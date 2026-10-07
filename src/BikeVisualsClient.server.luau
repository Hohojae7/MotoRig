--[[
	BikeVisualsClient

	A Script with RunContext Client inside the bike (set in the Rojo
	project): it runs on every player's client, wherever the bike is
	dropped. While someone else rides this bike it poses the bike's visual
	parts (wheels, fork, handlebar, swingarm) and the rider's avatar from
	the state the rider's client sends (BikeVisualSync); joint Transforms do
	not replicate, so every client poses other players' bikes itself. It
	also hands the rider's engine state to this bike's engine sound
	(BikeSound). On the rider's own client BikeControllerClient does both
	instead.

	With StreamingEnabled a far bike's parts are not on this client; it
	starts posing the bike when they stream in, and starts over when they
	stream out and back.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsClient() then
	warn("[BikeVisualsClient] set RunContext to Client; other players' bikes will not move on screen")

	return
end

local WAIT_TIMEOUT = 30
-- How often a bike whose parts are not here looks for them again (s).
local RIG_CHECK_INTERVAL = 0.5

local bike = script.Parent
local player = Players.LocalPlayer
local configModule = bike:WaitForChild("BikeConfig", WAIT_TIMEOUT)
local dynamicsModule = bike:WaitForChild("BikeDynamics", WAIT_TIMEOUT)
local poseModule = bike:WaitForChild("BikeRiderPose", WAIT_TIMEOUT)
local syncModule = bike:WaitForChild("BikeVisualSync", WAIT_TIMEOUT)
local soundModule = bike:WaitForChild("BikeSound", WAIT_TIMEOUT)
local serverScript = bike:WaitForChild("BikeServer", WAIT_TIMEOUT)
local remote = serverScript and serverScript:WaitForChild("BikeVisualRemote", WAIT_TIMEOUT)

if not (configModule and dynamicsModule and poseModule and syncModule and remote) then
	warn("[BikeVisualsClient] bike scripts missing; other players' bikes will not move on screen")

	return
end

local config = require(configModule)
local BikeDynamics = require(dynamicsModule)
local RiderPose = require(poseModule)
local VisualSync = require(syncModule)
local soundLoaded, BikeSound = false, nil

if soundModule then
	soundLoaded, BikeSound = pcall(require, soundModule)
end

if not soundLoaded then
	warn("[BikeVisualsClient] other players' engines will idle in the sound: " .. tostring(BikeSound))
end

while bike:GetAttribute(BikeDynamics.Names.ReadyAttribute) ~= true do
	task.wait(0.2)
end

-- Made when the bike's rig is on this client, remade after it streamed
-- out and back.
local remoteBike = nil
local rigCheckWait = 0

-- Forgets the remote bike (its rig streamed out or it failed).
local function dropRemoteBike()
	if remoteBike then
		pcall(remoteBike.destroy, remoteBike)
		remoteBike = nil
	end
end

-- The remote bike, built once its rig has streamed in.
local function currentRemoteBike(deltaTime)
	if remoteBike and not remoteBike:attached() then
		dropRemoteBike()
	end

	if remoteBike == nil then
		rigCheckWait -= deltaTime

		if rigCheckWait > 0 then
			return nil
		end

		rigCheckWait = RIG_CHECK_INTERVAL

		if BikeDynamics.rigMissing(bike, config) then
			return nil
		end

		remoteBike = VisualSync.RemoteBike.new(bike, config, BikeDynamics, RiderPose)
	end

	return remoteBike
end

-- The local player rides this bike: BikeControllerClient poses it.
local function ridingHere()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart

	return bike:GetAttribute("BikeDriverUserId") == player.UserId
		or (seatPart ~= nil and seatPart:IsDescendantOf(bike))
end

local packetConnection = remote.OnClientEvent:Connect(function(...)
	if remoteBike then
		remoteBike:receive(...)
	end
end)

local stepConnection

stepConnection = RunService.PreSimulation:Connect(function(deltaTime)
	if ridingHere() then
		if remoteBike then
			remoteBike:pause()
		end

		return
	end

	local current = currentRemoteBike(deltaTime)

	if current == nil then
		return
	end

	local stepped, problem = pcall(current.step, current, deltaTime)

	-- Without packets the sound falls back to what it knows (the engine
	-- switch from BikeState).
	if stepped and soundLoaded and current.engineRPM then
		BikeSound.publish(bike, current.engineRPM, current.engineThrottle, current.gear, nil)
	end

	if not stepped then
		-- Stop instead of repeating the same error every frame.
		stepConnection:Disconnect()
		packetConnection:Disconnect()
		dropRemoteBike()
		warn("[BikeVisualsClient] " .. tostring(problem))
	end
end)

script.Destroying:Connect(function()
	stepConnection:Disconnect()
	packetConnection:Disconnect()
	dropRemoteBike()
end)
