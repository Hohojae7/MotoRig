--[[
	BikeDashboardClient

	A Script with RunContext Client inside the bike (set in the Rojo
	project): it runs on every player's client wherever the bike is
	dropped, and shows the rider's HUD to the player sitting on this bike
	only.

	- Meter (config.Dashboard.Enabled), bottom right, after Forza
	  Horizon's: a hairline ring with small numbers to a little past the
	  rev limiter over a soft shadow, a red arc from Dashboard.RedZoneRPM,
	  the needle's tip at the rim, the gear in a ring in the middle (N
	  green, R amber, red in the red zone as the cue to shift up), ABS and
	  TC lights beside it and the speed in large light digits below.
	- Controls (config.Dashboard.Hints), bottom left: one tile per control
	  (ride, gear up, gear down, neutral, engine, view, look back) with its
	  key for the keyboard or the gamepad, whichever was used last. The
	  tile the bike needs now lights up in blue (a racing shift light's
	  color): the engine key while the engine is off, the gear keys in
	  neutral, gear up in the red zone.
	- Touch controls (config.Dashboard.TouchControls), on a touch screen
	  (phone, tablet) while it is the input in use. The left thumb leans
	  (drag left or right on the left part of the screen; the pad comes to
	  the thumb) and shifts (the buttons above it), as a rider's left foot
	  works the gear lever; the right thumb holds the throttle or the
	  brake, as the right hand does. Small buttons on top: engine, neutral,
	  view, look back, get off. While they are up, Roblox's own touch
	  controls are hidden, the meter moves to the top right and the key
	  tiles give way. They work through local attributes on the bike
	  (TOUCH_ATTRIBUTES), which BikeInputClient (riding) and
	  BikeCameraClient (views) read, so a map can bring its own touch
	  controls instead. Like Roblox's own thumbstick, the lean area only
	  takes touches no GUI took (the chat window, the map's buttons) and
	  covers none of them; the camera leaves the touches that start in it
	  alone (BikeTouchLeanArea). With Roblox's camera instead of the
	  bike's (config.Camera.Enabled false) it is a button, which keeps
	  that camera from turning as the thumb leans.

	Everything is drawn with plain GUI frames, without image assets, so the
	bike brings its HUD into any place. It only reads what the bike
	publishes: BikeState.EngineOn (server), the engine state every frame
	(BikeSound.Attributes) and the speed, gear, ABS and traction control
	the rider's controller publishes for it (BikeSpeed and the rest).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

if not RunService:IsClient() then
	warn("[BikeDashboardClient] set RunContext to Client; the dashboard will not show")

	return
end

local WAIT_TIMEOUT = 30
-- Published engine state older than this is stale (s).
local ENGINE_STALE_TIME = 0.5
-- Speed units per m/s.
local UNIT_SCALE = {
	["km/h"] = 3.6,
	mph = 3600 / 1609.344,
}
-- Traction control counts as working when it takes this much throttle.
local TRACTION_LAMP_SCALE = 0.98

-- Layout in pixels at UI scale 1, which is a 1000-pixel-high screen.
local REFERENCE_HEIGHT = 1000
local MIN_UI_SCALE = 0.6
local MAX_UI_SCALE = 1.25
local SCREEN_MARGIN = 24

-- Meter: dial diameter; the scale sweeps this many degrees, centered on
-- the top, so the speed sits in the gap at the bottom.
local DIAL_SIZE = 290
local DIAL_SWEEP = 270
-- The scale's ring: the middle of its line this far inside the dial's
-- edge; the red zone's arc lies on it, wider.
local RING_INSET = 3
local RING_WIDTH = 1.5
local RING_TRANSPARENCY = 0.45
local RED_ARC_WIDTH = 4
-- A tick inside the ring every 1000 rpm, longer at the numbered ones.
local TICK_LENGTH = 8
local MINOR_TICK_LENGTH = 5
local TICK_WIDTH = 1.5
local TICK_TRANSPARENCY = 0.35
-- The numbers, this far inside the ring.
local LABEL_INSET = 19
local LABEL_TRANSPARENCY = 0.2
-- No solid disc: a soft shadow darkens the scene behind the dial,
-- SHADE_DARKNESS out to SHADE_CORE of its reach (SHADE_REACH times the
-- dial), then fading smoothly to nothing, drawn as SHADE_STEPS faint
-- discs, each smaller than the last.
local SHADE_DARKNESS = 0.4
local SHADE_REACH = 1.12
local SHADE_CORE = 0.55
local SHADE_STEPS = 32
-- Small text and the ring get a faint dark edge, so they read over a
-- bright sky too.
local EDGE_TRANSPARENCY = 0.75
-- The gear ring: about a quarter of the dial, clear of the speed below.
local GEAR_SIZE = 76
local GEAR_RING_TRANSPARENCY = 0.2
-- ABS and TC while they are not working.
local LAMP_OFF_TRANSPARENCY = 0.6
-- Only the needle's tip shows, from the ring inward.
local NEEDLE_LENGTH = 26
local NEEDLE_WIDTH = 3
-- How quickly the needle follows the rpm (1/s): smooth, still quick.
local NEEDLE_RESPONSE = 30
-- The speed's middle, below the dial's center (share of the radius).
local SPEED_DROP = 0.62
-- The shift cue goes out once the revs fall this share of the rev limit
-- below the red zone, so it does not flicker at its edge.
local SHIFT_CUE_HYSTERESIS = 0.02
-- The scale runs at least this share past the rev limiter, as a real
-- tachometer's does: at the limiter (or held there by the slipper clutch
-- after a downshift) the needle stands short of the end, free to swing.
local DIAL_HEADROOM = 0.05

-- Controls: tile size and gap; the lit tile pulses at this rate (Hz).
local TILE_SIZE = 64
local TILE_GAP = 8
local TILE_TRANSPARENCY = 0.42
local GLYPH_TRANSPARENCY = 0.05
local PULSE_RATE = 1.5

-- Touch controls, at UI scale 1 like the rest. Right thumb: the throttle
-- at the screen's edge, the brake inside it. Left thumb: the gear buttons
-- above the lean pad. Small buttons in a row at the top.
local THROTTLE_SIZE = Vector2.new(124, 176)
local BRAKE_SIZE = Vector2.new(112, 124)
local PEDAL_GAP = 14
local GEAR_BUTTON_SIZE = Vector2.new(104, 80)
local GEAR_BUTTON_GAP = 12
local SMALL_BUTTON_GAP = 8
-- The lean pad: the thumb's knob slides along the track, full lean at the
-- end of its travel, none in the dead zone (share of the travel) around
-- the middle. LEAN_GAP is between the pad at rest and the gear buttons.
local LEAN_TRACK = Vector2.new(236, 56)
local LEAN_KNOB = 60
local LEAN_GAP = 22
local LEAN_DEADZONE = 0.08
-- A touch on this share of the screen (width, height), at its bottom
-- left, leans; the pad comes to the thumb.
local LEAN_AREA = Vector2.new(0.42, 0.75)
local TOUCH_TRANSPARENCY = 0.45
-- The drawings on the pedals and the gear buttons are this much larger.
local PEDAL_GLYPH_SCALE = 1.6
local GEAR_GLYPH_SCALE = 1.3
-- With the touch controls up the meter moves to the top right, this much
-- smaller.
local TOUCH_METER_SCALE = 0.8

local COLORS = {
	dial = Color3.fromRGB(8, 10, 14),
	shade = Color3.fromRGB(0, 0, 0),
	white = Color3.fromRGB(240, 244, 255),
	-- Forza Horizon's crimson.
	red = Color3.fromRGB(236, 32, 84),
	amber = Color3.fromRGB(255, 176, 32),
	neutral = Color3.fromRGB(80, 220, 120),
	keycap = Color3.fromRGB(242, 244, 248),
	keyText = Color3.fromRGB(16, 18, 24),
	-- The control tile to press now: a racing shift light's blue, apart from
	-- the meter's red (shift cue), amber (R, ABS, TC) and green (N).
	cue = Color3.fromRGB(40, 196, 255),
	cueTile = Color3.fromRGB(4, 34, 50),
}

-- Faces that ship with Roblox, italics included: Roboto Condensed for the
-- meter (narrow and light, like Forza Horizon's figures), Montserrat for
-- the control tiles.
local ROBOTO_CONDENSED = "rbxasset://fonts/families/RobotoCondensed.json"
local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
local FONTS = {
	speed = Font.new(ROBOTO_CONDENSED, Enum.FontWeight.Light, Enum.FontStyle.Italic),
	gear = Font.new(ROBOTO_CONDENSED, Enum.FontWeight.Bold, Enum.FontStyle.Italic),
	scale = Font.new(ROBOTO_CONDENSED, Enum.FontWeight.Regular),
	lamp = Font.new(ROBOTO_CONDENSED, Enum.FontWeight.Bold),
	unit = Font.new(ROBOTO_CONDENSED, Enum.FontWeight.Regular, Enum.FontStyle.Italic),
	label = Font.new(MONTSERRAT, Enum.FontWeight.Medium),
	key = Font.new(MONTSERRAT, Enum.FontWeight.Bold),
}

-- The control tiles, left to right: the drawing on the tile and the key
-- for the keyboard and for the gamepad.
local CONTROLS = {
	{ name = "Ride", glyph = "bike", keyboard = "WASD", gamepad = "R2 L2" },
	{ name = "GearUp", glyph = "up", keyboard = "L SHIFT", gamepad = "R1" },
	{ name = "GearDown", glyph = "down", keyboard = "R SHIFT", gamepad = "L1" },
	{ name = "Neutral", glyph = "neutral", keyboard = "N", gamepad = "R1+L1" },
	{ name = "Engine", glyph = "power", keyboard = "F", gamepad = "SELECT" },
	{ name = "View", glyph = "camera", keyboard = "V", gamepad = "Y" },
	{ name = "LookBack", glyph = "mirror", keyboard = "C", gamepad = "R3" },
}

-- What the touch controls do, as local attributes on the bike: held values
-- (throttle and brake 0 or 1, steer -1..1 with + to the left, look back 0
-- or 1) and press counters (one more per press). BikeInputClient turns
-- them into rider input and BikeCameraClient into views; a map's own touch
-- controls can set them the same way. LeanArea is where the lean area is
-- (a Rect in screen pixels while the controls are up), so the camera
-- leaves the touches that start there alone.
local TOUCH_ATTRIBUTES = {
	Throttle = "BikeTouchThrottle",
	Brake = "BikeTouchBrake",
	Steer = "BikeTouchSteer",
	LookBack = "BikeTouchLookBack",
	ShiftUp = "BikeTouchShiftUp",
	ShiftDown = "BikeTouchShiftDown",
	Neutral = "BikeTouchNeutral",
	Engine = "BikeTouchEngine",
	Exit = "BikeTouchExit",
	View = "BikeTouchView",
	LeanArea = "BikeTouchLeanArea",
}

-- The touch buttons, in the order touches are matched: where each sits,
-- its drawing and label, and what it does (hold: a held value, press: a
-- press counter, from TOUCH_ATTRIBUTES).
local TOUCH_BUTTONS = {
	{ name = "Throttle", group = "Right", glyph = "throttle", text = "THROTTLE", hold = "Throttle" },
	{ name = "Brake", group = "Right", glyph = "brake", text = "BRAKE", hold = "Brake" },
	{ name = "GearUp", group = "Left", glyph = "up", text = "SHIFT UP", press = "ShiftUp" },
	{ name = "GearDown", group = "Left", glyph = "down", text = "SHIFT DOWN", press = "ShiftDown" },
	{ name = "Engine", group = "Top", glyph = "power", text = "ENGINE", press = "Engine" },
	{ name = "Neutral", group = "Top", glyph = "neutral", text = "NEUTRAL", press = "Neutral" },
	{ name = "View", group = "Top", glyph = "camera", text = "VIEW", press = "View" },
	{ name = "LookBack", group = "Top", glyph = "mirror", text = "BACK", hold = "LookBack" },
	{ name = "Exit", group = "Top", glyph = "exit", text = "GET OFF", press = "Exit" },
}

local bike = script.Parent
local player = Players.LocalPlayer

local configModule = bike:WaitForChild("BikeConfig", WAIT_TIMEOUT)
local soundModule = bike:WaitForChild("BikeSound", WAIT_TIMEOUT)

if configModule == nil then
	warn("[BikeDashboardClient] bike scripts missing; the dashboard will not show")

	return
end

local config = require(configModule)
local soundLoaded, BikeSound = false, nil

if soundModule then
	soundLoaded, BikeSound = pcall(require, soundModule)
end

local dashboardConfig = config.Dashboard or {}
local showMeter = dashboardConfig.Enabled ~= false
local showControls = showMeter and dashboardConfig.Hints ~= false
-- Touch controls whenever the screen takes touches, HUD or not: without
-- them a phone cannot ride.
local showTouch = dashboardConfig.TouchControls ~= false and UserInputService.TouchEnabled
-- Roblox's camera turns with any touch no GUI took, while the bike's
-- camera leaves the lean area's touches alone; so with Roblox's camera (the
-- bike's off, or in VR) the lean area is a button and takes them itself.
local leanAreaIsButton = not (config.Camera ~= nil and config.Camera.Enabled == true and not UserInputService.VREnabled)

if not (showMeter or showTouch) then
	return
end

local drivetrain = config.Drivetrain
local limitRPM = drivetrain.RevLimitRPM
local gearCount = #drivetrain.GearRatios
-- The dial: a tick every 1000 rpm and a number at every other one (0, 2,
-- 4, ...), up to the first tick DIAL_HEADROOM past the rev limiter (15000
-- for 14000).
local tickStep = 1000
local labelStep = 2 * tickStep
local dialMax = math.ceil(limitRPM * (1 + DIAL_HEADROOM) / tickStep) * tickStep
-- The red band starts here, and the gear turns red here: the cue to shift.
local redZoneRPM = dashboardConfig.RedZoneRPM or drivetrain.RedlineRPM or limitRPM
local shiftCueOffRPM = redZoneRPM - SHIFT_CUE_HYSTERESIS * limitRPM
local speedUnit = dashboardConfig.SpeedUnit or "km/h"
local unitScale = UNIT_SCALE[speedUnit]
-- Speed readout per stud/s.
local speedScale = unitScale and (dashboardConfig.StudLength or 0.28) * unitScale or 1

if unitScale == nil then
	speedUnit = "studs/s"
end

-- A bike attribute, or default while it is not set.
local function attribute(name, default)
	local value = bike:GetAttribute(name)

	if value == nil then
		return default
	end

	return value
end

-- N, R or the gear number.
local function gearText(gear)
	if gear == 0 then
		return "N"
	end

	return gear < 0 and "R" or tostring(gear)
end

-- The last input came from a gamepad.
local function usingGamepad()
	return string.find(UserInputService:GetLastInputType().Name, "Gamepad", 1, true) ~= nil
end

-- The local player sits on this bike.
local function ridingHere()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart

	return seatPart ~= nil and seatPart:IsDescendantOf(bike)
end

-- The engine switch the server keeps (BikeState.EngineOn).
local function engineRunning()
	local stateFolder = bike:FindFirstChild("BikeState")
	local engineOn = stateFolder and stateFolder:FindFirstChild("EngineOn")

	return engineOn ~= nil and engineOn.Value == true
end

-- rpm and gear from the engine state the rider's controller publishes
-- every frame (or BikeRPM and BikeGear, published less often, when that
-- is stale).
local function engineState()
	local published = soundLoaded and BikeSound.read(bike, ENGINE_STALE_TIME)

	if published then
		return published.rpm, published.gear or attribute("BikeGear", 0)
	end

	return attribute("BikeRPM", 0), attribute("BikeGear", 0)
end

-- HUD scale from the screen height (1 at REFERENCE_HEIGHT).
local function uiScale()
	local camera = Workspace.CurrentCamera

	if camera == nil then
		return 1
	end

	return math.clamp(camera.ViewportSize.Y / REFERENCE_HEIGHT, MIN_UI_SCALE, MAX_UI_SCALE)
end

-- Instance.new with properties and children.
local function create(className, properties, children)
	local instance = Instance.new(className)

	for name, value in properties do
		instance[name] = value
	end

	for _, child in children or {} do
		child.Parent = instance
	end

	return instance
end

-- Rounded corners, radius in pixels.
local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

-- Fully rounded ends (a pill or a circle).
local function round()
	return create("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

-- Inner padding in pixels.
local function padding(horizontal, vertical)
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, horizontal),
		PaddingRight = UDim.new(0, horizontal),
		PaddingTop = UDim.new(0, vertical),
		PaddingBottom = UDim.new(0, vertical),
	})
end

-- A text label with the HUD's defaults.
local function label(properties)
	local instance = create("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		FontFace = FONTS.label,
		TextColor3 = COLORS.white,
		TextSize = 14,
	})

	for name, value in properties do
		instance[name] = value
	end

	return instance
