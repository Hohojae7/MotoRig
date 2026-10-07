--[[
	BikeCamera

	The rider's camera while riding. BikeCameraClient runs it on the rider's
	client; this module is plain math on the bike's pose and velocity, so
	the offline bench runs it too.

	Chase view (default): behind and above the bike, looking at a point over
	its center.
	  - It trails the bike like a trailer on a hitch: its heading turns
	    toward the bike's over Camera.HitchLength studs of travel. In a turn
	    of radius R the bike is seen about HitchLength / R radians off its
	    tail at any speed, and a slow or stopped bike still gets the camera
	    back behind it.
	  - It tilts with the road's slope (the line through the axles, which
	    the suspension does not move) and a little with the bike's lean.
	  - It hangs on a sprung boom: accelerating pushes it back and braking
	    pulls it in, by a / (2 pi f)^2 at a steady acceleration a.
	  - The field of view widens with speed, up to the bike's top speed.
	  - Walls and terrain between the bike and the camera pull it in front
	    of them; it eases back out once they are gone.
	Helmet view: from the rider's head, turning and rolling with it.

	The rider can look around (the offset swings back behind the bike a
	moment after the last input), zoom (all the way in is the helmet view),
	switch views and look back.
]]

local BikeCamera = {}
BikeCamera.__index = BikeCamera

local CHASE = "chase"
local HELMET = "helmet"

BikeCamera.Views = { Chase = CHASE, Helmet = HELMET }

-- How fast the shown roll, field of view and zoom follow their targets (1/s).
local ROLL_RESPONSE = 8
local FIELD_OF_VIEW_RESPONSE = 4
local ZOOM_RESPONSE = 10
-- The helmet view turns and tilts with the bike this quickly (1/s).
local HELMET_RESPONSE = 20
-- Steepest slope the view tilts with, and the pitch range of the view (rad).
local MAX_SLOPE = math.rad(45)
local MIN_PITCH = math.rad(-80)
local MAX_PITCH = math.rad(60)
-- Each mouse wheel notch changes the chase distance by this factor.
local ZOOM_STEP = 1.15
-- The boom spring is integrated in steps no longer than this (s), over at
-- most MAX_BOOM_TIME of a long frame.
local BOOM_SUBSTEP = 1 / 120
local MAX_BOOM_TIME = 0.5
-- Speed change the boom takes from one frame at most (studs/s), so a crash
-- does not fling the camera.
local MAX_BOOM_IMPULSE = 60
-- The bike moving farther than its own speed explains plus this (studs) in
-- one frame was teleported: the camera starts over behind it.
local TELEPORT_DISTANCE = 30
-- Parts at least this transparent do not block the view (as with Roblox's
-- own camera).
local SEE_THROUGH = 0.25
local MAX_CASTS = 4
local MAX_SEE_THROUGH_PARTS = 64

-- First-order lag toward target at response (1/s).
local function approach(current, target, response, deltaTime)
	return current + (target - current) * (1 - math.exp(-response * deltaTime))
end

-- Angle wrapped to -pi..pi.
local function wrapAngle(angle)
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

-- The vector without its vertical part.
local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Heading of a horizontal direction: 0 looks along -Z, positive turns left
-- (the yaw of CFrame.Angles(0, yaw, 0)).
local function yawOf(vector)
	return math.atan2(-vector.X, -vector.Z)
end

-- The bike's lean as drawn (positive to the left), at most a quarter turn
-- so a bike on its back does not turn the view over.
local function leanOf(frame)
	return math.clamp(math.atan2(frame.RightVector.Y, frame.UpVector.Y), -math.pi / 2, math.pi / 2)
end

