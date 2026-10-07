--[[
	BikeVisualSync

	Shows every bike moving on every player's screen. Joint Transforms do
	not replicate, so the rider's client sends what its visual parts show
	(handlebar, suspension travel, wheel spin) and the engine speed a few
	times a second. The server checks the numbers and passes them on to
	the other players, and each of their clients poses that bike and its
	rider itself, the same way the rider's client does
	(BikeDynamics.VisualRig, BikeRiderPose).

	A packet is a fixed list of numbers: handlebar (rad), frontTravel and
	rearTravel (studs, compression positive), frontOmega and rearOmega
	(rad/s), engineRPM, throttle (0..1, what the engine gets) and gear
	(-1 reverse, 0 neutral). The engine values drive the engine sound
	(BikeSound) on the other players' clients.
]]

local VisualSync = {}

-- Plausible range of each packet value, in packet order; anything outside
-- is clamped.
local LIMITS = {
	{ -1.6, 1.6 },
	{ -2, 2 },
	{ -2, 2 },
	{ -1000, 1000 },
	{ -1000, 1000 },
	{ 0, 30000 },
	{ 0, 1 },
	{ -1, 12 },
}

VisualSync.PACKET_SIZE = #LIMITS

-- A bike nobody rides counts as parked (nothing to pose) below this speed
-- (studs/s) once its handlebar and suspension are back within REST_OFFSET
-- (rad, studs) of rest.
local REST_SPEED = 0.05
local REST_OFFSET = 1e-3

-- Rider's client: the packet for its bike's visual state.
function VisualSync.pack(visual, engineRPM, throttle, gear)
	return visual.handlebar,
		visual.frontTravel,
		visual.rearTravel,
		visual.frontOmega,
		visual.rearOmega,
		engineRPM,
		throttle,
		gear
end

-- Server: the packet as clamped numbers, or nil if it is not one.
function VisualSync.sanitize(...)
	if select("#", ...) ~= #LIMITS then
		return nil
	end

	local values = { ... }

	for index, limit in LIMITS do
		local value = values[index]

		-- value ~= value is NaN; infinities are clamped below.
		if type(value) ~= "number" or value ~= value then
			return nil
		end

		values[index] = math.clamp(value, limit[1], limit[2])
	end

	return values
end

-- First-order lag toward target at response (1/s).
local function approach(current, target, response, deltaTime)
	return current + (target - current) * (1 - math.exp(-response * deltaTime))
end

-- Radius of a wheel joint's part (1 if it is missing).
local function wheelRadius(joint)
	local part = joint.Part1

	return part and math.max(part.Size.Y, part.Size.Z) * 0.5 or 1
end

--[=[
	RemoteBike

	One bike as another player's client shows it: the visual parts follow
	the rider's packets (smoothed, since packets come a few times a second
	and may be lost), and the rider's avatar gets the riding pose. Without
	packets for a while the handlebar and suspension settle to rest and the
	wheels turn with the bike's own speed.

	It also stands in for BikeDynamics where BikeRiderPose reads it: frame,
	seat, steerPivot, steerAxis, displayHandlebar, state.forwardSpeed.
	For the engine sound it keeps engineRPM (smoothed), engineThrottle and
	gear, all nil without packets.

	A parked bike (no rider, no packets, standing still, settled) is not
	posed again until something changes, so many parked bikes cost next to
	nothing. With StreamingEnabled the parts it poses can stream out;
	attached() is then false and a new RemoteBike is needed once they are
	back.
]=]
local RemoteBike = {}
RemoteBike.__index = RemoteBike
VisualSync.RemoteBike = RemoteBike

-- Another player's bike on this client, posed from their packets.
function RemoteBike.new(bike, config, BikeDynamics, RiderPose)
	local frame, seat = BikeDynamics.rigParts(bike, config)
	local rig = bike:FindFirstChild(BikeDynamics.Names.Folder)
	local visualRig = rig and BikeDynamics.VisualRig.new(rig)

	assert(frame and seat and visualRig, "BikeVisualSync: bike rig is not ready")

	return setmetatable({
		bike = bike,
		config = config.Sync,
		frame = frame,
		seat = seat,
		visualRig = visualRig,
		steerPivot = visualRig.steerPivot,
		steerAxis = visualRig.steerAxis,
		frontRadius = wheelRadius(visualRig.front.joint),
		rearRadius = wheelRadius(visualRig.rear.joint),
		displayHandlebar = 0,
		state = { forwardSpeed = 0 },
		target = nil,
		lastPacket = -math.huge,
		visual = {
			handlebar = 0,
			frontTravel = 0,
			rearTravel = 0,
			frontOmega = 0,
			rearOmega = 0,
		},
		pose = RiderPose.new(config),
		engineRPM = nil,
		engineThrottle = nil,
		gear = nil,
		riderCharacter = nil,
		posing = false,
		active = false,
		resting = false,
	}, RemoteBike)