end

-- Drawing ------------------------------------------------------------------------

-- Unit vector on screen (y down) at an angle in degrees clockwise from
-- straight up: GUI rotation turns the same way.
local function direction(degrees)
	local radians = math.rad(degrees)

	return Vector2.new(math.sin(radians), -math.cos(radians))
end

-- A bar `length` long along the radius at `angle`, centered `radius` from
-- `center`: a tick, a piece of an arc or a spoke.
local function radialBar(parent, name, center, radius, angle, length, width, color, transparency)
	local at = center + direction(angle) * radius

	return create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(at.X, at.Y),
		Size = UDim2.fromOffset(width, length),
		Rotation = angle,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Parent = parent,
	})
end

-- An arc `thickness` wide on `radius` from one angle to another, in pieces
-- of `step` degrees that overlap a little so it reads as one stroke (opaque,
-- so the overlaps do not show).
local function arc(parent, name, center, radius, from, to, thickness, color, transparency, step)
	local pieces = math.max(1, math.ceil((to - from) / step))
	local spread = (to - from) / pieces
	local length = 2 * math.pi * radius * spread / 360 + 0.6

	for index = 0, pieces do
		radialBar(parent, name .. index, center, radius, from + index * spread, thickness, length, color, transparency)
	end
end

-- A rounded bar `length` long, centered on `at`, turned clockwise by
-- `rotation` degrees from horizontal.
local function bar(parent, name, at, length, thickness, rotation, color)
	return create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(at.X, at.Y),
		Size = UDim2.fromOffset(length, thickness),
		Rotation = rotation,
		BackgroundColor3 = color or COLORS.white,
		BackgroundTransparency = GLYPH_TRANSPARENCY,
		BorderSizePixel = 0,
		Parent = parent,
	}, { round() })
