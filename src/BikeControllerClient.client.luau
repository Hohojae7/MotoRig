--[[
	BikeControllerClient

	Runs on the rider's client while it owns the bike. Each physics frame it
	hands rider input to BikeDynamics.RiderControls (linked brakes and ABS,
	traction control, paddle-shifted sequential gearbox), steps BikeDynamics (chassis,
	tires, engine and clutch), animates the visual wheels and fork, poses
	the rider (BikeRiderPose), sends the visual state to the other players
	(BikeVisualSync), hands the engine state to the engine sound
	(BikeSound, played by BikeSoundClient) and publishes the gear, speed,
	ABS and traction control for the HUD (BikeDashboardClient).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local screenGui = script.Parent
local bike = screenGui:WaitForChild("BikeModel").Value

-- The controller's state, a local attribute on the bike (Studio lists it
-- with the bike's attributes); a failure also goes to the Output.
local function setStatus(text)
	bike:SetAttribute("BikeControllerStatus", text)

	if string.sub(text, 1, 5) == "ERROR" then
		warn("[BikeControllerClient] " .. text)
	end
end

setStatus("starting")

local WAIT_TIMEOUT = 10
local RIG_READY_TIMEOUT = 30

local configModule = bike:WaitForChild("BikeConfig", WAIT_TIMEOUT)
local dynamicsModule = bike:WaitForChild("BikeDynamics", WAIT_TIMEOUT)
local riderPoseModule = bike:WaitForChild("BikeRiderPose", WAIT_TIMEOUT)
local syncModule = bike:WaitForChild("BikeVisualSync", WAIT_TIMEOUT)
local soundModule = bike:WaitForChild("BikeSound", WAIT_TIMEOUT)
local seat = bike:WaitForChild("VehicleSeat", WAIT_TIMEOUT)
local serverScript = bike:WaitForChild("BikeServer", WAIT_TIMEOUT)
local remote = serverScript and serverScript:WaitForChild("BikeRemote", WAIT_TIMEOUT)
local stateFolder = bike:WaitForChild("BikeState", WAIT_TIMEOUT)
local engineOn = stateFolder and stateFolder:WaitForChild("EngineOn", WAIT_TIMEOUT)
local inputEvent = screenGui:WaitForChild("BikeInputEvent", WAIT_TIMEOUT)

if not (configModule and dynamicsModule and seat and remote and engineOn and inputEvent) then
	setStatus("ERROR: bike scripts missing (restart rojo serve, then check BikeServer status)")

	return
end

local configLoaded, config = pcall(require, configModule)
local dynamicsLoaded, BikeDynamics = pcall(require, dynamicsModule)

if not (configLoaded and dynamicsLoaded) then
	setStatus("ERROR: require failed: " .. tostring(configLoaded and BikeDynamics or config))

	return
end

local readyAttribute = BikeDynamics.Names.ReadyAttribute
local rigDeadline = os.clock() + RIG_READY_TIMEOUT

setStatus("waiting for rig")

while bike:GetAttribute(readyAttribute) ~= true do
	if os.clock() >= rigDeadline then
		setStatus("ERROR: rig never became ready (see SERVER status)")

		return
	end

	task.wait(0.1)
end

local missingRigPart = BikeDynamics.waitForRig(bike, config, WAIT_TIMEOUT)

if missingRigPart then
	setStatus("ERROR: rig part did not stream in: " .. missingRigPart)

	return
end

local dynamicsCreated, dynamics = pcall(BikeDynamics.new, bike, config)

if not dynamicsCreated then
	setStatus("ERROR: " .. tostring(dynamics))

	return
end

local rider = BikeDynamics.RiderControls.new(dynamics)

-- Riding pose of the avatar. It only changes looks, so a problem with it
-- turns the pose off and the bike keeps running.
local poseLoaded, RiderPose = false, nil

if riderPoseModule then
	poseLoaded, RiderPose = pcall(require, riderPoseModule)
end

local riderPose = poseLoaded and RiderPose.new(config) or nil

-- What the pose is doing (a local attribute on the bike).
local function setPoseStatus(text)
	bike:SetAttribute("BikeRiderPose", text)
end

-- Turns the riding pose off after a failure; the bike keeps running.
local function dropPose(problem)
	if riderPose then
		pcall(riderPose.detach, riderPose)
		riderPose = nil
		setPoseStatus("off: " .. tostring(problem))
		warn("[BikeControllerClient] riding pose off: " .. tostring(problem))
	end
end

if not poseLoaded then
	setPoseStatus("unavailable: " .. tostring(RiderPose))
	warn("[BikeControllerClient] riding pose unavailable: " .. tostring(RiderPose))
end

-- What this bike's visual parts show goes to the other players
-- (BikeVisualSync); without it only this screen sees them move.
local syncLoaded, VisualSync = false, nil

if syncModule then
	syncLoaded, VisualSync = pcall(require, syncModule)
end

local visualRemote = serverScript:WaitForChild("BikeVisualRemote", WAIT_TIMEOUT)
local syncElapsed = 0

if not (syncLoaded and visualRemote) then
	warn("[BikeControllerClient] other players will not see this bike move: " .. tostring(VisualSync))
end

-- Sends the visual state to the other players, Sync.SendRate times a second.
local function sendVisualState(deltaTime)
	syncElapsed += deltaTime

	if syncElapsed < 1 / config.Sync.SendRate or not (syncLoaded and visualRemote) then
		return
	end

	syncElapsed = 0
	visualRemote:FireServer(VisualSync.pack(dynamics.visual, dynamics.state.engineRPM or 0, rider.throttle, rider.gear))
end

-- The engine state for the engine sound, every frame (BikeSound); without
-- it the bike just stays silent.
local soundLoaded, BikeSound = false, nil

if soundModule then
	soundLoaded, BikeSound = pcall(require, soundModule)
end

if not soundLoaded then
	warn("[BikeControllerClient] no engine sound: " .. tostring(BikeSound))
end

-- Hands the engine state to the engine sound (every frame).
local function publishSound()
	if soundLoaded then
		local state = dynamics.state

		BikeSound.publish(bike, state.engineRPM or 0, rider.throttle, rider.gear, state.revLimited == true)
	end
end

setStatus("ready")

-- The HUD's numbers go out this often (Hz), as a dashboard display updates.
local HUD_RATE = 10

local diagnostics = config.Diagnostics ~= nil and config.Diagnostics.Enabled == true
local lastDriveState = nil
local hudElapsed = 0
local active = false

-- One rider input from BikeInputClient (an attribute on this GUI).
local function readInput(name)
	return screenGui:GetAttribute(name) or 0
end

-- What the HUD shows besides the engine state: gear, revs, speed and the
-- ABS and traction control lights (local attributes). With diagnostics on,
-- each change of drive state is a line in the Output.
local function publishHud(deltaTime)
	hudElapsed += deltaTime

	if hudElapsed < 1 / HUD_RATE then
		return
	end

	hudElapsed = 0

	local state = dynamics.state
	local gear = rider.gear

	bike:SetAttribute("BikeGear", gear)
	bike:SetAttribute("BikeRPM", state.engineRPM)
	bike:SetAttribute("BikeSpeed", state.speed)
	-- Below 1 while traction control takes throttle.
	bike:SetAttribute("BikeTractionScale", rider.tractionScale)
	bike:SetAttribute("BikeFrontABS", state.front.absActive == true)
	bike:SetAttribute("BikeRearABS", state.rear.absActive == true)

	local driveState = rider.driveState

	if driveState ~= lastDriveState and diagnostics then
		lastDriveState = driveState
		print(
			string.format(
				"[BikeDriveState] %s | gear=%s | speed=%.2f | rpm=%.0f | wheel torque=%.1f | traction=%.2f | lean=%.1f (shown %.1f)",
				driveState,
				gear == 0 and "N" or gear < 0 and "R" or tostring(gear),
				state.forwardSpeed,
				state.engineRPM,
				state.wheelDriveTorque,
				rider.tractionScale,
				math.deg(state.lean),
				math.deg(state.leanCommand)
			)
		)
	end
end

-- The local player is seated on this bike and the server made them its driver.
local function isDriver()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	return humanoid ~= nil and seat.Occupant == humanoid and bike:GetAttribute("BikeDriverUserId") == player.UserId
end

-- One physics frame: rider controls, dynamics, visuals, pose, sound, HUD.
local function stepFrame(deltaTime)
	local controls = rider:update(deltaTime, {
		throttle = readInput("InputThrottle"),
		brake = readInput("InputBrake"),
		rearBrake = readInput("InputRearBrake"),
		steer = readInput("InputSteer"),
		engineOn = engineOn.Value,
	})

	dynamics:step(deltaTime, controls)
	dynamics:updateVisuals(deltaTime)
	sendVisualState(deltaTime)

	if riderPose then
		local posed, problem = pcall(riderPose.update, riderPose, deltaTime, dynamics)

		if not posed then
			dropPose(problem)
		end
	end

	publishSound()
	publishHud(deltaTime)
end

local physicsConnection

physicsConnection = RunService.PreSimulation:Connect(function(deltaTime)
	if not isDriver() then
		if active then
			active = false
			dynamics:resetVisuals()

			if riderPose then
				riderPose:detach()
			end

			setStatus("idle")
		end

		return
	end

	if not active then
		active = true
		dynamics:reset()
		rider:reset()

		if riderPose then
			local called, attached, detail = pcall(riderPose.attach, riderPose, player.Character, dynamics)

			if not called then
				dropPose(attached)
			elseif attached then
				setPoseStatus(detail)
			else
				-- An avatar rig it does not know keeps its own sitting pose.
				setPoseStatus("off: " .. tostring(detail))
				warn("[BikeControllerClient] riding pose off: " .. tostring(detail))
			end
		end

		setStatus("running")
	end

	local stepped, problem = pcall(stepFrame, deltaTime)

	if not stepped then
		-- Stop and show the error instead of repeating it every frame.
		physicsConnection:Disconnect()
		setStatus("ERROR: " .. tostring(problem))
	end
end)

local inputConnection = inputEvent.Event:Connect(function(action)
	if action == "ShiftUp" then
		rider:shiftUp()
	elseif action == "ShiftDown" then
		rider:shiftDown()
	elseif action == "Neutral" then
		rider:selectNeutral()
	elseif action == "ToggleEngine" then
		remote:FireServer("ToggleEngine")
	elseif action == "Exit" then
		remote:FireServer("Exit")
	end
end)

script.Destroying:Connect(function()
	physicsConnection:Disconnect()
	inputConnection:Disconnect()
	dynamics:resetVisuals()

	if riderPose then
		riderPose:detach()
	end
end)
