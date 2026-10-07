local Players = game:GetService("Players")

local bike = script.Parent
local vehicleSeat = bike:WaitForChild("VehicleSeat")
local settings = require(bike:WaitForChild("BikeConfig"))

local promptSettings = settings.Mount or {}

local attachment = vehicleSeat:FindFirstChild("BikeMountPromptAttachment")

if attachment == nil then
	attachment = Instance.new("Attachment")
	attachment.Name = "BikeMountPromptAttachment"
	attachment.Position = Vector3.new(0, 1, 0)
	attachment.Parent = vehicleSeat
end

assert(
	attachment:IsA("Attachment"),
	"BikeMountPromptAttachment must be an Attachment"
)

local prompt = attachment:FindFirstChild("BikeMountPrompt")

if prompt == nil then
	prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BikeMountPrompt"
	prompt.Parent = attachment
end

assert(
	prompt:IsA("ProximityPrompt"),
	"BikeMountPrompt must be a ProximityPrompt"
)

prompt.ActionText = promptSettings.ActionText or "Ride"
prompt.ObjectText = promptSettings.ObjectText or "Motorcycle"
prompt.KeyboardKeyCode = Enum.KeyCode.E
prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
prompt.HoldDuration = promptSettings.HoldDuration or 0.6
prompt.MaxActivationDistance = promptSettings.MaxActivationDistance or 8
prompt.RequiresLineOfSight = promptSettings.RequiresLineOfSight == true
prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton

-- Prevent the VehicleSeat from mounting a character just by touching it.
vehicleSeat.CanTouch = false

local mountingPlayers = {}

-- The ride prompt shows only while the seat is free.
local function refreshPrompt()
	prompt.Enabled = vehicleSeat.Occupant == nil
end

-- The player's living humanoid and root part, or nil.
local function getMountCharacter(player)
	local character = player.Character

	if character == nil then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	if humanoid == nil or rootPart == nil or humanoid.Health <= 0 then
		return nil, nil
	end

	return humanoid, rootPart
end

prompt.Triggered:Connect(function(player)
	if not Players:FindFirstChild(player.Name) then
		return
	end

	if mountingPlayers[player] or vehicleSeat.Occupant ~= nil then
		return
	end

	local humanoid, rootPart = getMountCharacter(player)

	if humanoid == nil or humanoid.SeatPart ~= nil then
		return
	end

	local maximumDistance = prompt.MaxActivationDistance + 2

	if (rootPart.Position - vehicleSeat.Position).Magnitude > maximumDistance then
		return
	end

	mountingPlayers[player] = true
	prompt.Enabled = false

	vehicleSeat:Sit(humanoid)

	task.delay(1, function()
		mountingPlayers[player] = nil
		refreshPrompt()
	end)
end)

vehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(refreshPrompt)

Players.PlayerRemoving:Connect(function(player)
	mountingPlayers[player] = nil
end)

refreshPrompt()