end

-- An outline (rounded rectangle or ring) centered on `at`.
local function outline(parent, name, at, size, radius, thickness)
	return create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(at.X, at.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = parent,
	}, {
		create("UICorner", { CornerRadius = radius }),
		create("UIStroke", { Color = COLORS.white, Transparency = GLYPH_TRANSPARENCY, Thickness = thickness }),
	})
end

-- A filled disc centered on `at`.
local function disc(parent, name, at, diameter, color)
	return create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(at.X, at.Y),
		Size = UDim2.fromOffset(diameter, diameter),
		BackgroundColor3 = color or COLORS.white,
		BackgroundTransparency = GLYPH_TRANSPARENCY,
		BorderSizePixel = 0,
		Parent = parent,
	}, { round() })
end

-- Two chevrons stacked, pointing up or down.
local function chevrons(tile, center, up)
	local sign = up and 1 or -1

	for index, offset in { -5, 5 } do
		-- Apex of this chevron; its arms run back from it at 45 degrees.
		local apex = center + Vector2.new(0, offset * sign - 4 * sign)
		local back = Vector2.new(4.6, 4.6 * sign)

		bar(tile, "Chevron" .. index .. "L", apex + Vector2.new(-back.X, back.Y), 13, 3.5, -45 * sign)
		bar(tile, "Chevron" .. index .. "R", apex + back, 13, 3.5, 45 * sign)
	end
end

-- The drawing on each control tile, centered on `center`.
local GLYPHS = {}

-- A rider on a motorcycle.
function GLYPHS.bike(tile, center)
	outline(tile, "RearWheel", center + Vector2.new(-11, 6), Vector2.new(11, 11), UDim.new(0.5, 0), 2.5)
	outline(tile, "FrontWheel", center + Vector2.new(12, 6), Vector2.new(11, 11), UDim.new(0.5, 0), 2.5)
	bar(tile, "Body", center + Vector2.new(0, -1), 20, 5, -10)
	bar(tile, "Fork", center + Vector2.new(10, 1), 11, 3, 65)
	bar(tile, "Rider", center + Vector2.new(-3, -7), 12, 4.5, -50)
	disc(tile, "Head", center + Vector2.new(3, -14), 6.5)
end

-- Gear up: chevrons pointing up.
function GLYPHS.up(tile, center)
	chevrons(tile, center, true)
end

-- Gear down: chevrons pointing down.
function GLYPHS.down(tile, center)
	chevrons(tile, center, false)
end

-- The neutral light of a motorcycle's dash.
function GLYPHS.neutral(tile, center)
	local lamp = disc(tile, "Lamp", center, 26, COLORS.neutral)

	label({
		Name = "Letter",
		Size = UDim2.fromScale(1, 1),
		FontFace = FONTS.key,
		TextSize = 16,
		TextColor3 = COLORS.keyText,
		Text = "N",
		Parent = lamp,
	})
end

-- The power symbol.
function GLYPHS.power(tile, center)
	arc(tile, "Ring", center + Vector2.new(0, 1), 10, 40, 320, 3, COLORS.white, GLYPH_TRANSPARENCY, 12)
	bar(tile, "Stem", center + Vector2.new(0, -6), 12, 3, 90)
end

-- View: a camera.
function GLYPHS.camera(tile, center)
	outline(tile, "Body", center + Vector2.new(0, 2), Vector2.new(28, 19), UDim.new(0, 4), 2.5)
	outline(tile, "Lens", center + Vector2.new(0, 2), Vector2.new(9, 9), UDim.new(0.5, 0), 2.5)
	bar(tile, "Finder", center + Vector2.new(-6, -9), 9, 4, 0)
end

-- A rear-view mirror with an arrow pointing back.
function GLYPHS.mirror(tile, center)
	outline(tile, "Glass", center + Vector2.new(0, -3), Vector2.new(30, 15), UDim.new(0.5, 0), 2.5)
	bar(tile, "Stem", center + Vector2.new(0, 9), 8, 3, 90)
	bar(tile, "ArrowL", center + Vector2.new(-3, -5.5), 8, 2.5, -40)
	bar(tile, "ArrowR", center + Vector2.new(-3, -0.5), 8, 2.5, 40)
	bar(tile, "ArrowShaft", center + Vector2.new(2, -3), 11, 2.5, 0)
end

-- A pedal: the plate with grip ribs across it, and its arm below.
local function pedal(tile, center, size, ribs)
	local plate = center + Vector2.new(0, -4)

	outline(tile, "Plate", plate, size, UDim.new(0, 5), 2.5)

	for index = 1, ribs do
		bar(
			tile,
			"Rib" .. index,
			plate + Vector2.new(0, (index - (ribs + 1) / 2) * (size.Y - 6) / ribs),
			size.X - 6,
			2,
			0
		)
	end

	bar(tile, "Arm", plate + Vector2.new(0, size.Y / 2 + 6), 8, 3, 90)