end

-- False once a part or joint it poses is no longer in the bike (streamed
-- out, or the bike was taken apart).
function RemoteBike:attached()
	local bike = self.bike
	local visualRig = self.visualRig

	if not (self.frame:IsDescendantOf(bike) and self.seat:IsDescendantOf(bike)) then
		return false
	end

	for _, joint in
		{
			visualRig.front.joint,
			visualRig.rear.joint,
			visualRig.forkJoint,
			visualRig.steerJoint,
			visualRig.swingarmJoint,
		}
	do
		if joint and not (joint:IsDescendantOf(bike) and joint.Part1 and joint.Part1:IsDescendantOf(bike)) then
			return false
		end
	end

	return true
end

-- A packet from the server (already checked there).
function RemoteBike:receive(handlebar, frontTravel, rearTravel, frontOmega, rearOmega, engineRPM, throttle, gear)
	self.target = {
		handlebar = handlebar,
		frontTravel = frontTravel,
		rearTravel = rearTravel,
		frontOmega = frontOmega,
		rearOmega = rearOmega,
		engineRPM = engineRPM,
		throttle = throttle,
		gear = gear and math.round(gear),
	}
	self.lastPacket = os.clock()
end

-- Bike speed along its heading (studs/s).
function RemoteBike:_speed()
	return self.frame.AssemblyLinearVelocity:Dot(self.frame.CFrame.LookVector)
end

-- Parked: nobody on it, no packets, standing still, settled at rest.
function RemoteBike:_parked(target, speed)
	local visual = self.visual

	return target == nil
		and self.seat.Occupant == nil
		and math.abs(speed) < REST_SPEED
		and math.abs(visual.handlebar) < REST_OFFSET
		and math.abs(visual.frontTravel) < REST_OFFSET
		and math.abs(visual.rearTravel) < REST_OFFSET
end

-- Poses the bike and its rider for this frame (call from PreSimulation).
function RemoteBike:step(deltaTime)
	local config = self.config
	local visual = self.visual
	local target = os.clock() - self.lastPacket <= config.StaleTime and self.target or nil
	local speed = self:_speed()
	local parked = self:_parked(target, speed)

	-- Posed once more on parking, then left as it is.
	if parked and self.resting then
		return
	end

	self.resting = parked
	self.active = true
	visual.handlebar = approach(visual.handlebar, target and target.handlebar or 0, config.Response, deltaTime)
	visual.frontTravel = approach(visual.frontTravel, target and target.frontTravel or 0, config.Response, deltaTime)
	visual.rearTravel = approach(visual.rearTravel, target and target.rearTravel or 0, config.Response, deltaTime)
	visual.frontOmega = target and target.frontOmega or speed / self.frontRadius
	visual.rearOmega = target and target.rearOmega or speed / self.rearRadius
	self.visualRig:apply(deltaTime, visual)

	self.displayHandlebar = visual.handlebar
	self.state.forwardSpeed = speed
	self:_followEngine(target, deltaTime)
	self:_poseRider(deltaTime)
end

-- Engine speed eases between packets like the visual parts; without
-- packets the engine state is unknown.
function RemoteBike:_followEngine(target, deltaTime)
	if target == nil or target.engineRPM == nil then
		self.engineRPM = nil
		self.engineThrottle = nil
		self.gear = nil

		return
	end

	local response = self.config.Response

	self.engineRPM = self.engineRPM and approach(self.engineRPM, target.engineRPM, response, deltaTime)
		or target.engineRPM
	self.engineThrottle = self.engineThrottle
			and approach(self.engineThrottle, target.throttle or 0, response, deltaTime)
		or target.throttle
		or 0
	self.gear = target.gear
end

-- Poses whoever sits on the bike (attaching on a new rider).
function RemoteBike:_poseRider(deltaTime)
	local occupant = self.seat.Occupant
	local character = occupant and occupant.Parent

	if character ~= self.riderCharacter then
		self.pose:detach()
		self.riderCharacter = character
		self.posing = character ~= nil and self.pose:attach(character, self)
	end

	if self.posing then
		self.pose:update(deltaTime, self)
	end
end

-- The local player rides this bike: its own controller poses the bike and
-- the avatar, so this lets go of both.
function RemoteBike:pause()
	if not self.active then
		return
	end

	self.active = false
	self.resting = false
	self.pose:detach()
	self.riderCharacter = nil
	self.posing = false
	self.target = nil
	self.lastPacket = -math.huge
	self.engineRPM = nil
	self.engineThrottle = nil
	self.gear = nil
end

-- Stops posing and puts the visual parts back.
function RemoteBike:destroy()
	self:pause()
	self.visualRig:reset()
end

return VisualSync
