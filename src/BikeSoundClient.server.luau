--[[
	BikeSoundClient

	A Script with RunContext Client inside the bike (set in the Rojo
	project): it runs on every player's client wherever the bike is
	dropped and plays this bike's engine (BikeSound) from the bike itself,
	so it is heard in 3D and fades with distance. Sounds made on a client
	stay on that client: every player hears every bike from their own
	client, driven by the engine state the bike's driving script publishes
	on it (BikeSound.Attributes: the rider's controller, or the visuals
	client for other players' bikes). The engine switch is
	BikeState.EngineOn; with no fresh engine state a running engine idles.

	Each loop plays a region of a Creator Store sound
	(PlaybackRegionsEnabled + LoopRegion), and a TremoloSoundEffect on it
	makes the rev limiter's stutter. Afterfire crackles play from a small
	pool through an equalizer that cuts the clip's low end.
	config.Sound.Profile picks the recorded engine; config.Sound.Enabled =
	false keeps the bike silent.

	A bike nobody can hear costs nothing: with its engine silent and every
	voice finished (a parked bike), or with the listener beyond the sounds'
	reach (RollOffMaxDistance), no sound is touched. The engine model keeps
	running, so the sound picks up where the engine is.
]]

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

if not RunService:IsClient() then
	warn("[BikeSoundClient] set RunContext to Client; the bike will be silent")

	return
end

local WAIT_TIMEOUT = 30
-- Published engine state older than this is stale (s).
local STALE_TIME = 0.5
-- A loop silent this long stops playing (s); it starts again when needed.
local SILENT_STOP_DELAY = 1
local SILENT_VOLUME = 1e-3
local STATUS_INTERVAL = 0.1
-- How often a detached sound emitter (the chassis streamed out) looks for
-- the chassis again (s).
local REBUILD_INTERVAL = 0.5
-- Afterfire bursts that may overlap, and the fade over a burst's last
-- POP_FADE seconds (no click where the region ends). The equalizer drops
-- the clip's lows (a car's burble under the crackle) by POP_LOW_CUT dB.
local POP_VOICES = 2
local POP_FADE = 0.06
local POP_LOW_CUT = -30

local bike = script.Parent

-- The sound's state, a local attribute on the bike (Studio lists it with
-- the bike's attributes).
local function setStatus(text)
	bike:SetAttribute("BikeSound", text)
end

local configModule = bike:WaitForChild("BikeConfig", WAIT_TIMEOUT)
local dynamicsModule = bike:WaitForChild("BikeDynamics", WAIT_TIMEOUT)
local soundModule = bike:WaitForChild("BikeSound", WAIT_TIMEOUT)

if not (configModule and dynamicsModule and soundModule) then
	setStatus("off: bike scripts missing")
	warn("[BikeSoundClient] bike scripts missing; the bike will be silent")

	return
end

local config = require(configModule)
local BikeDynamics = require(dynamicsModule)
local BikeSound = require(soundModule)

if not (config.Sound and config.Sound.Enabled) then
	setStatus("off (config)")

	return
end

local settingsFound, soundConfig = pcall(BikeSound.settings, config.Sound)

if not settingsFound then
	setStatus("off: " .. tostring(soundConfig))
	warn("[BikeSoundClient] " .. tostring(soundConfig))

	return
end

local profileName = soundConfig.Name or tostring(config.Sound.Profile or "sound")

while bike:GetAttribute(BikeDynamics.Names.ReadyAttribute) ~= true do
	task.wait(0.2)
end

local stateFolder = bike:WaitForChild("BikeState", WAIT_TIMEOUT)
local engineOn = stateFolder and stateFolder:WaitForChild("EngineOn", WAIT_TIMEOUT)

if not engineOn then
	setStatus("off: BikeState.EngineOn missing (see SERVER status)")
	warn("[BikeSoundClient] BikeState.EngineOn missing; the bike will be silent")

	return
end

local engine = BikeSound.new(soundConfig, config.Drivetrain, BikeDynamics.Powertrain)
local idleRPM = config.Drivetrain.IdleRPM

-- The sounds hang on an attachment at the chassis centre.
local emitter = nil
local chassis = nil
local loops = {}
local clips = {}
-- Afterfire voices: { sound, volume } and the next one to use.
local pops = {}
local nextPop = 1
local rebuildWait = 0

