--[[
	BikeServer

	Builds the raycast rig once, keeps the bike standing with the same
	BikeDynamics model the rider's client runs, hands network ownership to
	the rider (with Shift Lock off while riding: the gear paddles share its
	keys), and handles engine/exit requests from the rider GUI.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local bike = script.Parent

-- The server's state, an attribute on the bike (Studio lists it with the
-- bike's attributes); a failure also shows in the Output.
local function setStatus(text)
	bike:SetAttribute("BikeServerStatus", text)
end

-- Marks the bike as failed and stops this script with the reason.
local function fail(message)
	setStatus("ERROR: " .. message)
	error("[BikeServer] " .. message, 0)
end

setStatus("starting")

local REQUIRED_TIMEOUT = 10
local configModule = bike:WaitForChild("BikeConfig", REQUIRED_TIMEOUT)
local dynamicsModule = bike:WaitForChild("BikeDynamics", REQUIRED_TIMEOUT)
local seat = bike:WaitForChild("VehicleSeat", REQUIRED_TIMEOUT)
local guiTemplate = script:WaitForChild("BikeGuiTemplate", REQUIRED_TIMEOUT)

if not (configModule and dynamicsModule and seat and guiTemplate) then
	fail("BikeConfig/BikeDynamics/VehicleSeat/BikeGuiTemplate missing; restart rojo serve and reconnect")
end

local configLoaded, config = pcall(require, configModule)
local dynamicsLoaded, BikeDynamics = pcall(require, dynamicsModule)

if not configLoaded then
	fail("require BikeConfig failed: " .. tostring(config))
end

if not dynamicsLoaded then
	fail("require BikeDynamics failed: " .. tostring(BikeDynamics))
end

-- A parked bike that has been still this long stops updating its forces
-- until something moves it.
local SLEEP_LINEAR_SPEED = 0.05
local SLEEP_ANGULAR_SPEED = 0.05
local SLEEP_DELAY = 1

-- Earlier prototypes left these in the place. Rojo keeps unknown instances
-- under the model, so retire them before they add a second ballast.
for _, name in { "BikeMassDiagnostics", "BikeMassExperiment" } do
	local legacy = bike:FindFirstChild(name)

	if legacy and legacy:IsA("BaseScript") then
		legacy.Enabled = false
		legacy:Destroy()
	end
end

for _, descendant in bike:GetDescendants() do
	if
		descendant:IsA("BasePart") and (descendant.Name == "BikeMassBallast" or descendant.Name == "MassTestBallast")
	then
		descendant:Destroy()
	end
end

local rigBuilt, rigProblem = pcall(BikeDynamics.buildRig, bike, config)

if not rigBuilt then
	fail("rig build failed: " .. tostring(rigProblem))
end

-- Let the engine rebuild the assembly so AssemblyMass includes the new
-- ballast and axle masses before the dynamics model reads it.
RunService.PostSimulation:Wait()

local frame = bike.PrimaryPart
local dynamicsCreated, dynamics = pcall(BikeDynamics.new, bike, config)

if not dynamicsCreated then
	fail("dynamics init failed: " .. tostring(dynamics))
end

local stateFolder = Instance.new("Folder")
stateFolder.Name = "BikeState"

local engineOn = Instance.new("BoolValue")
engineOn.Name = "EngineOn"
engineOn.Parent = stateFolder
stateFolder.Parent = bike

local remote = Instance.new("RemoteEvent")
remote.Name = "BikeRemote"
remote.Parent = script

-- The rider's visual state for the other players (BikeVisualSync); packets
-- may be lost, a newer one follows.
local visualRemote = Instance.new("UnreliableRemoteEvent")
visualRemote.Name = "BikeVisualRemote"
visualRemote.Parent = script

local syncModule = bike:FindFirstChild("BikeVisualSync")
local syncLoaded, VisualSync = false, nil

if syncModule then
	syncLoaded, VisualSync = pcall(require, syncModule)
end

if not syncLoaded then
	warn("[BikeServer] other players will not see this bike's wheels and rider move: " .. tostring(VisualSync))
end

-- Rider mass policy: avatar parts become massless while seated so the
-- avatar package does not change handling.
local masslessOriginals = {}
local riderMassConnection = nil

-- Gives the rider's parts back their own Massless setting.
local function restoreRiderMass()
	if riderMassConnection then
		riderMassConnection:Disconnect()
		riderMassConnection = nil
	end

	for part, wasMassless in masslessOriginals do
		if part.Parent then
			part.Massless = wasMassless
		end
	end

	table.clear(masslessOriginals)
end

-- Makes one avatar part massless, remembering its setting.
local function makePartMassless(object)
	if object:IsA("BasePart") and masslessOriginals[object] == nil then
		masslessOriginals[object] = object.Massless
		object.Massless = true
	end
end

-- Makes the whole avatar massless, parts added later included.
local function makeRiderMassless(character)
	restoreRiderMass()

	for _, descendant in character:GetDescendants() do
		makePartMassless(descendant)
	end

	riderMassConnection = character.DescendantAdded:Connect(makePartMassless)
end

-- Physics ownership: the rider's client while riding, the server (nil) after.
local function setNetworkOwner(player)
	if frame:CanSetNetworkOwnership() then
		frame:SetNetworkOwner(player)
	end
end

local riderPlayer = nil
local riderGui = nil
local restTimer = 0
local sleeping = false

-- LeftShift and RightShift are the gear paddles, and Roblox's Shift Lock
-- (mouse lock) toggles on the same keys, so it is off while riding. Only
-- the server can set it; the rider's own setting comes back on exit.
local riderMouseLock = nil

-- Turns the rider's Shift Lock option on or off.
local function setMouseLock(player, enabled)
	local changed, problem = pcall(function()
		player.DevEnableMouseLock = enabled
	end)

	if not changed then
		warn("[BikeServer] Shift Lock left as it is: " .. tostring(problem))
	end
end

-- The rider got off: hand everything back and park the bike.
local function releaseRider()
	if riderGui then
		riderGui:Destroy()
		riderGui = nil
	end

	if riderPlayer and riderMouseLock ~= nil then
		setMouseLock(riderPlayer, riderMouseLock)
	end

	riderMouseLock = nil
	restoreRiderMass()
	riderPlayer = nil
	bike:SetAttribute("BikeDriverUserId", 0)
	setNetworkOwner(nil)
	dynamics:reset()
	restTimer = 0
	sleeping = false

	if config.Engine.StopOnDismount then
		engineOn.Value = false
	end
end

-- A rider sat down: ownership, the rider GUI with its controller, the engine.
local function attachRider(player, character)
	riderPlayer = player

	if config.Mass.RiderMassless then
		makeRiderMassless(character)
	end

	bike:SetAttribute("BikeDriverUserId", player.UserId)
	setNetworkOwner(player)

	local read, mouseLock = pcall(function()
		return player.DevEnableMouseLock
	end)

	if read then
		riderMouseLock = mouseLock
		setMouseLock(player, false)
	end

	local gui = guiTemplate:Clone()
	gui.ResetOnSpawn = false

	local reference = Instance.new("ObjectValue")
	reference.Name = "BikeModel"
	reference.Value = bike
	reference.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")
	riderGui = gui

	if config.Engine.AutoStartOnMount then
		engineOn.Value = true
	end
end

-- The seat's occupant changed: release the old rider, attach the new one.
local function onOccupantChanged()
	local humanoid = seat.Occupant
	local character = humanoid and humanoid.Parent
	local player = character and Players:GetPlayerFromCharacter(character)

	if player == riderPlayer then
		return
	end

	if riderPlayer then
		releaseRider()
	end

	if player then
		attachRider(player, character)
	end
end

seat:GetPropertyChangedSignal("Occupant"):Connect(onOccupantChanged)

Players.PlayerRemoving:Connect(function(player)
	if player == riderPlayer then
		releaseRider()
	end
end)

remote.OnServerEvent:Connect(function(player, action)
	if player ~= riderPlayer then
		return
	end

	if action == "ToggleEngine" then
		engineOn.Value = not engineOn.Value
	elseif action == "Exit" then
		-- The seat's own weld to the character (not the chassis SeatWeld).
		local seatWeld = seat:FindFirstChild("SeatWeld")

		if seatWeld and seatWeld:IsA("JointInstance") then
			seatWeld:Destroy()
		end
	end
end)

-- Passes the rider's visual state on to everyone else: only from the
-- rider, only checked numbers, at most twice the rate the rider sends.
local lastVisualPacket = -math.huge

visualRemote.OnServerEvent:Connect(function(player, ...)
	if player ~= riderPlayer or not syncLoaded then
		return
	end

	local now = os.clock()

	if now - lastVisualPacket < 0.5 / config.Sync.SendRate then
		return
	end

	local values = VisualSync.sanitize(...)

	if values == nil then
		return
	end

	lastVisualPacket = now

	for _, other in Players:GetPlayers() do
		if other ~= player then
			visualRemote:FireClient(other, table.unpack(values, 1, VisualSync.PACKET_SIZE))
		end
	end
end)

-- Nobody riding: the server owns the bike and keeps it standing on its
-- suspension with the parking brake set (holding torque from the bike's
-- weight and wheel size, see BikeDynamics:parkingBrakeTorques).
local parkedControls = {
	-- No rider: the stand holds the bike upright instead of steering balance.
	parked = true,
	steer = 0,
	driveTorque = 0,
	frontBrakeTorque = 0,
	rearBrakeTorque = 0,
}

local parkedConnection

parkedConnection = RunService.PreSimulation:Connect(function(deltaTime)
	if riderPlayer then
		return
	end

	local state = dynamics.state
	local resting = frame.AssemblyLinearVelocity.Magnitude < SLEEP_LINEAR_SPEED
		and frame.AssemblyAngularVelocity.Magnitude < SLEEP_ANGULAR_SPEED
		and state.frontGrounded
		and state.rearGrounded

	if resting then
		restTimer += deltaTime
	else
		restTimer = 0
		sleeping = false
	end

	if restTimer >= SLEEP_DELAY then
		sleeping = true
	end

	if not sleeping then
		parkedControls.frontBrakeTorque, parkedControls.rearBrakeTorque = dynamics:parkingBrakeTorques()

		local stepped, problem = pcall(dynamics.step, dynamics, deltaTime, parkedControls)

		if not stepped then
			-- Stop instead of repeating the same error every frame.
			parkedConnection:Disconnect()
			setStatus("ERROR: parked step: " .. tostring(problem))
			warn("[BikeServer] parked step failed: " .. tostring(problem))
		end
	end
end)

bike:SetAttribute("BikeDriverUserId", 0)
setNetworkOwner(nil)
onOccupantChanged()
setStatus("ready")

-- One line per bike in the Output for development (config.Diagnostics).
if config.Diagnostics and config.Diagnostics.Enabled then
	print(
		string.format(
			"[BikeServer] raycast rig ready | mass=%.3f | wheelbase=%.3f | rake=%.1f | front/rear static load=%.1f/%.1f | exterior=%d parts",
			dynamics.mass,
			dynamics.wheelbase,
			math.deg(dynamics.rake),
			dynamics.front.staticLoad,
			dynamics.rear.staticLoad,
			bike:GetAttribute(BikeDynamics.Names.ExteriorAttribute) or 0
		)
	)
end