end

-- The throttle tall and narrow, the brake wide and short, as pedals are.
function GLYPHS.throttle(tile, center)
	pedal(tile, center, Vector2.new(18, 28), 4)
end

function GLYPHS.brake(tile, center)
	pedal(tile, center, Vector2.new(28, 18), 3)
end

-- Getting off: a doorway with an arrow out of it.
function GLYPHS.exit(tile, center)
	outline(tile, "Door", center + Vector2.new(-6, 0), Vector2.new(14, 24), UDim.new(0, 3), 2.5)
	bar(tile, "ArrowShaft", center + Vector2.new(4, 0), 16, 3, 0)
	bar(tile, "ArrowUp", center + Vector2.new(9, -3), 8, 3, 45)
	bar(tile, "ArrowDown", center + Vector2.new(9, 3), 8, 3, -45)
end

-- Meter ---------------------------------------------------------------------------

-- Dial angle (deg, clockwise from straight up) for an engine speed.
local function dialAngle(rpm)
	return DIAL_SWEEP * (math.clamp(rpm / dialMax, 0, 1) - 0.5)
end

-- { left, top, right, bottom } of the window (meter pixels) that holds the
-- part of a ring right of its center between dial angles `from` and `to`
-- (0 <= from < to <= 135) and nothing else of it. Each end is cut along
-- the line nearest to square across the ring: vertical near the top,
-- horizontal elsewhere.
local function rightArcWindow(center, radius, reach, from, to)
	local left, top = center.X, center.Y - reach
	local right, bottom = center.X + reach, center.Y + reach

	if from >= 45 then
		top = center.Y - radius * math.cos(math.rad(from))
	elseif from > 0 then
		left = center.X + radius * math.sin(math.rad(from))
	end

	if to >= 45 then
		bottom = center.Y - radius * math.cos(math.rad(to))
	else
		right = center.X + radius * math.sin(math.rad(to))
		bottom = center.Y
	end

	return { left, top, right, bottom }
end

--[=[
	An arc of a ring from dial angle `from` to `to` (within the sweep), its
	line's middle on `radius`: a whole ring (a UIStroke on a round frame,
	smooth at any size) seen through windows that clip off the rest.
]=]
local function ringArc(parent, name, center, radius, thickness, color, transparency, from, to)
	local reach = radius + thickness
	local windows = {}

	if from == -to and to >= 45 then
		-- Even about the top: one cut across the bottom.
		windows[1] =
			{ center.X - reach, center.Y - reach, center.X + reach, center.Y - radius * math.cos(math.rad(to)) }
	else
		if to > 0 then
			table.insert(windows, rightArcWindow(center, radius, reach, math.max(from, 0), to))
		end

		if from < 0 then
			-- The left part, as the mirror image of a right one.
			local mirror = rightArcWindow(center, radius, reach, math.max(-to, 0), -from)

			table.insert(windows, { 2 * center.X - mirror[3], mirror[2], 2 * center.X - mirror[1], mirror[4] })
		end

		if #windows == 2 then
			-- Overlap the halves by a pixel so no seam shows at the top.
			windows[1][1] -= 0.5
			windows[2][3] += 0.5
		end
	end

	-- Offsets are whole pixels: round the window, and give the ring an
	-- even size so it centers on the dial's (whole) center pixel. A
	-- UIStroke lies outside its frame's edge, so the frame is one line
	-- width smaller than the line's middle.
	local size = 2 * math.round(radius - thickness / 2)

	for index, window in windows do
		local left, top = math.round(window[1]), math.round(window[2])
		local right, bottom = math.round(window[3]), math.round(window[4])
		local frame = create("Frame", {
			Name = #windows == 1 and name or name .. index,
			Position = UDim2.fromOffset(left, top),
			Size = UDim2.fromOffset(right - left, bottom - top),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Parent = parent,
		})

		create("Frame", {
			Name = "Ring",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(center.X - left, center.Y - top),
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = frame,
		}, {
			round(),
			create("UIStroke", { Color = color, Transparency = transparency, Thickness = thickness }),
		})
	end
end