-- Road slope under the bike (rad, uphill positive): the line through the
-- tire contacts (each axle less its wheel radius along the bike's up)
-- follows the ground whatever the suspension does; without the axles,
-- the chassis pitch.
local function slopeOf(view, radiusDifference)
	local front, rear = view.frontAxle, view.rearAxle

	if front and rear then
		local axis = front - rear - view.frame.UpVector * radiusDifference
		local run = horizontal(axis).Magnitude

		if run > 0.1 then
			return math.clamp(math.atan2(axis.Y, run), -MAX_SLOPE, MAX_SLOPE)
		end
	end

	return math.clamp(math.asin(math.clamp(view.frame.LookVector.Y, -1, 1)), -MAX_SLOPE, MAX_SLOPE)
end

-- Whether a part between the bike and the camera blocks the view:
-- see-through parts and characters (any model with a Humanoid) do not.
local function blocksView(instance)
	if not instance:IsA("BasePart") then
		return true
	end

	if instance.Transparency >= SEE_THROUGH or instance.LocalTransparencyModifier >= SEE_THROUGH then
		return false
	end

	local model = instance:FindFirstAncestorOfClass("Model")

	return not (model and model:FindFirstChildOfClass("Humanoid"))
end

-- The bike's top speed (studs/s): the rev limiter in its tallest gear.
function BikeCamera.topSpeed(config, Powertrain, rearRadius)
	local tallest = math.huge

	for _, ratio in config.Drivetrain.GearRatios do
		tallest = math.min(tallest, ratio)
	end

	return Powertrain.revLimitWheelOmega(config.Drivetrain, tallest) * rearRadius
end

--[=[
	config: the bike config (Camera; Rider.HeadLevel sets how far the
	helmet view rolls with the bike, as the rider's head does).
	options.topSpeed: bike speed (studs/s) where the view is widest.
	options.frontRadius, options.rearRadius: wheel radii (studs), so the
	slope is read at the tire contacts.
	options.world: where the view looks for walls (workspace); nil: none.
]=]
function BikeCamera.new(config, options)
	options = options or {}

	local cameraConfig = config.Camera
	local headLevel = config.Rider and config.Rider.HeadLevel or 0.5
	local self = setmetatable({
		config = cameraConfig,
		helmetRoll = 1 - headLevel,
		topSpeed = math.max(options.topSpeed or 100, 1),
		radiusDifference = (options.frontRadius or 0) - (options.rearRadius or 0),
		world = options.world,
		castParams = nil,
		ignore = {},
		seeThrough = {},
		minDistance = cameraConfig.MinDistance,
		maxDistance = cameraConfig.MaxDistance,
		view = CHASE,
		lookBack = false,
		lookHeld = false,
		lookIdle = math.huge,
		orbitYaw = 0,
		orbitPitch = 0,
		zoomTarget = cameraConfig.Distance,
		zoomDistance = cameraConfig.Distance,
		-- View heading, and the bike's heading at the last frame.
		yaw = 0,
		heading = 0,
		slope = 0,
		roll = 0,
		boom = 0,
		boomVelocity = 0,
		lastVelocity = Vector3.zero,
		lastFocus = nil,
		-- Occlusion limit on the distance (math.huge: nothing in the way).
		limit = math.huge,
		distance = cameraConfig.Distance,
		fieldOfView = cameraConfig.FieldOfView,
		cframe = CFrame.identity,
	}, BikeCamera)

	self:_refreshFilter()

	return self
end

-- Instances the view sees through: the bike and its rider.
function BikeCamera:setIgnore(instances)
	self.ignore = table.clone(instances)
	table.clear(self.seeThrough)
	self:_refreshFilter()
end

-- Zoom range the place allows (Player.CameraMinZoomDistance and
-- CameraMaxZoomDistance), within the bike's own.
function BikeCamera:setZoomLimits(minimum, maximum)
	local config = self.config

	self.minDistance = math.max(config.MinDistance, minimum or 0)
	self.maxDistance = math.max(math.min(config.MaxDistance, maximum or math.huge), self.minDistance)
	self.zoomTarget = math.clamp(self.zoomTarget, self.minDistance, self.maxDistance)
end

-- Raycast filter for the camera's wall checks (ignored and see-through parts).
function BikeCamera:_refreshFilter()
	if self.world == nil then
		return
	end

	local list = table.clone(self.ignore)

	for _, part in self.seeThrough do
		table.insert(list, part)
	end

	local params = RaycastParams.new()

	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.IgnoreWater = true
	-- What the rider can walk through (CanCollide off) does not block the view.
	params.RespectCanCollide = true
	self.castParams = params
end

-- Input --------------------------------------------------------------------

function BikeCamera:_basePitch()
	return -math.rad(self.view == HELMET and self.config.HelmetPitch or self.config.Pitch)
end

-- Looks around by these angles (rad): positive yaw to the left, positive
-- pitch up.
function BikeCamera:look(yaw, pitch)
	local base = self:_basePitch()

	self.orbitYaw = wrapAngle(self.orbitYaw + yaw)
	self.orbitPitch = math.clamp(self.orbitPitch + pitch, MIN_PITCH - base, MAX_PITCH - base)
	self.lookIdle = 0
end

-- While held (a mouse button or a finger down) the view stays where it was
-- turned; the swing back waits from the moment it is let go.
function BikeCamera:holdLook(held)
	self.lookHeld = held
	self.lookIdle = 0
end

-- Look back while held.
function BikeCamera:setLookBack(held)
	if held ~= self.lookBack then
		self.lookBack = held
		self.limit = math.huge
	end
end

-- Chase or helmet view.
function BikeCamera:setView(view)
	if view ~= CHASE and view ~= HELMET then
		return
	end

	if view ~= self.view then
		self.view = view
		self.orbitYaw = 0
		self.orbitPitch = 0
		self.zoomDistance = self.zoomTarget
		self.limit = math.huge
	end
end

-- Switches between the chase and helmet views.
function BikeCamera:toggleView()
	self:setView(self.view == CHASE and HELMET or CHASE)
end

-- Mouse wheel notches, positive in. In past the nearest chase distance is
-- the helmet view; out of the helmet view is the nearest chase distance.
function BikeCamera:zoomIn(steps)
	if self.view == HELMET then
		if steps < 0 then
			self.zoomTarget = self.minDistance
			self:setView(CHASE)
		end

		return
	end

	if steps > 0 and self.zoomTarget <= self.minDistance + 1e-3 then
		self:setView(HELMET)

		return
	end

	self.zoomTarget = math.clamp(self.zoomTarget / ZOOM_STEP ^ steps, self.minDistance, self.maxDistance)
end

-- The view from the rider's eyes this frame (not looking back).
function BikeCamera:showsHelmet()
	return self.view == HELMET and not self.lookBack
end

-- For the dashboard.
function BikeCamera:describe()
	if self.lookBack then
		return "look back"
	end

	if self.view == HELMET then
		return "helmet"
	end

	if self.limit < math.huge then
		return string.format("chase %.0f (wall %.1f)", self.zoomTarget, self.distance)
	end

	return string.format("chase %.0f", self.zoomTarget)
end

-- Frame ----------------------------------------------------------------------

--[=[
	Puts the camera straight behind the bike, as it is now (start of a
	ride, or after a teleport). Keeps the view and zoom the rider chose.
]=]
function BikeCamera:reset(view)
	local frame = view.frame
	local flat = horizontal(frame.LookVector)
	local helmet = self:showsHelmet()

	if flat.Magnitude > 0.2 then
		self.yaw = yawOf(flat)
		self.heading = self.yaw
	end

	self.slope = helmet and math.asin(math.clamp(frame.LookVector.Y, -1, 1))
		or slopeOf(view, self.radiusDifference) * self.config.SlopeFollow
	self.roll = leanOf(frame) * (helmet and self.helmetRoll or self.config.LeanRoll)
	self.orbitYaw = 0
	self.orbitPitch = 0
	self.lookIdle = math.huge
	self.boom = 0
	self.boomVelocity = 0
	self.lastVelocity = view.velocity
	self.limit = math.huge
	self.zoomDistance = self.zoomTarget
	self.fieldOfView = self:_fieldOfViewTarget(view.velocity, helmet)
	self.lastFocus = frame.Position + Vector3.yAxis * self.config.FocusHeight
end

-- Field of view, wider with speed (SpeedFieldOfView more at top speed).
function BikeCamera:_fieldOfViewTarget(velocity, helmet)
	local config = self.config
	local speedShare = math.clamp(velocity.Magnitude / self.topSpeed, 0, 1)

	return (helmet and config.HelmetFieldOfView or config.FieldOfView) + config.SpeedFieldOfView * speedShare
end

-- Boom: a damped spring along the view, driven by the bike's speed change
-- over the frame (spread over the frame as a steady acceleration, so the
-- swing does not depend on the frame rate).
function BikeCamera:_stepBoom(deltaTime, speedChange)
	local config = self.config
	local omega = 2 * math.pi * config.BoomFrequency
	local damping = 2 * config.BoomDampingRatio * omega
	local time = math.min(deltaTime, MAX_BOOM_TIME)
	local steps = math.ceil(time / BOOM_SUBSTEP)

	if steps == 0 then
		self.boomVelocity += speedChange
	end

	for _ = 1, steps do
		local step = time / steps

		self.boomVelocity += (speedChange / time - omega * omega * self.boom - damping * self.boomVelocity) * step
		self.boom += self.boomVelocity * step
	end

	local limit = config.MaxBoomRatio * self.zoomDistance

	if math.abs(self.boom) > limit then
		self.boom = math.clamp(self.boom, -limit, limit)
		self.boomVelocity = 0
	end
end

-- How far from origin the view is open along direction (unit), within
-- distance; nil when nothing blocks it.
function BikeCamera:_openDistance(origin, direction, distance)
	local world = self.world

	if world == nil then
		return nil
	end

	for _ = 1, MAX_CASTS do
		local hit = world:Spherecast(origin, self.config.CollisionRadius, direction * distance, self.castParams)

		if hit == nil then
			return nil
		end

		if blocksView(hit.Instance) then
			return hit.Distance
		end

		-- See through it from now on (until the ride ends).
		if #self.seeThrough >= MAX_SEE_THROUGH_PARTS then
			table.clear(self.seeThrough)
		end

		table.insert(self.seeThrough, hit.Instance)
		self:_refreshFilter()
	end

	return nil
end

--[=[
	One render frame. view:
	  frame       CFrame of the bike's chassis part
	  velocity    the chassis's velocity (studs/s)
	  frontAxle   front and rear wheel centers (optional; the slope)
	  rearAxle
	  head        the rider's head position (helmet view; without it the
	              helmet view sits at the chase view's focus point)
	Returns the camera CFrame, its focus CFrame and the field of view (deg).
]=]
function BikeCamera:update(deltaTime, view)
	local config = self.config
	local frame = view.frame
	local velocity = view.velocity
	local focus = frame.Position + Vector3.yAxis * config.FocusHeight

	deltaTime = math.max(deltaTime, 0)

	if self.lastFocus == nil
		or (focus - self.lastFocus).Magnitude > velocity.Magnitude * deltaTime + TELEPORT_DISTANCE
	then
		self:reset(view)
	end

	self.lastFocus = focus

	local helmet = self:showsHelmet()
	local groundSpeed = horizontal(velocity).Magnitude
	-- The trailer turns toward the bike's heading at speed / hitch length,
	-- within RecenterRate and MaxFollowRate; the helmet turns with the head.
	local rate = helmet and HELMET_RESPONSE
		or math.clamp(groundSpeed / config.HitchLength, config.RecenterRate, config.MaxFollowRate)
	local flat = horizontal(frame.LookVector)

	-- Pointing straight up or down, the bike has no heading: keep the last.
	if flat.Magnitude > 0.2 then
		local heading = yawOf(flat)
		-- Exact over the frame for a bike turning at a steady rate, so the
		-- lag is the same at any frame rate.
		local turned = wrapAngle(heading - self.heading)
		local decay = math.exp(-rate * deltaTime)
		local follow = rate * deltaTime > 1e-6 and (1 - decay) / (rate * deltaTime) or 1
		local lag = wrapAngle(self.heading - self.yaw) * decay + turned * follow
		local maxLag = math.rad(config.MaxLag)

		self.yaw = heading - math.clamp(lag, -maxLag, maxLag)
		self.heading = heading
	end

	local slopeTarget = helmet and math.asin(math.clamp(frame.LookVector.Y, -1, 1))
		or slopeOf(view, self.radiusDifference) * config.SlopeFollow

	self.slope = approach(self.slope, slopeTarget, rate, deltaTime)
	self.roll = approach(
		self.roll,
		leanOf(frame) * (helmet and self.helmetRoll or config.LeanRoll),
		helmet and HELMET_RESPONSE or ROLL_RESPONSE,
		deltaTime
	)

	-- A moment after the last look-around input the view swings back.
	self.lookIdle += deltaTime

	if not self.lookHeld and self.lookIdle > config.LookReturnDelay then
		local keep = math.exp(-config.LookReturnRate * deltaTime)

		self.orbitYaw = wrapAngle(self.orbitYaw) * keep
		self.orbitPitch *= keep
	end

	local pitch = math.clamp(self:_basePitch() + self.orbitPitch, MIN_PITCH, MAX_PITCH)
	local rotation = CFrame.Angles(0, self.yaw, 0)
		* CFrame.Angles(self.slope, 0, 0)
		* CFrame.Angles(0, 0, self.roll)
		* CFrame.Angles(0, self.orbitYaw + (self.lookBack and math.pi or 0), 0)
		* CFrame.Angles(pitch, 0, 0)

	self.fieldOfView = approach(
		self.fieldOfView,
		self:_fieldOfViewTarget(velocity, helmet),
		FIELD_OF_VIEW_RESPONSE,
		deltaTime
	)

	-- The boom swings with the bike's speed change along the view.
	local along = horizontal(rotation.LookVector)
	local change = velocity - self.lastVelocity
	local speedChange = 0

	self.lastVelocity = velocity

	if along.Magnitude > 0.1 then
		speedChange = math.clamp(change:Dot(along.Unit), -MAX_BOOM_IMPULSE, MAX_BOOM_IMPULSE)
	end

	self.zoomDistance = approach(self.zoomDistance, self.zoomTarget, ZOOM_RESPONSE, deltaTime)
	self:_stepBoom(deltaTime, speedChange)

	local position

	if helmet then
		position = view.head or focus
		self.limit = math.huge
		self.distance = 0
	else
		local distance = math.max(self.zoomDistance + self.boom, 1)
		local back = -rotation.LookVector
		local open = self:_openDistance(focus, back, distance) or math.huge

		if open <= self.limit then
			-- Something came into the way: in front of it at once.
			self.limit = open
		else
			-- It went away: ease back out.
			self.limit = approach(self.limit, math.min(open, distance), config.ZoomResponse, deltaTime)

			if self.limit >= distance - 0.01 then
				self.limit = math.huge
			end
		end

		self.distance = math.min(distance, self.limit)
		position = focus + back * self.distance
	end

	self.cframe = CFrame.new(position) * rotation

	return self.cframe, CFrame.new(focus), self.fieldOfView
end

return BikeCamera