-- A Sound that plays one region of a clip (PlaybackRegion).
local function regionSound(name, clip, looped)
	local sound = Instance.new("Sound")

	sound.Name = name
	sound.SoundId = "rbxassetid://" .. tostring(clip.SoundId)
	sound.Looped = looped
	sound.PlaybackRegionsEnabled = true
	sound.PlaybackRegion = NumberRange.new(clip.Start, clip.End)

	if looped then
		sound.LoopRegion = NumberRange.new(clip.Start, clip.End)
	end

	sound.Volume = 0
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = soundConfig.RollOffMinDistance
	sound.RollOffMaxDistance = soundConfig.RollOffMaxDistance
	sound.Parent = emitter

	return sound
end

-- Removes the sounds (the chassis streamed out, or the script stops).
local function teardown()
	if emitter then
		emitter:Destroy()
	end

	emitter = nil
	chassis = nil
	table.clear(loops)
	table.clear(clips)
	table.clear(pops)
	nextPop = 1
end

-- Builds the sounds on the chassis: loops, start and stop clips, pops.
local function build(frame)
	teardown()
	chassis = frame
	emitter = Instance.new("Attachment")
	emitter.Name = "BikeSoundEmitter"
	emitter.Parent = frame

	for index, layer in engine.layers do
		local sound = regionSound("EngineLoop" .. index, layer.loop, true)
		local tremolo = Instance.new("TremoloSoundEffect")

		tremolo.Enabled = false
		tremolo.Parent = sound
		loops[index] = { sound = sound, tremolo = tremolo, start = layer.loop.Start, silentFor = math.huge }
	end

	for _, name in { "Start", "Stop" } do
		local clip = soundConfig[name]

		if BikeSound.clipLength(clip) > 0 then
			clips[name] = regionSound(name .. "Sound", clip, false)
		end
	end

	if BikeSound.clipLength(soundConfig.Pops) > 0 then
		for index = 1, POP_VOICES do
			local sound = regionSound("PopSound" .. index, soundConfig.Pops, false)
			local equalizer = Instance.new("EqualizerSoundEffect")

			equalizer.LowGain = POP_LOW_CUT
			equalizer.MidGain = 0
			equalizer.HighGain = 0
			equalizer.Parent = sound
			pops[index] = { sound = sound, volume = 0 }
		end
	end

	local assets = {}

	for _, loop in loops do
		table.insert(assets, loop.sound)
	end

	for _, clip in clips do
		table.insert(assets, clip)
	end

	for _, pop in pops do
		table.insert(assets, pop.sound)
	end

	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, assets)
	end)
end

-- The sounds still hang on this bike's chassis.
local function attached()
	return emitter ~= nil and chassis ~= nil and emitter.Parent == chassis and chassis:IsDescendantOf(bike)
end

-- Plays a sound from a time position.
local function play(sound, from)
	sound.TimePosition = from
	sound:Play()
end

-- An afterfire burst on the next voice.
local function firePop(mix)
	local pop = pops[nextPop]

	if pop == nil then
		return
	end

	nextPop = nextPop % #pops + 1
	pop.volume = mix.popVolume
	pop.sound.PlaybackSpeed = mix.popSpeed
	pop.sound.Volume = mix.popVolume
	play(pop.sound, mix.popStart)
end

-- Bursts fade out over their last POP_FADE seconds.
local function fadePops()
	local clipEnd = soundConfig.Pops and soundConfig.Pops.End or 0

	for _, pop in pops do
		if pop.sound.IsPlaying then
			local left = (clipEnd - pop.sound.TimePosition) / math.max(pop.sound.PlaybackSpeed, 1e-3)

			pop.sound.Volume = pop.volume * math.clamp(left / POP_FADE, 0, 1)
		end
	end
end

-- The engine makes no sound this frame: nothing to start, every loop silent.
local function silentMix(mix)
	if #mix.events > 0 then
		return false
	end

	for _, layer in mix.layers do
		if layer.volume > SILENT_VOLUME then
			return false
		end
	end

	return true
end

-- Every voice (loops, start and stop clips, pops) has stopped.
local function voicesFinished()
	for _, loop in loops do
		if loop.sound.IsPlaying then
			return false
		end
	end

	for _, clip in clips do
		if clip.IsPlaying then
			return false
		end
	end

	for _, pop in pops do
		if pop.sound.IsPlaying then
			return false
		end
	end

	return true
end

-- Stops every voice.
local function stopVoices()
	for _, loop in loops do
		loop.sound:Stop()
		loop.tremolo.Enabled = false
	end

	for _, clip in clips do
		clip:Stop()
	end

	for _, pop in pops do
		pop.sound:Stop()
	end
end

