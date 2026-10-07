--[[
	BikeInputClient

	Rider input. Continuous inputs are written as attributes on this
	ScreenGui (InputThrottle, InputBrake, InputRearBrake, InputSteer);
	discrete actions go through the BikeInputEvent bindable.
	The dashboard is the bike's own BikeDashboardClient, so it shows even
	when the bike failed to start.

	Keyboard: W/Up throttle, S/Down brake (both brakes, linked; held 1 s in
	neutral at a standstill: reverse), A/D or Left/Right lean, B rear
	brake, F engine, Space get off. Gears (order 1-N-2-3-4-5-6): LeftShift
	up, RightShift down, N neutral. A bike is left in neutral: when nobody
	rides it, it holds itself with both brakes (BikeServer).
	Gamepad: left stick lean, R2 throttle, L2 brake (and reverse), R1 up /
	L1 down (both = neutral), Select engine, A get off.
	Touch: the bike's touch controls (BikeDashboardClient on a touch screen,
	or a map's own) leave local attributes on the bike: held values
	(BikeTouchThrottle, BikeTouchBrake, BikeTouchSteer) taken with the keys
	and sticks, and press counters (BikeTouchShiftUp, ...) that fire the
	action once per press.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local screenGui = script.Parent
local bike = screenGui:WaitForChild("BikeModel").Value
local seat = bike:WaitForChild("VehicleSeat")
local inputEvent = screenGui:WaitForChild("BikeInputEvent")

-- Left stick deflection below this does not lean.
local STICK_DEADZONE = 0.15
-- Touch controls: held values, and press counters with the action each
-- press fires (at most MAX_TOUCH_PRESSES from one jump of a counter).
local TOUCH_HELD = {
	throttle = "BikeTouchThrottle",
	brake = "BikeTouchBrake",
	steer = "BikeTouchSteer",
}
local TOUCH_PRESSES = {
	BikeTouchShiftUp = "ShiftUp",
	BikeTouchShiftDown = "ShiftDown",
	BikeTouchNeutral = "Neutral",
	BikeTouchEngine = "ToggleEngine",
	BikeTouchExit = "Exit",
}
local MAX_TOUCH_PRESSES = 3
-- The gamepad bumpers are gear paddles; both pulled within this time (s)
-- count as pulled together (neutral), even if the first was already let go.
-- The keyboard has a neutral key instead: Windows reports both Shift keys
-- as one key and loses track of them when both are held, so a Shift chord
-- cannot be read reliably.
local BUMPER_CHORD_TIME = 0.2
local BUMPERS = {
	up = Enum.KeyCode.ButtonR1,
	down = Enum.KeyCode.ButtonL1,
}

local held = {
	left = false,
	right = false,
	throttleKey = false,
	brakeKey = false,
	rearBrakeKey = false,
}
local analog = {
	stick = 0,
	throttle = 0,
	brake = 0,
}
-- Gamepad bumpers held down, and when each was last pulled.
local bumpers = {
	up = false,
	down = false,
}
local bumperPulled = {
	up = -math.huge,
	down = -math.huge,
}
local connections = {}

-- The local player sits on this bike's seat.
local function isLocalRider()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	return humanoid ~= nil and seat.Occupant == humanoid
end

-- A held touch value, only while the local player rides (so a value left
-- behind never drives the bike).
local function touchValue(name, rider)
	local value = rider and bike:GetAttribute(name)

	return type(value) == "number" and value or 0
end

-- Merges keys, gamepad and touch into the rider input the controller
-- reads (attributes on the rider GUI).
local function publishInputs()
	local keyboardSteer = 0

	if held.left ~= held.right then
		keyboardSteer = held.left and 1 or -1
	end

	local rider = isLocalRider()
	local touchSteer = touchValue(TOUCH_HELD.steer, rider)
	-- Positive steer = left, matching BikeDynamics. A stick, then a touch,
	-- then the keys.
	local steer = math.abs(analog.stick) > 0 and analog.stick
		or math.abs(touchSteer) > 0 and touchSteer
		or keyboardSteer

	screenGui:SetAttribute("InputSteer", math.clamp(steer, -1, 1))
	screenGui:SetAttribute(
		"InputThrottle",
		math.clamp(math.max(held.throttleKey and 1 or 0, analog.throttle, touchValue(TOUCH_HELD.throttle, rider)), 0, 1)
	)
	screenGui:SetAttribute(
		"InputBrake",
		math.clamp(math.max(held.brakeKey and 1 or 0, analog.brake, touchValue(TOUCH_HELD.brake, rider)), 0, 1)
	)
	screenGui:SetAttribute("InputRearBrake", held.rearBrakeKey and 1 or 0)
end

-- Lets go of everything (the player left the seat).
local function clearInputs()
	for key in held do
		held[key] = false
	end

	bumpers.up = false
	bumpers.down = false
	bumperPulled.up = -math.huge
	bumperPulled.down = -math.huge

	analog.stick = 0
	analog.throttle = 0
	analog.brake = 0
	publishInputs()
end

-- keyCode is one of the given keys.
local function matches(keyCode, ...)
	for _, candidate in { ... } do
		if keyCode == candidate then
			return true
		end
	end

	return false
end

-- A bumper pulled while the other is held (by our record or the input
-- service's own button state), or just after it, selects neutral.
local function pullBumper(side)
	local other = side == "up" and "down" or "up"
	local now = os.clock()
	local together = bumpers[other]
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, BUMPERS[other])
		or now - bumperPulled[other] <= BUMPER_CHORD_TIME

	bumpers[side] = true
	bumperPulled[side] = now

	if together then
		-- Neutral also cancels the shift the first bumper has just started.
		inputEvent:Fire("Neutral")
	else
		inputEvent:Fire(side == "up" and "ShiftUp" or "ShiftDown")
	end
end

-- gameProcessed is not checked: the default character controls also bind
-- WASD/Space, and chat typing is already caught by the focused text box.
local function onInputBegan(input)
	if UserInputService:GetFocusedTextBox() or not isLocalRider() then
		return
	end

	local keyCode = input.KeyCode

	if matches(keyCode, Enum.KeyCode.W, Enum.KeyCode.Up) then
		held.throttleKey = true
	elseif matches(keyCode, Enum.KeyCode.S, Enum.KeyCode.Down) then
		held.brakeKey = true
	elseif matches(keyCode, Enum.KeyCode.A, Enum.KeyCode.Left) then
		held.left = true
	elseif matches(keyCode, Enum.KeyCode.D, Enum.KeyCode.Right) then
		held.right = true
	elseif keyCode == Enum.KeyCode.B then
		held.rearBrakeKey = true
	elseif keyCode == Enum.KeyCode.LeftShift then
		inputEvent:Fire("ShiftUp")
	elseif keyCode == Enum.KeyCode.RightShift then
		inputEvent:Fire("ShiftDown")
	elseif keyCode == Enum.KeyCode.N then
		inputEvent:Fire("Neutral")
	elseif keyCode == BUMPERS.up then
		pullBumper("up")
	elseif keyCode == BUMPERS.down then
		pullBumper("down")
	elseif matches(keyCode, Enum.KeyCode.F, Enum.KeyCode.ButtonSelect) then
		inputEvent:Fire("ToggleEngine")
	elseif matches(keyCode, Enum.KeyCode.Space, Enum.KeyCode.ButtonA) then
		inputEvent:Fire("Exit")
	end

	publishInputs()
end

-- Releases count even off the bike, so no key stays held.
local function onInputEnded(input)
	local keyCode = input.KeyCode

	if matches(keyCode, Enum.KeyCode.W, Enum.KeyCode.Up) then
		held.throttleKey = false
	elseif matches(keyCode, Enum.KeyCode.S, Enum.KeyCode.Down) then
		held.brakeKey = false
	elseif matches(keyCode, Enum.KeyCode.A, Enum.KeyCode.Left) then
		held.left = false
	elseif matches(keyCode, Enum.KeyCode.D, Enum.KeyCode.Right) then
		held.right = false
	elseif keyCode == Enum.KeyCode.B then
		held.rearBrakeKey = false
	elseif keyCode == BUMPERS.up then
		bumpers.up = false
	elseif keyCode == BUMPERS.down then
		bumpers.down = false
	elseif keyCode == Enum.KeyCode.ButtonR2 then
		analog.throttle = 0
	elseif keyCode == Enum.KeyCode.ButtonL2 then
		analog.brake = 0
	end

	publishInputs()
end

-- Analog input: the left stick leans, the triggers are throttle and brake.
local function onInputChanged(input)
	if not isLocalRider() then
		return
	end

	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		local x = input.Position.X
		-- Stick right is positive X; lean right is negative steer.
		analog.stick = math.abs(x) > STICK_DEADZONE and -x or 0
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		analog.throttle = math.clamp(input.Position.Z, 0, 1)
	elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
		analog.brake = math.clamp(input.Position.Z, 0, 1)
	else
		return
	end

	publishInputs()
end

table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
table.insert(connections, UserInputService.InputEnded:Connect(onInputEnded))
table.insert(connections, UserInputService.InputChanged:Connect(onInputChanged))
table.insert(
	connections,
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if not isLocalRider() then
			clearInputs()
		end
	end)
)

for _, name in TOUCH_HELD do
	table.insert(connections, bike:GetAttributeChangedSignal(name):Connect(publishInputs))
end

-- Each press counted since the last change fires its action once; counts
-- from before this script started are not presses.
local pressCounts = {}

-- A touch press counter's value (0 when not set).
local function pressCount(name)
	local count = bike:GetAttribute(name)

	return type(count) == "number" and count or 0
end

for name, action in TOUCH_PRESSES do
	pressCounts[name] = pressCount(name)
	table.insert(
		connections,
		bike:GetAttributeChangedSignal(name):Connect(function()
			local count = pressCount(name)
			local presses = count - pressCounts[name]

			pressCounts[name] = count

			if presses > 0 and isLocalRider() then
				for _ = 1, math.min(presses, MAX_TOUCH_PRESSES) do
					inputEvent:Fire(action)
				end
			end
		end)
	)
end

script.Destroying:Connect(function()
	for _, connection in connections do
		connection:Disconnect()
	end
end)

clearInputs()
