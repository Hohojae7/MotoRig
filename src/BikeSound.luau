--[[
	BikeSound

	The engine sound of a bike, from constant-rpm loops cut out of one
	engine's recordings (a profile in config.Sound, see BikeSound.settings).
	BikeSoundClient plays it on every player's client; this module is plain
	math on the engine state, so the offline checks run it too.

	- Pitch: an engine's firing frequency is rpm / 60 * cylinders / 2, so
	  its sound scales with engine speed like a tape played faster. A loop
	  recorded at RecordedRPM plays at PlaybackSpeed = soundRPM / RecordedRPM.
	  Our engine (Drivetrain.IdleRPM..RevLimitRPM) is a scaled one; the
	  sound maps it linearly onto the recorded engine's own idle..limiter
	  (Sound.IdleRPM..RevLimitRPM).
	- Mix: the two loops around soundRPM cross over with equal power along
	  log rpm (pitch), so the loudness stays even and each loop is
	  stretched as little as possible.
	- Loudness: the level rises LoudnessSlope dB per tenfold engine speed
	  (measured in the recording), and the exhaust pulses scale with the
	  cylinder charge: ClosedThrottleCharge of a full charge with the
	  throttle shut, all of it wide open. The charge follows the throttle
	  over ChargeRevolutions crank turns (the intake fills and empties).
	  DynamicRange keeps that share of the real range; Volume is the
	  volume at the rev limiter with the throttle open.
	- Rev limiter: the fuel cut stops combustion until the engine has
	  slowed by LimiterHysteresisRPM against its own drag, then full torque
	  brings it back: t_cut = I * dw / T_drag and t_fire = I * dw / T_full.
	  The sound drops to the closed-throttle level for the cut share of each
	  cycle, 1 / (t_cut + t_fire) times a second.
	- Starting: the start clip plays and the loops fade in over its tail
	  (at once when the rider opens the throttle). Stopping: combustion
	  ends, the loops fall silent within StopRelease and the stop clip
	  plays.
	- Afterfire: shutting the throttle at high revs after a spell of load
	  leaves unburnt fuel that fires in the hot exhaust. When the throttle
	  stays shut for PopDelay after at least PopLoadTime of load, with the
	  engine above PopRevShare of the limiter, the Pops clip plays with
	  PopChance, a little different each time. A shift's ignition cut is
	  too short to count. It crackles only from PopMinGear up, never in
	  neutral, the low gears or reverse.
]]

local BikeSound = {}
BikeSound.__index = BikeSound