--[=[
	The meter: { root, scale, needle, rpm, angle, gearDisc, gearRing, gear,
	abs, tc, speed, speedShadow, speedShown, gearShown, cueShown }.
]=]
local function buildMeter(gui)
	local radius = DIAL_SIZE / 2
	local center = Vector2.new(radius, radius)
	local ringRadius = radius - RING_INSET
	local root = create("Frame", {
		Name = "Meter",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -SCREEN_MARGIN, 1, -SCREEN_MARGIN),
		Size = UDim2.fromOffset(DIAL_SIZE, DIAL_SIZE),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	local scale = create("UIScale", { Scale = 1, Parent = root })

	-- The soft shadow: inside the k-th disc the scene is darkened by
	-- SHADE_DARKNESS times a smoothstep of k / SHADE_STEPS, so the shadow
	-- fades in from nothing at its edge, without rings.
	local shaded = 0

	for step = 1, SHADE_STEPS do
		local share = step / SHADE_STEPS
		local darkness = SHADE_DARKNESS * share * share * (3 - 2 * share)
		local diameter = DIAL_SIZE * SHADE_REACH * (1 - (1 - SHADE_CORE) * (step - 1) / SHADE_STEPS)

		create("Frame", {
			Name = "Shade" .. step,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(center.X, center.Y),
			Size = UDim2.fromOffset(diameter, diameter),
			BackgroundColor3 = COLORS.shade,
			-- What this disc lets through, on top of the discs around it.
			BackgroundTransparency = (1 - darkness) / (1 - shaded),
			BorderSizePixel = 0,
			Parent = root,
		}, { round() })

		shaded = darkness
	end

	-- Scale: the ring, the red zone's arc on it, then a tick every 1000 rpm
	-- and a number at every other one.
	local scaleLayer = create("Frame", {
		Name = "Scale",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = root,
	})
	local sweepEnd = DIAL_SWEEP / 2

	ringArc(
		scaleLayer,
		"RingEdge",
		center,
		ringRadius,
		RING_WIDTH + 2,
		COLORS.shade,
		EDGE_TRANSPARENCY,
		-sweepEnd,
		sweepEnd
	)
	ringArc(scaleLayer, "Ring", center, ringRadius, RING_WIDTH, COLORS.white, RING_TRANSPARENCY, -sweepEnd, sweepEnd)

	if redZoneRPM < dialMax then
		ringArc(scaleLayer, "RedArc", center, ringRadius, RED_ARC_WIDTH, COLORS.red, 0, dialAngle(redZoneRPM), sweepEnd)
	end

	for rpm = 0, dialMax, tickStep do
		local angle = dialAngle(rpm)
		local red = rpm >= redZoneRPM
		local numbered = rpm % labelStep == 0
		local length = numbered and TICK_LENGTH or MINOR_TICK_LENGTH
		local tickAt = center + direction(angle) * (ringRadius - RING_WIDTH - length / 2)

		create("Frame", {
			Name = "Tick" .. rpm,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(math.round(tickAt.X), math.round(tickAt.Y)),
			Size = UDim2.fromOffset(TICK_WIDTH, length),
			Rotation = angle,
			BackgroundColor3 = red and COLORS.red or COLORS.white,
			BackgroundTransparency = red and 0 or TICK_TRANSPARENCY,
			BorderSizePixel = 0,
			Parent = scaleLayer,
		}, { round() })

		if numbered then
			local labelAt = center + direction(angle) * (ringRadius - LABEL_INSET)

			label({
				Name = "Label" .. rpm,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(math.round(labelAt.X), math.round(labelAt.Y)),
				Size = UDim2.fromOffset(24, 16),
				FontFace = FONTS.scale,
				TextSize = 14,
				TextColor3 = red and COLORS.red or COLORS.white,
				TextTransparency = red and 0 or LABEL_TRANSPARENCY,
				TextStrokeColor3 = COLORS.shade,
				TextStrokeTransparency = EDGE_TRANSPARENCY,
				Text = tostring(math.round(rpm / 1000)),
				Parent = scaleLayer,
			})
		end
	end

	-- ABS and traction control lights left of the gear, the unit right of it.
	local sideOffset = GEAR_SIZE / 2 + 38
	local lights = {}

	for index, name in { "ABS", "TC" } do
		lights[name] = label({
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(center.X - sideOffset, center.Y + (index - 1.5) * 16),
			Size = UDim2.fromOffset(36, 15),
			FontFace = FONTS.lamp,
			TextSize = 13,
			TextTransparency = LAMP_OFF_TRANSPARENCY,
			TextStrokeColor3 = COLORS.shade,
			TextStrokeTransparency = EDGE_TRANSPARENCY,
			Text = name,
			Parent = root,
		})
	end

	label({
		Name = "Unit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X + sideOffset, center.Y),
		Size = UDim2.fromOffset(50, 15),
		FontFace = FONTS.unit,
		TextSize = 13,
		TextTransparency = 0.25,
		TextStrokeColor3 = COLORS.shade,
		TextStrokeTransparency = EDGE_TRANSPARENCY,
		Text = string.upper(speedUnit),
		Parent = root,
	})

	-- The needle's tip turns with a full-dial frame about the center.
	local needle = create("Frame", {
		Name = "Needle",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Rotation = dialAngle(0),
		Parent = root,
	})

	for _, layer in { { "Glow", 3 * NEEDLE_WIDTH, 0.8 }, { "Tip", NEEDLE_WIDTH, 0 } } do
		create("Frame", {
			Name = layer[1],
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromOffset(center.X, center.Y - ringRadius - 1),
			Size = UDim2.fromOffset(layer[2], NEEDLE_LENGTH),
			BackgroundColor3 = COLORS.white,
			BackgroundTransparency = layer[3],
			BorderSizePixel = 0,
			Parent = needle,
		}, { round() })
	end

	-- The gear in a ring in the middle.
	local gearDisc = create("Frame", {
		Name = "GearDisc",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(GEAR_SIZE, GEAR_SIZE),
		BackgroundColor3 = COLORS.shade,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Parent = root,
	}, { round() })
	local gearRing = create("UIStroke", {
		Color = COLORS.white,
		Transparency = GEAR_RING_TRANSPARENCY,
		Thickness = 2,
		Parent = gearDisc,
	})
	local gear = label({
		Name = "Gear",
		Size = UDim2.fromScale(1, 1),
		FontFace = FONTS.gear,
		TextSize = 48,
		TextColor3 = COLORS.neutral,
		Text = "N",
		Parent = gearDisc,
	})

	-- The speed in the gap at the bottom, over a drop shadow. The box sits
	-- a little left, as the italic digits lean right.
	local speedAt = center + Vector2.new(-3, radius * SPEED_DROP)
	local speedLabels = {}

	for _, layer in { { "SpeedShadow", 2, 3, COLORS.shade, 0.55 }, { "Speed", 0, 0, COLORS.white, 0 } } do
		speedLabels[layer[1]] = label({
			Name = layer[1],
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(speedAt.X + layer[2], speedAt.Y + layer[3]),
			Size = UDim2.fromOffset(220, 96),
			FontFace = FONTS.speed,
			TextSize = 100,
			TextColor3 = layer[4],
			TextTransparency = layer[5],
			Text = "0",
			Parent = root,
		})
	end

	root.Parent = gui

	return {
		root = root,
		scale = scale,
		needle = needle,
		rpm = 0,
		angle = dialAngle(0),
		gearDisc = gearDisc,
		gearRing = gearRing,
		gear = gear,
		abs = lights.ABS,
		tc = lights.TC,
		speed = speedLabels.Speed,
		speedShadow = speedLabels.SpeedShadow,
		speedShown = nil,
		gearShown = nil,
		cueShown = nil,
		touch = false,
	}
end

-- An ABS or TC lamp: amber while working, dim otherwise.
local function setLight(light, on)
	light.TextColor3 = on and COLORS.amber or COLORS.white
	light.TextTransparency = on and 0 or LAMP_OFF_TRANSPARENCY
end

-- One frame of the meter: needle, gear ring and shift cue, lamps, speed.
local function updateMeter(meter, deltaTime, status)
	-- Out of the right thumb's way while the touch controls are up.
	if status.touch ~= meter.touch then
		meter.touch = status.touch
		meter.root.AnchorPoint = status.touch and Vector2.new(1, 0) or Vector2.new(1, 1)
		meter.root.Position = status.touch and UDim2.new(1, -SCREEN_MARGIN, 0, SCREEN_MARGIN)
			or UDim2.new(1, -SCREEN_MARGIN, 1, -SCREEN_MARGIN)
	end

	meter.scale.Scale = status.scale * (status.touch and TOUCH_METER_SCALE or 1)
	meter.rpm += (status.rpm - meter.rpm) * (1 - math.exp(-NEEDLE_RESPONSE * deltaTime))

	local angle = dialAngle(meter.rpm)

	if math.abs(angle - meter.angle) > 0.05 then
		meter.angle = angle
		meter.needle.Rotation = angle
	end

	local shownSpeed = math.round(math.abs(attribute("BikeSpeed", 0)) * speedScale)

	if shownSpeed ~= meter.speedShown then
		meter.speedShown = shownSpeed
		meter.speed.Text = tostring(shownSpeed)
		meter.speedShadow.Text = meter.speed.Text
	end

	local gear = status.gear

	if gear ~= meter.gearShown or status.shiftCue ~= meter.cueShown then
		meter.gearShown = gear
		meter.cueShown = status.shiftCue
		meter.gear.Text = gearText(gear)
		meter.gear.TextColor3 = status.shiftCue and COLORS.red
			or gear == 0 and COLORS.neutral
			or gear < 0 and COLORS.amber
			or COLORS.white
		meter.gearRing.Color = status.shiftCue and COLORS.red or COLORS.white
		meter.gearRing.Transparency = status.shiftCue and 0 or GEAR_RING_TRANSPARENCY
	end

	setLight(meter.abs, attribute("BikeFrontABS", false) or attribute("BikeRearABS", false))
	setLight(meter.tc, status.running and attribute("BikeTractionScale", 1) < TRACTION_LAMP_SCALE)
end

-- Controls ------------------------------------------------------------------------

local function isWhite(color)
	local white = COLORS.white

	return math.abs(color.R - white.R) + math.abs(color.G - white.G) + math.abs(color.B - white.B) < 1e-3
end

-- The white parts of a tile's drawing (filled frames and outlines) as
-- { instance, property }: they take the cue color while the tile is lit.
local function glyphParts(tile)
	local parts = {}

	for _, child in tile:GetChildren() do
		if child:IsA("Frame") then
			local stroke = child:FindFirstChildOfClass("UIStroke")

			if child.BackgroundTransparency < 1 and isWhite(child.BackgroundColor3) then
				table.insert(parts, { child, "BackgroundColor3" })
			end

			if stroke and isWhite(stroke.Color) then
				table.insert(parts, { stroke, "Color" })
			end
		end
	end

	return parts
end

--[=[
	The control tiles: { root, scale, tiles = { [name] = { frame, stroke,
	key, glyph, control, lit } }, gamepad }.
]=]
local function buildControls(gui)
	local root = create("Frame", {
		Name = "Controls",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, SCREEN_MARGIN, 1, -SCREEN_MARGIN),
		Size = UDim2.fromOffset(#CONTROLS * TILE_SIZE + (#CONTROLS - 1) * TILE_GAP, TILE_SIZE),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	})
	local scale = create("UIScale", { Scale = 1, Parent = root })
	local tiles = {}

	for index, control in CONTROLS do
		local tile = create("Frame", {
			Name = control.name,
			Position = UDim2.fromOffset((index - 1) * (TILE_SIZE + TILE_GAP), 0),
			Size = UDim2.fromOffset(TILE_SIZE, TILE_SIZE),
			BackgroundColor3 = COLORS.dial,
			BackgroundTransparency = TILE_TRANSPARENCY,
			BorderSizePixel = 0,
			Parent = root,
		}, { corner(10) })
		local stroke = create("UIStroke", { Color = COLORS.white, Transparency = 0.8, Thickness = 1.5, Parent = tile })

		GLYPHS[control.glyph](tile, Vector2.new(TILE_SIZE / 2, 24))

		local glyph = glyphParts(tile)
		local key = label({
			Name = "Key",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -5),
			Size = UDim2.fromOffset(0, 16),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = COLORS.keycap,
			BackgroundTransparency = 0.06,
			FontFace = FONTS.key,
			TextSize = 11,
			TextColor3 = COLORS.keyText,
			Text = control.keyboard,
			Parent = tile,
		})

		corner(4).Parent = key
		padding(5, 0).Parent = key
		tiles[control.name] =
			{ frame = tile, stroke = stroke, key = key, glyph = glyph, control = control, lit = false }
	end

	root.Parent = gui

	return { root = root, scale = scale, tiles = tiles, gamepad = false }
end

-- What the bike needs now, by control name: the engine started, a gear out
-- of neutral, a shift up in the red zone. That tile or button turns blue,
-- its rim pulsing (pulse 0..1).
local function needsNow(status)
	local inNeutral = status.running and status.gear == 0

	return {
		Engine = not status.running,
		GearUp = inNeutral or status.shiftCue,
		GearDown = inNeutral,
	}
end

-- 0..1, the slow pulse of the lit tiles' rims.
local function pulseNow()
	return 0.5 + 0.5 * math.cos(os.clock() * 2 * math.pi * PULSE_RATE)
end

-- One frame of the control tiles: keys for the input in use, lit tiles.
local function updateControls(controls, status)
	-- The touch controls take their place on a touch screen.
	controls.root.Visible = not status.touch
	controls.scale.Scale = status.scale

	local gamepad = usingGamepad()

	if gamepad ~= controls.gamepad then
		controls.gamepad = gamepad

		for _, tile in controls.tiles do
			tile.key.Text = gamepad and tile.control.gamepad or tile.control.keyboard
		end
	end

	local needs = needsNow(status)
	local pulse = pulseNow()

	for name, tile in controls.tiles do
		local lit = needs[name] == true

		if lit then
			tile.stroke.Transparency = 0.45 * (1 - pulse)
		end

		if lit ~= tile.lit then
			tile.lit = lit
			tile.stroke.Color = lit and COLORS.cue or COLORS.white
			tile.stroke.Thickness = lit and 2.5 or 1.5
			tile.frame.BackgroundColor3 = lit and COLORS.cueTile or COLORS.dial
			tile.frame.BackgroundTransparency = lit and TILE_TRANSPARENCY - 0.14 or TILE_TRANSPARENCY

			for _, part in tile.glyph do
				part[1][part[2]] = lit and COLORS.cue or COLORS.white
			end

			if not lit then
				tile.stroke.Transparency = 0.8
			end
		end
	end
end

-- Touch controls -----------------------------------------------------------------

local function touchPoint(input)
	return Vector2.new(input.Position.X, input.Position.Y)
end

-- The point (screen pixels, as touches report it) is on the object.
local function inside(object, point)
	local topLeft, size = object.AbsolutePosition, object.AbsoluteSize

	return point.X >= topLeft.X
		and point.Y >= topLeft.Y
		and point.X <= topLeft.X + size.X
		and point.Y <= topLeft.Y + size.Y
end

-- The touch controls are up: a touch screen that is the input in use (a
-- phone or tablet from the start, a touch laptop after a touch).
local function touchMode()
	if not UserInputService.TouchEnabled then
		return false
	end

	local last = UserInputService:GetLastInputType()

	if last == Enum.UserInputType.Touch then
		return true
	end

	if usingGamepad() or last == Enum.UserInputType.Keyboard or string.find(last.Name, "Mouse", 1, true) then
		return false
	end

	return not UserInputService.KeyboardEnabled
end

--[=[
	The touch layer: { root, scales (UIScale), left (the gear buttons),
	lean = { area, pad, track, stroke, thumb, knob, input, start, published
	(the area's Rect last given to the camera) },
	buttons = { [name] = button }, order (TOUCH_BUTTONS order), claimed =
	{ [touch] = button or lean }, values (held values given to the bike),
	shownScale }. A button: { spec, frame, stroke, glyph (parts), touches =
	{ [touch] = true }, lit, pressed }.
]=]
local function buildTouch(gui)
	local root = create("Frame", {
		Name = "Touch",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = false,
	})
	local touch = {
		root = root,
		scales = {},
		buttons = {},
		order = {},
		claimed = {},
		values = {},
		shownScale = nil,
	}

	-- A group of controls, scaled with the HUD about its anchor point.
	local function group(name, anchor, position, size)
		local frame = create("Frame", {
			Name = name,
			AnchorPoint = anchor,
			Position = position,
			Size = UDim2.fromOffset(size.X, size.Y),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = root,
		})

		table.insert(touch.scales, create("UIScale", { Scale = 1, Parent = frame }))

		return frame
	end

	-- The lean area first, so the buttons drawn over it keep their touches.
	-- A plain frame takes no touches from the map's buttons under it.
	local area = create(leanAreaIsButton and "TextButton" or "Frame", {
		Name = "LeanArea",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(LEAN_AREA.X, LEAN_AREA.Y),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Selectable = false,
		Parent = root,
	})

	if leanAreaIsButton then
		area.AutoButtonColor = false
		area.Text = ""
	end
	local pad = group("LeanPad", Vector2.new(0.5, 0.5), UDim2.new(), LEAN_TRACK)
	local track = create("Frame", {
		Name = "Track",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.dial,
		BackgroundTransparency = TOUCH_TRANSPARENCY,
		BorderSizePixel = 0,
		Parent = pad,
	}, { round() })
	local trackStroke =
		create("UIStroke", { Color = COLORS.white, Transparency = 0.75, Thickness = 1.5, Parent = track })

	-- An arrow at each end, pointing out: lean that way.
	for index, side in { -1, 1 } do
		local tip = Vector2.new(LEAN_TRACK.X / 2 + side * (LEAN_TRACK.X / 2 - 16), LEAN_TRACK.Y / 2)

		for arm, sign in { -1, 1 } do
			local stroke =
				bar(pad, "Arrow" .. index .. arm, tip + Vector2.new(-side * 3, sign * 3.5), 10, 2.5, -side * sign * 50)

			stroke.BackgroundTransparency = 0.5
		end
	end

	-- The thumb: a knob in a faint halo, sliding along the track.
	local thumb = create("Frame", {
		Name = "Thumb",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(LEAN_KNOB, LEAN_KNOB),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		Parent = pad,
	}, { round() })
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(LEAN_KNOB * 0.6, LEAN_KNOB * 0.6),
		BackgroundColor3 = COLORS.white,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Parent = thumb,
	}, { round() })

	touch.lean = {
		area = area,
		pad = pad,
		track = track,
		stroke = trackStroke,
		thumb = thumb,
		knob = knob,
		input = nil,
		start = nil,
		published = nil,
	}

	local groups = {
		Left = group(
			"Left",
			Vector2.new(0, 1),
			UDim2.new(),
			Vector2.new(GEAR_BUTTON_SIZE.X, 2 * GEAR_BUTTON_SIZE.Y + GEAR_BUTTON_GAP)
		),
		Right = group(
			"Right",
			Vector2.new(1, 1),
			UDim2.new(1, -SCREEN_MARGIN, 1, -SCREEN_MARGIN),
			Vector2.new(BRAKE_SIZE.X + PEDAL_GAP + THROTTLE_SIZE.X, THROTTLE_SIZE.Y)
		),
		Top = group("Top", Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, SCREEN_MARGIN), Vector2.zero),
	}
	-- Where a button sits in its group, its size and corner radius, and how
	-- much larger its drawing is. The small buttons go in a row on top.
	local places = {
		Throttle = { Vector2.new(BRAKE_SIZE.X + PEDAL_GAP, 0), THROTTLE_SIZE, 16, PEDAL_GLYPH_SCALE },
		Brake = { Vector2.new(0, THROTTLE_SIZE.Y - BRAKE_SIZE.Y), BRAKE_SIZE, 16, PEDAL_GLYPH_SCALE },
		GearUp = { Vector2.zero, GEAR_BUTTON_SIZE, 12, GEAR_GLYPH_SCALE },
		GearDown = { Vector2.new(0, GEAR_BUTTON_SIZE.Y + GEAR_BUTTON_GAP), GEAR_BUTTON_SIZE, 12, GEAR_GLYPH_SCALE },
	}
	local topCount = 0

	touch.left = groups.Left

	for _, spec in TOUCH_BUTTONS do
		local place = places[spec.name]

		if place == nil then
			place =
				{ Vector2.new(topCount * (TILE_SIZE + SMALL_BUTTON_GAP), 0), Vector2.new(TILE_SIZE, TILE_SIZE), 10, 1 }
			topCount += 1
		end

		local frame = create("TextButton", {
			Name = spec.name,
			Position = UDim2.fromOffset(place[1].X, place[1].Y),
			Size = UDim2.fromOffset(place[2].X, place[2].Y),
			BackgroundColor3 = COLORS.dial,
			BackgroundTransparency = TOUCH_TRANSPARENCY,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			Parent = groups[spec.group],
		}, { corner(place[3]) })
		local stroke =
			create("UIStroke", { Color = COLORS.white, Transparency = 0.75, Thickness = 1.5, Parent = frame })
		-- The drawing, in a box like a key tile's, enlarged.
		local drawing = create("Frame", {
			Name = "Drawing",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -8),
			Size = UDim2.fromOffset(TILE_SIZE, 48),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = frame,
		})

		create("UIScale", { Scale = place[4], Parent = drawing })
		GLYPHS[spec.glyph](drawing, Vector2.new(TILE_SIZE / 2, 24))
		label({
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -5),
			Size = UDim2.new(1, -4, 0, 14),
			FontFace = FONTS.lamp,
			TextSize = 12,
			TextTransparency = 0.2,
			Text = spec.text,
			Parent = frame,
		})

		local button = {
			spec = spec,
			frame = frame,
			stroke = stroke,
			glyph = glyphParts(drawing),
			touches = {},
			lit = false,
			pressed = false,
		}

		touch.buttons[spec.name] = button
		table.insert(touch.order, button)
	end

	groups.Top.Size = UDim2.fromOffset(topCount * (TILE_SIZE + SMALL_BUTTON_GAP) - SMALL_BUTTON_GAP, TILE_SIZE)
	root.Parent = gui

	return touch
