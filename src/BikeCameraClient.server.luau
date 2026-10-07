--[[
	BikeCameraClient

	A Script with RunContext Client inside the bike (set in the Rojo
	project): it runs on every player's client wherever the bike is
	dropped, and apart from the rider GUI, so the camera is always given
	back when the rider gets off. While the local player sits on this bike
	it drives the camera with BikeCamera; config.Camera.Enabled = false
	leaves the camera to Roblox.

	Look around: right mouse button drag, right stick or a touch drag (off
	the touch controls and their lean area, BikeTouchLeanArea).
	Zoom: mouse wheel or I / O; all the way in is the helmet view.
	Chase / helmet view: V, gamepad Y or the VIEW touch button. Look back
	(held): C, the right stick button or the BACK touch button.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

if not RunService:IsClient() then
	warn("[BikeCameraClient] set RunContext to Client; the bike camera will not run")

	return
end

local WAIT_TIMEOUT = 30
-- Right stick deflection below this does not turn the view.
local STICK_DEADZONE = 0.2
-- A touch drag turns the view this much more per pixel than the mouse (as
-- Roblox's own camera).
local TOUCH_SCALE = 2.25
-- Marks the camera while a bike drives it (with that bike's token), so a
-- camera a bike left behind is recognised and a bike never takes the
-- camera back from another bike the player has just got on.
local OWNER_ATTRIBUTE = "BikeCameraOwner"

local bike = script.Parent
local player = Players.LocalPlayer

-- The camera's state, a local attribute on the bike (Studio lists it with
-- the bike's attributes).
local function setStatus(text)
	bike:SetAttribute("BikeCamera", text)
end

if UserInputService.VREnabled then
	setStatus("off: VR keeps Roblox's camera")

	return
end

local configModule = bike:WaitForChild("BikeConfig", WAIT_TIMEOUT)
local dynamicsModule = bike:WaitForChild("BikeDynamics", WAIT_TIMEOUT)
local cameraModule = bike:WaitForChild("BikeCamera", WAIT_TIMEOUT)

if not (configModule and dynamicsModule and cameraModule) then
	setStatus("off: bike scripts missing")
	warn("[BikeCameraClient] bike scripts missing; Roblox's camera stays on")

	return
end

local config = require(configModule)
local BikeDynamics = require(dynamicsModule)
local BikeCamera = require(cameraModule)

if not (config.Camera and config.Camera.Enabled) then
	setStatus("off (config)")

	return
end

while bike:GetAttribute(BikeDynamics.Names.ReadyAttribute) ~= true do
	task.wait(0.2)
end

local names = BikeDynamics.Names
local ownerToken = HttpService:GenerateGUID(false)

-- A wheel part's radius (a cylinder along X).
local function wheelRadius(part)
	return math.max(part.Size.Y, part.Size.Z) * 0.5
end

-- The rig parts on this client. With StreamingEnabled they are here only
-- near the player (always while riding), and a part that streams out and
-- back in may come back as a new instance, so they are looked up for every
-- ride. The camera model is made on the first ride.
local frame, seat, frontWheel, rearWheel = nil, nil, nil, nil
local bikeCamera = nil

-- Nil when the rig is here, otherwise what has not streamed in yet.
local function acquireRig()
	local missing = BikeDynamics.rigMissing(bike, config)

	if missing then
		return missing
	end

	local rig = bike:FindFirstChild(names.Folder)

	frame, seat = BikeDynamics.rigParts(bike, config)
	frontWheel = rig:FindFirstChild(names.FrontWheelJoint).Part1
	rearWheel = rig:FindFirstChild(names.RearWheelJoint).Part1

	if bikeCamera == nil then
		bikeCamera = BikeCamera.new(config, {
			topSpeed = BikeCamera.topSpeed(config, BikeDynamics.Powertrain, wheelRadius(rearWheel)),
			frontRadius = wheelRadius(frontWheel),
			rearRadius = wheelRadius(rearWheel),
			world = Workspace,
		})
	end

	return nil
end

-- The rig parts found are still in this bike (not streamed out).
local function rigAttached()
	return frame ~= nil
		and frame:IsDescendantOf(bike)
		and frontWheel:IsDescendantOf(bike)
		and rearWheel:IsDescendantOf(bike)
end

local gameSettings = nil

pcall(function()
	gameSettings = UserSettings():GetService("UserGameSettings")
end)

-- The camera while this bike drives it: { camera, cameraType, fieldOfView }.
local taken = nil
-- Another script took the camera during this ride, or the camera failed:
-- leave it alone until the rider gets off.
local standingDown = false
local lookButton = false
local touches = {}
local stick = Vector2.zero
local hidden = {}
local lastStatus = nil

setStatus("ready")

-- The local player sits on this bike's seat.
local function ridingHere()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart

	return seatPart ~= nil and seatPart:IsDescendantOf(bike)
end

-- Sets the status attribute when it changes.
local function showStatus(status)
	if status ~= lastStatus then
		lastStatus = status
		setStatus(status)
	end
end

-- The rider's head, or where it would be above the seat.
local function headPosition()
	local character = player.Character
	local head = character and character:FindFirstChild("Head")

	if head and head:IsA("BasePart") then
		return head.Position
	end

	return seat.CFrame * Vector3.new(0, seat.Size.Y * 0.5 + 2.6, 0)
end

-- What BikeCamera needs this frame: frame, velocity, axles, head.
local function currentView()
	return {
		frame = frame.CFrame,
		velocity = frame.AssemblyLinearVelocity,
		frontAxle = frontWheel.Position,
		rearAxle = rearWheel.Position,
		head = headPosition(),
	}
end

-- Radians per pixel of mouse drag, and 1 or -1 for the player's inverted
-- camera setting.
local function mouseScale()
	local sensitivity, invert = 1, 1

	if gameSettings then
		pcall(function()
			sensitivity = gameSettings.MouseSensitivity
			invert = gameSettings:GetCameraYInvertValue()
		end)
	end

	return math.rad(config.Camera.MouseSensitivity) * sensitivity, invert
end

-- Hides or shows a part or decal on this screen only.
local function setLocalTransparency(object, value)
	if object:IsA("BasePart") or object:IsA("Decal") then
		object.LocalTransparencyModifier = value
	end
end

-- Helmet view: the rider's head and what is worn on it are hidden on this
-- screen (the camera sits inside the head).
local function hideHead(character)
	local head = character and character:FindFirstChild("Head")

	if head == nil then
		return
	end

	-- Hides an object and everything in it.
	local function hide(object)
		hidden[object] = true
		setLocalTransparency(object, 1)

		for _, descendant in object:GetDescendants() do
			hidden[descendant] = true
			setLocalTransparency(descendant, 1)
		end
	end

	hide(head)

	for _, accessory in character:GetChildren() do
		local handle = accessory:IsA("Accessory") and accessory:FindFirstChild("Handle")
		local attachment = handle and handle:FindFirstChildOfClass("Attachment")

		-- Worn on the head: attached to one of the head's attachments.
		if attachment and head:FindFirstChild(attachment.Name) then
			hide(handle)
		end
	end
end

-- Shows what the helmet view hid.
local function showHead()
	for object in hidden do
		if object.Parent then
			setLocalTransparency(object, 0)
		end
	end

	table.clear(hidden)
end

-- Lets go of looking around and looking back.
local function clearLookInput()
	if lookButton then
		lookButton = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	table.clear(touches)
	stick = Vector2.zero
	bikeCamera:holdLook(false)
	bikeCamera:setLookBack(false)
end

-- Takes the camera for this bike; false if there is none.
local function takeCamera()
	local camera = Workspace.CurrentCamera

	if camera == nil then
		return false
	end

	local missing = acquireRig()

	if missing then
		showStatus("waiting for the bike to stream in: " .. missing)

		return false
	end

	local cameraType = camera.CameraType

	-- Left scriptable by an earlier run of a bike camera: Roblox's own.
	if cameraType == Enum.CameraType.Scriptable and camera:GetAttribute(OWNER_ATTRIBUTE) then
		cameraType = Enum.CameraType.Custom
	end

	taken = { camera = camera, cameraType = cameraType, fieldOfView = camera.FieldOfView }
	camera:SetAttribute(OWNER_ATTRIBUTE, ownerToken)
	camera.CameraType = Enum.CameraType.Scriptable

	local character = player.Character

	-- Roblox's camera fades the avatar when zoomed in; with the camera
	-- scriptable nothing would bring it back.
	for _, descendant in character:GetDescendants() do
		setLocalTransparency(descendant, 0)
	end

	bikeCamera:setIgnore({ bike, character })
	bikeCamera:setZoomLimits(player.CameraMinZoomDistance, player.CameraMaxZoomDistance)

	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		bikeCamera:setView(BikeCamera.Views.Helmet)
	end

	bikeCamera:reset(currentView())

	return true
end

-- restore: put Roblox's camera back (false when another script owns it
-- now). A camera another bike has taken meanwhile is left to that bike.
local function releaseCamera(restore)
	if taken == nil then
		return
	end

	local camera = taken.camera
	local owner = camera:GetAttribute(OWNER_ATTRIBUTE)
	local otherBike = owner ~= nil and owner ~= ownerToken

	showHead()
	clearLookInput()

	if owner == ownerToken then
		camera:SetAttribute(OWNER_ATTRIBUTE, nil)
	end

	if restore and not otherBike and camera.Parent then
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = taken.cameraType
		end

		camera.FieldOfView = taken.fieldOfView

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if humanoid and (camera.CameraSubject == seat or camera.CameraSubject == nil) then
			camera.CameraSubject = humanoid
		end
	end

	taken = nil
	lastStatus = nil
end

-- Leaves the camera alone until the rider gets off; restore as in
-- releaseCamera.
local function standDown(reason, restore)
	releaseCamera(restore)
	standingDown = true
	setStatus("off: " .. reason)
	warn("[BikeCameraClient] " .. reason)
end

-- Every frame: take or give back the camera, then move it.
local function onRender(deltaTime)
	if not ridingHere() then
		if taken then
			releaseCamera(true)
		end

		showStatus("ready")
		standingDown = false

		return
	end

	-- The bike streamed out under the camera: Roblox's camera until it is
	-- back.
	if taken and not rigAttached() then
		releaseCamera(true)
	end

	if standingDown or (taken == nil and not takeCamera()) then
		return
	end

	local camera = taken.camera

	if Workspace.CurrentCamera ~= camera or camera.CameraType ~= Enum.CameraType.Scriptable then
		standDown("another script took the camera", false)

		return
	end

	if stick ~= Vector2.zero then
		local turn = math.rad(config.Camera.StickTurnRate) * deltaTime

		bikeCamera:look(-stick.X * turn, stick.Y * turn)
	end

	local cframe, focus, fieldOfView = bikeCamera:update(deltaTime, currentView())

	camera.CFrame = cframe
	camera.Focus = focus
	camera.FieldOfView = fieldOfView

	if bikeCamera:showsHelmet() then
		hideHead(player.Character)
	elseif next(hidden) then
		showHead()
	end

	showStatus(bikeCamera:describe())
end

local connections = {}

table.insert(connections, RunService.PreRender:Connect(function(deltaTime)
	local ran, problem = pcall(onRender, deltaTime)

	if not ran then
		-- Roblox's camera for the rest of this ride, instead of repeating
		-- the error every frame.
		standDown(tostring(problem), true)
	end
end))

-- A text box (the chat) has focus.
local function typing()
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- C or the right stick button.
local function isLookBack(keyCode)
	return keyCode == Enum.KeyCode.C or keyCode == Enum.KeyCode.ButtonR3
end

-- Where the bike's touch controls lean (a Rect in screen pixels while they
-- are up; BikeDashboardClient or a map's own controls set it): a touch
-- that starts there steers the bike, so it does not turn the view.
local TOUCH_LEAN_AREA = "BikeTouchLeanArea"

-- The position is inside the published lean area.
local function inLeanArea(position)
	local area = bike:GetAttribute(TOUCH_LEAN_AREA)

	return typeof(area) == "Rect"
		and position.X >= area.Min.X
		and position.Y >= area.Min.Y
		and position.X <= area.Max.X
		and position.Y <= area.Max.Y
end

-- Input over the GUI (processed) does not turn or zoom the view; keys are
-- read whatever else uses them, except while typing.
table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
	if taken == nil then
		return
	end

	local inputType = input.UserInputType
	local keyCode = input.KeyCode

	if inputType == Enum.UserInputType.MouseButton2 then
		if not processed then
			lookButton = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			bikeCamera:holdLook(true)
		end
	elseif inputType == Enum.UserInputType.Touch then
		if not processed and not inLeanArea(input.Position) then
			touches[input] = true
			bikeCamera:holdLook(true)
		end
	elseif typing() then
		return
	elseif keyCode == Enum.KeyCode.V or keyCode == Enum.KeyCode.ButtonY then
		bikeCamera:toggleView()
	elseif isLookBack(keyCode) then
		bikeCamera:setLookBack(true)
	elseif keyCode == Enum.KeyCode.I then
		bikeCamera:zoomIn(1)
	elseif keyCode == Enum.KeyCode.O then
		bikeCamera:zoomIn(-1)
	end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
	if taken == nil then
		return
	end

	local inputType = input.UserInputType

	if inputType == Enum.UserInputType.MouseButton2 then
		if lookButton then
			lookButton = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			bikeCamera:holdLook(next(touches) ~= nil)
		end
	elseif inputType == Enum.UserInputType.Touch then
		if touches[input] then
			touches[input] = nil
			bikeCamera:holdLook(lookButton or next(touches) ~= nil)
		end
	elseif isLookBack(input.KeyCode) then
		bikeCamera:setLookBack(false)
	end
end))

table.insert(connections, UserInputService.InputChanged:Connect(function(input, processed)
	if taken == nil then
		return
	end

	local inputType = input.UserInputType

	if inputType == Enum.UserInputType.MouseMovement then
		if lookButton then
			local scale, invert = mouseScale()

			bikeCamera:look(-input.Delta.X * scale, -input.Delta.Y * scale * invert)
		end
	elseif inputType == Enum.UserInputType.MouseWheel then
		if not processed then
			bikeCamera:zoomIn(input.Position.Z)
		end
	elseif inputType == Enum.UserInputType.Touch then
		if touches[input] then
			local scale, invert = mouseScale()

			bikeCamera:look(-input.Delta.X * scale * TOUCH_SCALE, -input.Delta.Y * scale * invert * TOUCH_SCALE)
		end
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local position = Vector2.new(input.Position.X, input.Position.Y)

		stick = position.Magnitude > STICK_DEADZONE and position or Vector2.zero
	end
end))

-- The bike's touch controls (BikeDashboardClient, or a map's own) work the
-- view through local attributes on the bike: a press counter for the view
-- and a held value for looking back.
local TOUCH_VIEW = "BikeTouchView"
local TOUCH_LOOK_BACK = "BikeTouchLookBack"

-- The VIEW button's press counter (0 when not set).
local function touchCount()
	local count = bike:GetAttribute(TOUCH_VIEW)

	return type(count) == "number" and count or 0
end

local viewPresses = touchCount()

table.insert(connections, bike:GetAttributeChangedSignal(TOUCH_VIEW):Connect(function()
	local count = touchCount()
	local pressed = count > viewPresses

	viewPresses = count

	if pressed and taken then
		bikeCamera:toggleView()
	end
end))

table.insert(connections, bike:GetAttributeChangedSignal(TOUCH_LOOK_BACK):Connect(function()
	local value = bike:GetAttribute(TOUCH_LOOK_BACK)

	if taken then
		bikeCamera:setLookBack(type(value) == "number" and value > 0)
	end
end))

script.Destroying:Connect(function()
	for _, connection in connections do
		connection:Disconnect()
	end

	releaseCamera(true)
end)