local RAD_PER_RPM = math.pi / 30
-- TremoloSoundEffect.Frequency accepts 0.1..20 Hz.
local MIN_TREMOLO_FREQUENCY = 0.1
local MAX_TREMOLO_FREQUENCY = 20
-- Without word from the sender (other players' bikes), an engine within
-- this share of the rev limiter with the throttle at least this open is
-- limiting.
local LIMITER_MARGIN_SHARE = 0.005
local LIMITER_THROTTLE = 0.5
-- The rider opening the throttle, or the engine running this far over
-- idle, ends the start clip early.
local START_THROTTLE = 0.05
local START_RPM_RATIO = 1.25
-- Time constant of a quick fade (s): the loops coming in without a start
-- clip, or a start clip cut short. A clip faded below CLIP_GONE (-40 dB)
-- is over.
local QUICK_FADE = 0.05
local CLIP_GONE = 0.01
-- Roblox Sound limits.
local MAX_VOLUME = 10
local MIN_SPEED = 0.05
local MAX_SPEED = 10
-- Afterfire: a throttle at least POP_LOAD_THROTTLE open counts as load,
-- one below SHUT_THROTTLE as shut. Each burst starts up to
-- POP_OFFSET_SPREAD (s) into the clip, plays up to POP_SPEED_SPREAD faster
-- or slower and down to POP_QUIETEST of its volume, so no two sound alike.
local POP_LOAD_THROTTLE = 0.5
local SHUT_THROTTLE = 0.05
local POP_OFFSET_SPREAD = 0.15
local POP_SPEED_SPREAD = 0.06
local POP_QUIETEST = 0.6

-- Engine state published on the bike every frame by the script that
-- drives it on this client: the rider's controller, or the visuals client
-- for other players' bikes. Local attributes, never replicated.
BikeSound.Attributes = {
	RPM = "BikeSoundRPM",
	Throttle = "BikeSoundThrottle",
	Gear = "BikeSoundGear",
	Limited = "BikeSoundLimited",
	Tick = "BikeSoundTick",
}

-- limited may be nil when the sender does not know (it is then worked out
-- from rpm and throttle).
function BikeSound.publish(bike, rpm, throttle, gear, limited)
	local names = BikeSound.Attributes

	bike:SetAttribute(names.RPM, rpm)
	bike:SetAttribute(names.Throttle, throttle)
	bike:SetAttribute(names.Gear, gear)
	bike:SetAttribute(names.Limited, limited)
	bike:SetAttribute(names.Tick, os.clock())
end

-- The published state, or nil when nothing was published for staleTime.
function BikeSound.read(bike, staleTime)
	local names = BikeSound.Attributes
	local tick = bike:GetAttribute(names.Tick)

	if type(tick) ~= "number" or os.clock() - tick > staleTime then
		return nil
	end

	return {
		rpm = bike:GetAttribute(names.RPM) or 0,
		throttle = bike:GetAttribute(names.Throttle) or 0,
		gear = bike:GetAttribute(names.Gear),
		limited = bike:GetAttribute(names.Limited),
	}
end

-- The sound that plays: the shared settings of config.Sound with the
-- chosen profile (Sound.Profiles[Sound.Profile]) on top. A config without
-- profiles is used as it is.
function BikeSound.settings(soundConfig)
	local profiles = soundConfig.Profiles

	if profiles == nil then
		return soundConfig
	end

	local profile = profiles[soundConfig.Profile]

	if profile == nil then
		error("BikeSound: no sound profile named " .. tostring(soundConfig.Profile), 2)
	end

	local settings = table.clone(soundConfig)

	settings.Profiles = nil

	for key, value in profile do
		settings[key] = value
	end

	return settings
end

-- First-order lag with a time constant (s), not a rate as in the other
-- modules.
local function approach(current, target, timeConstant, deltaTime)
	if timeConstant <= 0 then
		return target
	end

	return current + (target - current) * (1 - math.exp(-deltaTime / timeConstant))
end

-- Length of a clip (s); 0 when it has no sound.
local function clipLength(clip)
	if clip == nil or (clip.SoundId or 0) == 0 then
		return 0
	end

	return math.max((clip.End or 0) - (clip.Start or 0), 0)
end

BikeSound.clipLength = clipLength

-- The recorded engine's speed at our engine speed rpm.
function BikeSound.soundRPM(sound, drivetrain, rpm)
	local span = math.max(drivetrain.RevLimitRPM - drivetrain.IdleRPM, 1)
	local soundRPM = sound.IdleRPM + (rpm - drivetrain.IdleRPM) * (sound.RevLimitRPM - sound.IdleRPM) / span

	return math.max(soundRPM, sound.IdleRPM * MIN_SPEED)
end

-- Amplitude weight of each loop (sorted by RecordedRPM) at a sound rpm;
-- the squares add up to 1.
function BikeSound.weights(loops, soundRPM)
	local count = #loops
	local weights = table.create(count, 0)

	if count == 0 then
		return weights
	end

	if soundRPM <= loops[1].RecordedRPM then
		weights[1] = 1

		return weights
	end

	if soundRPM >= loops[count].RecordedRPM then
		weights[count] = 1

		return weights
	end

	for index = 1, count - 1 do
		local low = loops[index].RecordedRPM
		local high = loops[index + 1].RecordedRPM

		if soundRPM <= high then
			local share = math.log(soundRPM / low) / math.log(high / low)

			weights[index] = math.cos(share * math.pi / 2)
			weights[index + 1] = math.sin(share * math.pi / 2)

			break
		end
	end

	return weights
end

-- Share of a full cylinder charge at a throttle opening (0..1).
function BikeSound.charge(sound, throttle)
	local closed = math.clamp(sound.ClosedThrottleCharge, 1e-3, 1)

	return closed + (1 - closed) * math.clamp(throttle, 0, 1)
end

-- Real level (dB) at a sound rpm and cylinder charge, against idle with
-- the throttle shut.
function BikeSound.level(sound, soundRPM, charge)
	return sound.LoudnessSlope * math.log10(math.max(soundRPM, 1) / sound.IdleRPM)
		+ 20 * math.log10(math.max(charge, 1e-3) / BikeSound.charge(sound, 0))
end

-- Sound volume at a sound rpm and cylinder charge: the real level kept by
-- DynamicRange, with Volume at the rev limiter and the throttle open.
function BikeSound.volume(sound, soundRPM, charge)
	local loudest = BikeSound.level(sound, sound.RevLimitRPM, 1)
	local decibels = (BikeSound.level(sound, soundRPM, charge) - loudest) * sound.DynamicRange

	return sound.Volume * 10 ^ (decibels / 20)
end

-- Gain that brings a clip measured at level (RMS dBFS) to ReferenceLevel,
-- so the loops and clips match before the loudness model applies.
function BikeSound.levelGain(sound, level)
	local reference = sound.ReferenceLevel or -20

	return 10 ^ ((reference - (level or reference)) / 20)
end

-- Volume of a clip played at level dB against the engine at the limiter
-- with the throttle open (the afterfire).
function BikeSound.clipVolume(sound, clip, level)
	return sound.Volume * 10 ^ ((level or 0) / 20) * BikeSound.levelGain(sound, clip and clip.Level)
end

-- Rev limiter cycle: frequency (Hz) and the share of each cycle without
-- combustion, from the engine's inertia, full-load torque and drag; nil
-- without a hysteresis.
function BikeSound.limiterCycle(sound, drivetrain, Powertrain)
	local hysteresis = math.max(sound.LimiterHysteresisRPM or 0, 0) * RAD_PER_RPM
	local limit = drivetrain.RevLimitRPM
	local fullTorque = Powertrain.netTorque(drivetrain, limit, 1)
	local dragTorque = Powertrain.engineBrakeTorque(drivetrain, limit)

	if hysteresis <= 0 or fullTorque <= 0 or dragTorque <= 0 then
		return nil, nil
	end

	local inertia = Powertrain.engineInertia(drivetrain)
	local firing = inertia * hysteresis / fullTorque
	local cut = inertia * hysteresis / dragTorque

	return 1 / (firing + cut), cut / (firing + cut)
end

-- The engine sound of one bike; update() it every frame.
function BikeSound.new(sound, drivetrain, Powertrain)
	local loops = table.clone(sound.Loops or {})

	table.sort(loops, function(a, b)
		return a.RecordedRPM < b.RecordedRPM
	end)

	local layers = {}

	for index, loop in loops do
		layers[index] = {
			loop = loop,
			gain = BikeSound.levelGain(sound, loop.Level),
			weight = 0,
			speed = 1,
			volume = 0,
		}
	end

	local frequency, cutShare = BikeSound.limiterCycle(sound, drivetrain, Powertrain)
	local idleVolume = BikeSound.volume(sound, sound.IdleRPM, BikeSound.charge(sound, 0))

	return setmetatable({
		config = sound,
		drivetrain = drivetrain,
		loops = loops,
		layers = layers,
		limiterFrequency = frequency,
		limiterCutShare = cutShare,
		-- Volume of idle with the throttle shut: the clips are recorded
		-- around idle and play at it.
		idleVolume = idleVolume,
		initialized = false,
		running = false,
		gear = nil,
		charge = BikeSound.charge(sound, 0),
		-- Share of the loops' volume: 0 silent, 1 running.
		combustion = 0,
		-- Seconds into the start clip while it plays, and its gain.
		startTime = nil,
		startGain = 0,
		startCut = false,
		-- Afterfire: seconds of load before the throttle shut, and seconds
		-- shut since. random() gives 0..1 (tests may replace it).
		loadTime = 0,
		shutTime = 0,
		random = math.random,
		mix = {
			soundRPM = sound.IdleRPM,
			volume = 0,
			layers = layers,
			limiter = false,
			limiterFrequency = frequency and math.clamp(frequency, MIN_TREMOLO_FREQUENCY, MAX_TREMOLO_FREQUENCY) or 0,
			limiterDuty = cutShare or 0,
			limiterDepth = 0,
			startVolume = 0,
			stopVolume = idleVolume * BikeSound.levelGain(sound, sound.Stop and sound.Stop.Level),
			-- The latest afterfire burst: where in the clip it starts (s),
			-- its playback speed and volume.
			popStart = 0,
			popSpeed = 1,
			popVolume = 0,
			-- "start", "stop", "pop" since the last update.
			events = {},
		},
	}, BikeSound)
end

-- Whether the exhaust crackles in a gear: only from PopMinGear up, not in
-- neutral, the low gears or reverse. An unknown gear (nil) counts as one
-- that does.
local function popsInGear(sound, gear)
	local lowest = sound.PopMinGear

	return gear == nil or lowest == nil or gear >= lowest
end

-- Afterfire bookkeeping for one frame; adds "pop" to the events when a
-- burst fires.
function BikeSound:_afterfire(deltaTime, running, rpm, throttle, soundRPM)
	local sound = self.config
	local clip = sound.Pops

	if not running or clipLength(clip) <= 0 then
		self.loadTime = 0
		self.shutTime = 0

		return
	end

	if throttle >= POP_LOAD_THROTTLE then
		self.loadTime += deltaTime
		self.shutTime = 0

		return
	end

	if throttle > SHUT_THROTTLE then
		self.shutTime = 0

		return
	end

	self.shutTime += deltaTime

	if self.loadTime < (sound.PopLoadTime or 0) or self.shutTime < (sound.PopDelay or 0) then
		return
	end

	-- One chance per lift-off.
	self.loadTime = 0

	local drivetrain = self.drivetrain

	if rpm < drivetrain.RevLimitRPM * (sound.PopRevShare or 1)
		or not popsInGear(sound, self.gear)
		or self.random() >= (sound.PopChance or 0)
	then
		return
	end

	local mix = self.mix
	-- Louder at higher revs, as the engine is.
	local revLevel = sound.LoudnessSlope * math.log10(math.max(soundRPM, 1) / sound.RevLimitRPM) * sound.DynamicRange

	mix.popStart = clip.Start + self.random() * math.min(POP_OFFSET_SPREAD, clipLength(clip) * 0.5)
	mix.popSpeed = 1 + (self.random() * 2 - 1) * POP_SPEED_SPREAD
	mix.popVolume = math.min(
		BikeSound.clipVolume(sound, clip, sound.PopLevel)
			* 10 ^ (revLevel / 20)
			* (POP_QUIETEST + (1 - POP_QUIETEST) * self.random()),
		MAX_VOLUME
	)
	table.insert(mix.events, "pop")
end

--[=[
	One frame. input: running (engine on), rpm (our engine), throttle
	(0..1, what the engine gets), gear (nil if unknown), limited (nil if
	unknown). Returns the mix: soundRPM, volume, layers[i] = {weight,
	speed, volume}, limiter (+ Frequency, Duty, Depth for a
	TremoloSoundEffect), startVolume, stopVolume,
	popStart/popSpeed/popVolume, events.
]=]
function BikeSound:update(deltaTime, input)
	local sound = self.config
	local drivetrain = self.drivetrain
	local mix = self.mix
	local events = mix.events
	local running = input.running == true
	local rpm = math.max(input.rpm or 0, 0)
	local throttle = running and math.clamp(input.throttle or 0, 0, 1) or 0

	deltaTime = math.max(deltaTime, 0)
	table.clear(events)

	if not self.initialized then
		-- An engine already running when this client arrived: no start clip.
		self.initialized = true
		self.running = running
		self.combustion = running and 1 or 0
	elseif running ~= self.running then
		self.running = running
		self.startTime = nil
		self.startGain = 0

		if running then
			table.insert(events, "start")

			if clipLength(sound.Start) > 0 then
				self.startTime = 0
				self.startGain = 1
				self.startCut = false
			end
		else
			table.insert(events, "stop")
		end
	end

	if input.gear ~= nil then
		if self.gear ~= nil and input.gear ~= self.gear then
			-- A shift's ignition cut or blip is not a lift-off.
			self.loadTime = 0
		end

		self.gear = input.gear
	end

	-- The cylinder charge follows the throttle over ChargeRevolutions
	-- crank turns.
	local turnsPerSecond = math.max(rpm, drivetrain.IdleRPM) / 60

	self.charge = approach(
		self.charge,
		BikeSound.charge(sound, throttle),
		(sound.ChargeRevolutions or 0) / turnsPerSecond,
		deltaTime
	)

	if not running then
		self.combustion = approach(self.combustion, 0, sound.StopRelease or 0, deltaTime)
	elseif self.startTime then
		local length = clipLength(sound.Start)

		self.startTime += deltaTime

		if throttle > START_THROTTLE or rpm > drivetrain.IdleRPM * START_RPM_RATIO then
			self.startCut = true
		end

		if self.startCut then
			self.combustion = approach(self.combustion, 1, QUICK_FADE, deltaTime)
			self.startGain = approach(self.startGain, 0, QUICK_FADE, deltaTime)
		else
			-- Equal-power crossover from the clip's idle tail into the loops.
			local blend = math.clamp(sound.Start.Blend or 0, 0, length)
			local share = blend > 0 and math.clamp((self.startTime - (length - blend)) / blend, 0, 1)
				or (self.startTime >= length and 1 or 0)

			self.combustion = math.sin(share * math.pi / 2)
			self.startGain = math.cos(share * math.pi / 2)
		end

		if self.startTime >= length or (self.startCut and self.startGain < CLIP_GONE) then
			if not self.startCut then
				self.combustion = 1
			end

			self.startTime = nil
			self.startGain = 0
		end
	else
		self.combustion = approach(self.combustion, 1, QUICK_FADE, deltaTime)
	end

	local soundRPM = BikeSound.soundRPM(sound, drivetrain, rpm)
	local volume = BikeSound.volume(sound, soundRPM, self.charge)
	local weights = BikeSound.weights(self.loops, soundRPM)

	self:_afterfire(deltaTime, running, rpm, throttle, soundRPM)

	for index, layer in self.layers do
		layer.weight = weights[index]
		layer.speed = math.clamp(soundRPM / layer.loop.RecordedRPM, MIN_SPEED, MAX_SPEED)
		layer.volume = math.min(weights[index] * layer.gain * self.combustion * volume, MAX_VOLUME)
	end

	local limited = input.limited

	if limited == nil then
		limited = rpm >= drivetrain.RevLimitRPM * (1 - LIMITER_MARGIN_SHARE) and throttle >= LIMITER_THROTTLE
	end

	mix.soundRPM = soundRPM
	mix.volume = volume * self.combustion
	mix.limiter = running and limited == true and self.limiterFrequency ~= nil
	-- During the cut the charge drops to the closed-throttle one.
	mix.limiterDepth = 1 - (BikeSound.charge(sound, 0) / math.max(self.charge, 1e-3)) ^ sound.DynamicRange
	mix.startVolume = self.idleVolume * BikeSound.levelGain(sound, sound.Start and sound.Start.Level) * self.startGain

	return mix
end

return BikeSound