end

-- A touch button lit (blue: the bike needs it now), pressed (filled) or
-- plain.
local function setButtonState(button, lit, pressed)
	if lit == button.lit and pressed == button.pressed then
		return
	end

	button.lit = lit
	button.pressed = pressed
	button.frame.BackgroundColor3 = pressed and COLORS.white or lit and COLORS.cueTile or COLORS.dial
	button.frame.BackgroundTransparency = pressed and 0.75 or lit and TOUCH_TRANSPARENCY - 0.14 or TOUCH_TRANSPARENCY
	button.stroke.Color = lit and COLORS.cue or COLORS.white
	button.stroke.Thickness = lit and 2.5 or 1.5
	button.stroke.Transparency = pressed and 0.05 or 0.75

	for _, part in button.glyph do
		part[1][part[2]] = lit and COLORS.cue or COLORS.white
	end
end

-- A held value given to the bike, written when it changes.
local function setTouchValue(touch, key, value)
	if touch.values[key] ~= value then
		touch.values[key] = value
		bike:SetAttribute(TOUCH_ATTRIBUTES[key], value)
	end
end

-- One more press on a press counter.
local function countPress(key)
	local name = TOUCH_ATTRIBUTES[key]
	local count = bike:GetAttribute(name)

	bike:SetAttribute(name, (type(count) == "number" and count or 0) + 1)