-- Where this player hears from: Roblox's listener, the camera unless the
-- place set another one; nil when it cannot be told.
local function listenerPosition()
	local read, listenerType, listener = pcall(SoundService.GetListener, SoundService)

	if not read then
		return nil
	end

	if listenerType == Enum.ListenerType.Camera then
		local camera = Workspace.CurrentCamera

		return camera and camera.CFrame.Position
	elseif typeof(listener) == "CFrame" then
		return listener.Position
	elseif typeof(listener) == "Instance" and listener:IsA("BasePart") then
		return listener.Position
	elseif typeof(listener) == "Instance" and listener:IsA("Camera") then
		return listener.CFrame.Position
	end

	return nil
end

-- The listener is within the sounds' reach: their volume falls to zero at
-- RollOffMaxDistance. An unknown listener counts as near.
local function inReach()
	local position = listenerPosition()

	return position == nil or (position - emitter.WorldPosition).Magnitude < soundConfig.RollOffMaxDistance
end

-- Every sound is stopped and left alone until the bike can be heard again.
local muted = false
local statusElapsed = 0

local function updateStatus(deltaTime, running)
	statusElapsed += deltaTime

	if statusElapsed >= STATUS_INTERVAL then
		statusElapsed = 0
		setStatus((running and "on: " or "engine off: ") .. profileName)
	end
end

-- Every frame: rebuild if needed, then set every sound from the mix.
local function step(deltaTime)
	if not attached() then
		teardown()
		rebuildWait -= deltaTime

		if rebuildWait > 0 then
			return
		end

		rebuildWait = REBUILD_INTERVAL

		local frame = BikeDynamics.rigParts(bike, config)

		if frame == nil then
			setStatus("waiting for the chassis to stream in")

			return
		end

		build(frame)
		muted = false
	end

	local running = engineOn.Value
	local published = BikeSound.read(bike, STALE_TIME)
	local mix = engine:update(deltaTime, published and {
		running = running,
		rpm = published.rpm,
		throttle = published.throttle,
		gear = published.gear,
		limited = published.limited,
	} or {
		running = running,
		rpm = running and idleRPM or 0,
		throttle = 0,
	})
	local silent = silentMix(mix)

	-- A parked bike stays muted without a look at its sounds; otherwise mute
	-- once the voices have finished, or while out of reach.
	if silent and muted then
		updateStatus(deltaTime, running)

		return
	end

	if not inReach() or (silent and voicesFinished()) then
		if not muted then
			muted = true
			stopVoices()
		end

		updateStatus(deltaTime, running)

		return
	end

	muted = false

	for index, loop in loops do
		local layer = mix.layers[index]
		local sound = loop.sound
		local tremolo = loop.tremolo

		sound.PlaybackSpeed = layer.speed
		sound.Volume = layer.volume

		if layer.volume > SILENT_VOLUME then
			loop.silentFor = 0

			if not sound.IsPlaying then
				play(sound, loop.start)
			end
		else
			loop.silentFor += deltaTime

			if loop.silentFor > SILENT_STOP_DELAY and sound.IsPlaying then
				sound:Stop()
			end
		end

		tremolo.Enabled = mix.limiter

		if mix.limiter then
			tremolo.Frequency = mix.limiterFrequency
			tremolo.Duty = mix.limiterDuty
			tremolo.Depth = math.clamp(mix.limiterDepth, 0, 1)
		end
	end

	for _, event in mix.events do
		if event == "start" then
			if clips.Stop then
				clips.Stop:Stop()
			end

			if clips.Start then
				play(clips.Start, soundConfig.Start.Start)
			end
		elseif event == "stop" then
			if clips.Start then
				clips.Start:Stop()
			end

			if clips.Stop then
				play(clips.Stop, soundConfig.Stop.Start)
			end
		elseif event == "pop" then
			firePop(mix)
		end
	end

	if clips.Start then
		clips.Start.Volume = mix.startVolume
	end

	if clips.Stop then
		clips.Stop.Volume = mix.stopVolume
	end

	fadePops()
	updateStatus(deltaTime, running)
end

setStatus("ready")

local stepConnection

stepConnection = RunService.Heartbeat:Connect(function(deltaTime)
	local stepped, problem = pcall(step, deltaTime)

	if not stepped then
		-- Go quiet and say why instead of repeating the error every frame.
		stepConnection:Disconnect()
		pcall(teardown)
		setStatus("off: " .. tostring(problem))
		warn("[BikeSoundClient] " .. tostring(problem))
	end
end)

script.Destroying:Connect(function()
	stepConnection:Disconnect()
	teardown()
end)