end

-- The lean pad: bright under a leaning thumb, dim at rest.
local function showLean(lean, active)
	lean.track.BackgroundTransparency = active and TOUCH_TRANSPARENCY - 0.15 or TOUCH_TRANSPARENCY
	lean.stroke.Transparency = active and 0.35 or 0.75
	lean.knob.BackgroundTransparency = active and 0.05 or 0.3
	lean.thumb.BackgroundTransparency = active and 0.75 or 0.85
end

-- The pad's place at rest: bottom left, under the gear buttons.
local function restLeanPad(touch)
	local scale = touch.shownScale or 1

	touch.lean.pad.Position = UDim2.new(
		0,
		math.round(SCREEN_MARGIN + LEAN_TRACK.X / 2 * scale),
		1,
		-math.round(SCREEN_MARGIN + LEAN_TRACK.Y / 2 * scale)
	)
end

-- Steer from how far the thumb has moved since it came down: + = left (as
-- BikeDynamics), full at the end of the knob's travel.
local function leanTo(touch, point)
	local lean = touch.lean
	local travel = (LEAN_TRACK.X - LEAN_KNOB) / 2
	local moved = math.clamp((point.X - lean.start.X) / (touch.shownScale or 1), -travel, travel)
	local share = math.abs(moved) / travel
	local steer = share > LEAN_DEADZONE and -math.sign(moved) * (share - LEAN_DEADZONE) / (1 - LEAN_DEADZONE) or 0

	lean.thumb.Position = UDim2.new(0.5, math.round(moved), 0.5, 0)
	setTouchValue(touch, "Steer", math.round(steer * 100) / 100)
end

-- The pad comes to the thumb.
local function startLean(touch, input, point)
	local lean = touch.lean
	local origin = touch.root.AbsolutePosition

	lean.input = input
	lean.start = point
	lean.pad.Position = UDim2.fromOffset(math.round(point.X - origin.X), math.round(point.Y - origin.Y))
	showLean(lean, true)
	leanTo(touch, point)
end

-- The leaning thumb lifted: pad back to rest, steer 0.
local function endLean(touch)
	local lean = touch.lean

	lean.input = nil
	lean.start = nil
	lean.thumb.Position = UDim2.fromScale(0.5, 0.5)
	showLean(lean, false)
	restLeanPad(touch)
	setTouchValue(touch, "Steer", 0)
end

-- A finger on a button: its held value goes to 1, or a press is counted
-- (the first finger only).
local function pressButton(touch, button, input)
	local first = next(button.touches) == nil
	local spec = button.spec

	button.touches[input] = true

	if not first then
		return
	end

	if spec.hold then
		setTouchValue(touch, spec.hold, 1)
	else
		countPress(spec.press)
	end

	setButtonState(button, button.lit, true)
end

-- A finger off a button: its held value back to 0 once no finger holds it.
local function releaseButton(touch, button, input)
	button.touches[input] = nil

	if next(button.touches) ~= nil then
		return
	end

	if button.spec.hold then
		setTouchValue(touch, button.spec.hold, 0)
	end

	setButtonState(button, button.lit, false)
end

-- A finger comes down: on a button, or in the lean area (one thumb leans).
-- processed: a GUI took the touch (as Roblox reports it); our buttons do,
-- and so do the chat window and the map's own buttons, which the lean area
-- leaves alone unless it is a button itself.
local function touchBegan(touch, input, processed)
	if not touch.root.Visible then
		return
	end

	local point = touchPoint(input)

	for _, button in touch.order do
		if inside(button.frame, point) then
			touch.claimed[input] = button
			pressButton(touch, button, input)

			return
		end
	end

	if touch.lean.input == nil and (leanAreaIsButton or not processed) and inside(touch.lean.area, point) then
		touch.claimed[input] = touch.lean
		startLean(touch, input, point)
	end
end

-- The leaning thumb moved: steer from how far.
local function touchMoved(touch, input)
	if input == touch.lean.input then
		leanTo(touch, touchPoint(input))
	end
end

-- A finger lifted: let go of what it held.
local function touchEnded(touch, input)
	local claim = touch.claimed[input]

	touch.claimed[input] = nil

	if claim == touch.lean then
		endLean(touch)
	elseif claim then
		releaseButton(touch, claim, input)
	end
end

-- Lets go of everything (the controls going away, the window losing focus).
local function releaseTouch(touch)
	table.clear(touch.claimed)

	for _, button in touch.order do
		table.clear(button.touches)

		if button.spec.hold then
			setTouchValue(touch, button.spec.hold, 0)
		end

		setButtonState(button, button.lit, false)
	end

	endLean(touch)
end

-- Tells the camera where the lean area is (TOUCH_ATTRIBUTES.LeanArea), or
-- that the touch controls are down (nil), when that changes.
local function publishLeanArea(touch, up)
	local lean = touch.lean
	local rect = nil

	if up then
		local topLeft, size = lean.area.AbsolutePosition, lean.area.AbsoluteSize

		rect = Rect.new(topLeft.X, topLeft.Y, topLeft.X + size.X, topLeft.Y + size.Y)
	end

	if rect ~= lean.published then
		lean.published = rect
		bike:SetAttribute(TOUCH_ATTRIBUTES.LeanArea, rect)
	end
end

-- One frame of the touch controls: shown or not, scale, lit buttons.
local function updateTouch(touch, status)
	if touch.root.Visible ~= status.touch then
		touch.root.Visible = status.touch

		if not status.touch then
			releaseTouch(touch)
		end
	end

	publishLeanArea(touch, status.touch)

	if not status.touch then
		return
	end

	if status.scale ~= touch.shownScale then
		touch.shownScale = status.scale

		for _, scaleObject in touch.scales do
			scaleObject.Scale = status.scale
		end

		-- The gear buttons sit above the lean pad's place, which scales too.
		touch.left.Position =
			UDim2.new(0, SCREEN_MARGIN, 1, -math.round(SCREEN_MARGIN + (LEAN_TRACK.Y + LEAN_GAP) * status.scale))

		if touch.lean.input == nil then
			restLeanPad(touch)
		end
	end

	local needs = needsNow(status)
	local pulse = pulseNow()

	for name, button in touch.buttons do
		setButtonState(button, needs[name] == true, button.pressed)

		if button.lit and not button.pressed then
			button.stroke.Transparency = 0.45 * (1 - pulse)
		end
	end
end

-- Roblox's own touch controls (thumbstick, jump button) stay hidden while
-- the touch controls are built; the setting found is put back afterwards.
local savedTouchControls = nil

-- Hides them, keeping the setting found.
local function hideRobloxTouchControls()
	if savedTouchControls ~= nil then
		return
	end

	local read, enabled = pcall(function()
		return GuiService.TouchControlsEnabled
	end)

	if read then
		savedTouchControls = enabled
		pcall(function()
			GuiService.TouchControlsEnabled = false
		end)
	end
end

-- Puts the kept setting back.
local function restoreRobloxTouchControls()
	if savedTouchControls == nil then
		return
	end

	local enabled = savedTouchControls

	savedTouchControls = nil
	pcall(function()
		GuiService.TouchControlsEnabled = enabled
	end)
end

-- Lifecycle ------------------------------------------------------------------

-- While the local player rides this bike: { gui, meter, controls, touch,
-- cueGear (the gear the shift cue came on in, nil while it is off) }.
local shown = nil

-- The rider got off: remove the HUD and let go of every touch.
local function hide()
	if shown then
		if shown.touch then
			-- Nothing stays held on the bike.
			pcall(releaseTouch, shown.touch)
			pcall(publishLeanArea, shown.touch, false)
			restoreRobloxTouchControls()
		end

		shown.gui:Destroy()
		shown = nil
	end
end

-- The rider got on: build the HUD in PlayerGui.
local function show()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")

	if playerGui == nil then
		return
	end

	local gui = create("ScreenGui", {
		Name = "BikeDashboard",
		ResetOnSpawn = false,
		DisplayOrder = 50,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	shown = {
		gui = gui,
		meter = showMeter and buildMeter(gui) or nil,
		controls = showControls and buildControls(gui) or nil,
		touch = showTouch and buildTouch(gui) or nil,
		cueGear = nil,
	}
	gui.Parent = playerGui

	if shown.touch then
		hideRobloxTouchControls()
	end
end

-- What the meter, the control tiles and the touch controls show this frame.
local function readStatus()
	local running = engineRunning()
	local rpm, gear = engineState()

	if not running then
		rpm = 0
	end

	-- Shift cue: in the red zone in any gear below the top one, until the
	-- gear changes or the revs fall back to shiftCueOffRPM.
	if shown.cueGear ~= nil and (gear ~= shown.cueGear or rpm < shiftCueOffRPM) then
		shown.cueGear = nil
	end

	if shown.cueGear == nil and gear > 0 and gear < gearCount and rpm >= redZoneRPM then
		shown.cueGear = gear
	end

	return {
		running = running,
		rpm = rpm,
		gear = gear,
		shiftCue = shown.cueGear ~= nil,
		scale = uiScale(),
		touch = shown.touch ~= nil and touchMode(),
	}
end

-- Every frame: show or hide the HUD, then update its parts.
local function step(deltaTime)
	if not ridingHere() then
		hide()

		return
	end

	if shown == nil then
		show()

		if shown == nil then
			return
		end
	end

	local status = readStatus()

	if shown.meter then
		updateMeter(shown.meter, deltaTime, status)
	end

	if shown.controls then
		updateControls(shown.controls, status)
	end

	if shown.touch then
		updateTouch(shown.touch, status)
	end
end

local stepConnection

stepConnection = RunService.PreRender:Connect(function(deltaTime)
	local stepped, problem = pcall(step, deltaTime)

	if not stepped then
		-- Stop instead of repeating the same error every frame.
		stepConnection:Disconnect()
		pcall(hide)
		warn("[BikeDashboardClient] " .. tostring(problem))
	end
end)

-- Touches go to the touch controls, which match them to the buttons by
-- screen position; the window losing focus lets go of everything.
local inputConnections = {}

for signalName, handler in { InputBegan = touchBegan, InputChanged = touchMoved, InputEnded = touchEnded } do
	table.insert(
		inputConnections,
		UserInputService[signalName]:Connect(function(input, processed)
			if shown and shown.touch and input.UserInputType == Enum.UserInputType.Touch then
				local handled, problem = pcall(handler, shown.touch, input, processed)

				if not handled then
					warn("[BikeDashboardClient] touch: " .. tostring(problem))
				end
			end
		end)
	)
end

table.insert(
	inputConnections,
	UserInputService.WindowFocusReleased:Connect(function()
		if shown and shown.touch then
			pcall(releaseTouch, shown.touch)
		end
	end)
)

script.Destroying:Connect(function()
	stepConnection:Disconnect()

	for _, connection in inputConnections do
		connection:Disconnect()
	end

	hide()
end)
