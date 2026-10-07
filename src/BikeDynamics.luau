--[[
	BikeDynamics

	Raycast motorcycle model shared by the server (unridden bikes) and the
	rider's client (the bike it owns). The chassis is one rigid assembly; the
	wheels and fork are visual. Every physics frame:

	1. Tire contact. The tire is a torus: wheel radius r with a round
	   cross-section of radius rho (half the tire width). Spherecasts placed
	   on its core circle sweep it along the suspension axis, so the wheel
	   meets curbs with its real profile and the contact normal comes from
	   the surface that was actually hit.

	2. Suspension. A preloaded spring-damper per wheel whose rate and damping
	   come from ride frequency and damping ratio on the measured static
	   corner load. The fork/swingarm only strokes along its axis and carries
	   everything else rigidly, so the contact force acts along the contact
	   normal with magnitude spring / (axis . normal). On a step edge the
	   normal tilts back: the same law gives lift plus the push-back a real
	   wheel feels, and a step close to the wheel radius acts like a wall.
	   It is solved implicitly as a soft contact constraint, so it stays
	   stable at any frame rate and bottoming out is just a stiffer spring.

	3. Tires. Pacejka Magic Formula force curves (lateral and longitudinal,
	   combined by the similarity method) with camber thrust, load
	   sensitivity, relaxation length and rolling resistance. They are
	   solved implicitly as velocity constraints together with wheel spin,
	   drive and brakes (projected Gauss-Seidel): the curve enters as its
	   secant stiffness at the current slip, which stays stable at any frame
	   rate and still lets grip fall off once the tire slides past its peak.

	4. Roll. The lean obeys the bicycle roll equation about the tire contact
	   line, I * roll'' = m g h sin(roll) - m h a_lat cos(roll) + gyroscopic
	   moments, where the path acceleration a_lat = (v^2 + b v') tan(steer)/L
	   + b v steer' sec^2(steer)/L carries the countersteer effect. The
	   rider balances it the way a real rider does, by choosing the steering
	   rate; at walking pace, where steering cannot hold the bike up, the
	   rider's feet support it. A rigid roll constraint enforces the result.

	   Riding pose: in a steady turn tan(steer) / tan(lean) = L g / v^2, so
	   under Roblox gravity this bike steers more than it leans below about
	   30 studs/s, which looks like a bicycle. There the bike is shown in
	   the pose it would have yawing at the same rate at that speed: the
	   visual handlebar turns less (tan / q) and the chassis leans more
	   (tan * q). The extra lean is cosmetic; the roll state, steering and
	   tire camber stay physical.

	5. Air and rolling resistance. Drag 1/2 rho Cd A v^2 from the map's air
	   density and wind, frontal area from the bike and rider silhouette.

	6. Engine and brakes. The engine is a rotating mass in the same solve:
	   its torque curve drives the crank, a centrifugal clutch (friction
	   that grows with rpm^2) couples it through the gearing to the rear
	   wheel, and the rev limiter and idle control are one-sided limits on
	   crank speed. Brakes are friction torques on the wheels; with ABS a
	   brake only takes its wheel down to the tire's peak slip.

	RiderControls (bottom of this module) turns rider input into the
	controls for step(): linked brakes split by load transfer, traction
	control and a manual sequential gearbox.
]]

local BikeDynamics = {}
BikeDynamics.__index = BikeDynamics

-- Names of what the rig adds to the bike (BikeDynamics.Names).
local NAMES = table.freeze({
	Folder = "BikeRig",
	FrontWheelJoint = "BikeFrontWheelJoint",
	RearWheelJoint = "BikeRearWheelJoint",
	ForkJoint = "BikeForkJoint",
	-- Exterior shell joints (only when the bike has an exterior).
	SteerJoint = "BikeSteerJoint",
	SwingarmJoint = "BikeSwingarmJoint",
	ExteriorAttribute = "BikeExteriorParts",
	FrontContact = "BikeFrontContact",
	RearContact = "BikeRearContact",
	FrontForce = "BikeFrontTireForce",
	RearForce = "BikeRearTireForce",
	AeroAttachment = "BikeAeroAttachment",
	AeroForce = "BikeAeroForce",
	TorqueAttachment = "BikeTorqueAttachment",
	ChassisTorque = "BikeChassisTorque",
	RollAttachment = "BikeRollAttachment",
	UprightAttachment = "BikeUprightAttachment",
	RollAlign = "BikeRollAlign",
	Collider = "BikeCollider",
	FrontAxleMass = "BikeFrontAxleMass",
	RearAxleMass = "BikeRearAxleMass",
	Ballast = "BikeBallast",
	ReadyAttribute = "BikeRigReady",
})

BikeDynamics.Names = NAMES

local WORLD_UP = Vector3.new(0, 1, 0)
local EPSILON = 1e-6
-- Longest step (s): after a hitch the frame is stepped this long, never longer.
local MAX_STEP = 1 / 15
-- Projected Gauss-Seidel passes per step.
local SOLVER_ITERATIONS = 8
-- While a brake holds a stopped wheel the two tires both pin the chassis to
-- the road; the solve needs more passes to share the load between them
-- (with too few, they end up pushing against each other).
local HELD_SOLVER_ITERATIONS = 32
-- Mass properties are read again this often (s), and when a rider gets on or off.
local MASS_REFRESH_INTERVAL = 1
-- Contact normals steeper than this relative to the suspension axis are
-- clamped when mapping the axial spring onto the normal (about 75 deg).
local MIN_AXIS_NORMAL_DOT = 0.25
-- A tire this close (studs) to the ground counts as touching it.
local TIRE_TOUCH_TOLERANCE = 0.02
-- Below this travel per frame (studs) the contact is not swept.
local SWEEP_MIN_DISTANCE = 0.05
-- Hits whose normal is more than 85 degrees from the suspension axis are
-- vertical faces; the next profile sample or the body collider handles them.
local MIN_CONTACT_NORMAL_DOT = math.cos(math.rad(85))
-- Camber thrust stops growing past this tilt of the tire against the ground.
local MAX_CAMBER = math.rad(75)
-- A braked wheel whose contact patch is slower than this share of the
-- slip reference minimum speed is held still by its brake.
local STICK_SPEED_SHARE = 0.25
-- The turn rate of the direction of travel is smoothed at this rate (1/s),
-- and measured only above this speed (studs/s).
local COURSE_RATE_RESPONSE = 10
local COURSE_MINIMUM_SPEED = 2
-- The roll equation is integrated in this many substeps per frame.
local ROLL_SUBSTEPS = 4
-- Measured lean further than this from the roll state means something
-- external (a collision) moved the chassis; the roll state follows it.
local ROLL_RESYNC_ANGLE = math.rad(8)
-- The riding pose follows speed changes at this rate (1/s), so a sudden
-- stop (a collision) does not snap the shown lean.
local POSE_RATIO_RESPONSE = 8
-- Smoothing of the measured forward acceleration (1/s).
local ACCELERATION_FILTER_RESPONSE = 10
-- Roblox's default Workspace.AirDensity, when the map's cannot be read.
local DEFAULT_AIR_DENSITY = 0.0012
local RAD_PER_RPM = math.pi / 30
-- Cornering ABS keeps at least this share of the tire's grip for braking,
-- so the brakes never vanish completely in a lean.
local ABS_MINIMUM_FORCE_SHARE = 0.3
-- ABS valve: while the tire is past its peak the brake pressure drops at
-- this rate per unit of excess slip (1/s); while it grips, pressure builds
-- back at the build rate (1/s). Real ABS cycles the same way, a few times
-- a second.
local ABS_DUMP_RATE = 20
local ABS_BUILD_RATE = 4

-- Physical actuators an older rig may have left in the model; buildRig removes them.
local LEGACY_ACTUATOR_CLASSES = {
	HingeConstraint = true,
	PrismaticConstraint = true,
	CylindricalConstraint = true,
	SpringConstraint = true,
	RodConstraint = true,
	RopeConstraint = true,
	BallSocketConstraint = true,
	UniversalConstraint = true,
	TorsionSpringConstraint = true,
	RigidConstraint = true,
	PlaneConstraint = true,
	AlignOrientation = true,
	AlignPosition = true,
	AngularVelocity = true,
	LinearVelocity = true,
	Torque = true,
	VectorForce = true,
	LineForce = true,
}

-- value limited to minimum..maximum.
local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

-- 0 at edge0, 1 at edge1, with a smooth (zero slope) start and end.
local function smoothstep(edge0, edge1, value)
	if edge1 <= edge0 then
		return value >= edge1 and 1 or 0
	end

	local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)

	return t * t * (3 - 2 * t)
end

-- First-order lag toward target at response (1/s), frame-rate independent.
local function approach(current, target, response, deltaTime)
	return current + (target - current) * (1 - math.exp(-response * deltaTime))
end

-- At most maximumDelta closer to target.
local function moveToward(current, target, maximumDelta)
	if current < target then
		return math.min(current + maximumDelta, target)
	end

	return math.max(current - maximumDelta, target)
end

-- Unit vector, or fallback for a (near) zero vector.
local function safeUnit(vector, fallback)
	local magnitude = vector.Magnitude

	if magnitude < EPSILON then
		return fallback
	end

	return vector / magnitude
end

-- Angle wrapped to -pi..pi.
local function wrapAngle(angle)
	return math.atan2(math.sin(angle), math.cos(angle))
end

-- Rodrigues rotation of a vector about a unit axis.
local function rotateAroundAxis(vector, axis, angle)
	local cosine = math.cos(angle)
	local sine = math.sin(angle)

	return vector * cosine
		+ axis:Cross(vector) * sine
		+ axis * (axis:Dot(vector) * (1 - cosine))
end

-- 3x3 matrices are row-major arrays of 9 numbers.
local function mat3Zero()
	return { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end

-- m * v.
local function mat3MulVector(m, v)
	return Vector3.new(
		m[1] * v.X + m[2] * v.Y + m[3] * v.Z,
		m[4] * v.X + m[5] * v.Y + m[6] * v.Z,
		m[7] * v.X + m[8] * v.Y + m[9] * v.Z
	)
end

-- m += scale * v v^T (inertia tensor terms).
local function mat3AddOuter(m, v, scale)
	m[1] += scale * v.X * v.X
	m[2] += scale * v.X * v.Y
	m[3] += scale * v.X * v.Z
	m[4] += scale * v.Y * v.X
	m[5] += scale * v.Y * v.Y
	m[6] += scale * v.Y * v.Z
	m[7] += scale * v.Z * v.X
	m[8] += scale * v.Z * v.Y
	m[9] += scale * v.Z * v.Z
end

-- Inverse by cofactors; nil when singular.
local function mat3Inverse(m)
	local a, b, c = m[1], m[2], m[3]
	local d, e, f = m[4], m[5], m[6]
	local g, h, i = m[7], m[8], m[9]
	local cofactor11 = e * i - f * h
	local cofactor12 = -(d * i - f * g)
	local cofactor13 = d * h - e * g
	local determinant = a * cofactor11 + b * cofactor12 + c * cofactor13

	if math.abs(determinant) < 1e-12 then
		return nil
	end

	local scale = 1 / determinant

	return {
		cofactor11 * scale,
		-(b * i - c * h) * scale,
		(b * f - c * e) * scale,
		cofactor12 * scale,
		(a * i - c * g) * scale,
		-(a * f - c * d) * scale,
		cofactor13 * scale,
		-(a * h - b * g) * scale,
		(a * e - b * d) * scale,
	}
end

--[=[
	Pacejka Magic Formula normalized so the peak (value 1) sits at slip 1:
	f(s) = sin(C * atan(B s - E (B s - atan(B s)))). B follows from C and E.
	Its slope at zero is C * B, so a tire with initial stiffness k (per unit
	load) and peak friction mu peaks at slip mu * C * B / k.
]=]
local function makeTireCurve(shape, curvature)
	shape = math.max(shape, 1.05)
	curvature = math.min(curvature, 0.95)

	local target = math.tan(math.pi / (2 * shape))
	local low, high = 0, 1000

	-- B - E (B - atan B) is increasing in B for E < 1.
	for _ = 1, 80 do
		local middle = (low + high) * 0.5

		if middle - curvature * (middle - math.atan(middle)) < target then
			low = middle
		else
			high = middle
		end
	end

	local stiffness = (low + high) * 0.5

	return {
		shape = shape,
		curvature = curvature,
		stiffness = stiffness,
		slope = shape * stiffness,
	}
end

-- Normalized tire force at a normalized slip (peak 1 at slip 1).
local function tireCurveValue(curve, slip)
	local x = curve.stiffness * slip

	return math.sin(curve.shape * math.atan(x - curve.curvature * (x - math.atan(x))))
end

-- Principal moments of a part about its own center, in part space.
local function partPrincipalInertia(part, mass)
	local size = part.Size
	local shapeName = "Block"

	if part:IsA("Part") then
		shapeName = part.Shape.Name
	end

	if shapeName == "Ball" then
		local radius = math.min(size.X, size.Y, size.Z) * 0.5
		local moment = 0.4 * mass * radius * radius

		return moment, moment, moment
	elseif shapeName == "Cylinder" then
		local radius = math.min(size.Y, size.Z) * 0.5
		local length = size.X
		local axial = 0.5 * mass * radius * radius
		local radial = mass * (3 * radius * radius + length * length) / 12

		return axial, radial, radial
	end

	return mass * (size.Y * size.Y + size.Z * size.Z) / 12,
		mass * (size.X * size.X + size.Z * size.Z) / 12,
		mass * (size.X * size.X + size.Y * size.Y) / 12
end

-- A wheel part's radius (a cylinder along X).
local function wheelRadius(part)
	return math.max(part.Size.Y, part.Size.Z) * 0.5
end

-- Wheel mass from its cylinder volume and Mass.WheelDensity.
local function wheelMass(part, massConfig)
	local radius = wheelRadius(part)

	return massConfig.WheelDensity * math.pi * radius * radius * part.Size.X
end

-- The optional exterior shell (config.Rig.Exterior) of the bike.
local function findExterior(bike, rigConfig)
	local exterior = rigConfig.Exterior and bike:FindFirstChild(rigConfig.Exterior)

	if exterior and exterior:IsA("Model") then
		return exterior
	end

	return nil
end

-- First descendant of the bike of a class (and name) outside the exterior,
-- whose groups and parts may reuse rig names.
local function findRigInstance(bike, className, name, exterior)
	for _, descendant in bike:GetDescendants() do
		if
			(name == nil or descendant.Name == name)
			and descendant:IsA(className)
			and not (exterior and descendant:IsDescendantOf(exterior))
		then
			return descendant
		end
	end

	return nil
end

-- A rig part by name (frame or exterior); asserts when required.
local function findPart(bike, name, required, exterior)
	local object = findRigInstance(bike, "BasePart", name, exterior)

	assert(object or not required, string.format("BikeDynamics: %s (BasePart) not found.", name))

	return object
end

-- Terrain materials' default physical properties, read once per material.
local terrainProperties = {}

-- Combined contact friction using Roblox's rule for two touching materials.
local function contactFriction(hit, tireConfig)
	local instance = hit.Instance
	local surfaceFriction = 0.5
	local surfaceWeight = 1

	if instance:IsA("Terrain") then
		local properties = terrainProperties[hit.Material]

		if properties == nil then
			properties = PhysicalProperties.new(hit.Material)
			terrainProperties[hit.Material] = properties
		end

		surfaceFriction = properties.Friction
		surfaceWeight = properties.FrictionWeight
	elseif instance:IsA("BasePart") then
		local properties = instance.CurrentPhysicalProperties
		surfaceFriction = properties.Friction
		surfaceWeight = properties.FrictionWeight
	end

	local tireWeight = tireConfig.FrictionWeight

	return (tireConfig.Friction * tireWeight + surfaceFriction * surfaceWeight)
		/ math.max(tireWeight + surfaceWeight, EPSILON)
end

-- Velocity of the contacted surface, so moving platforms carry the bike.
-- Anchored parts count too: Roblox uses an anchored part's assembly
-- velocity as a conveyor speed for whatever touches it.
local function surfaceVelocity(instance, point)
	if instance:IsA("Terrain") or not instance:IsA("BasePart") then
		return Vector3.zero
	end

	return instance.AssemblyLinearVelocity
		+ instance.AssemblyAngularVelocity:Cross(point - instance.AssemblyCenterOfMass)
end

--[=[
	Engine and drivetrain relations shared by the rider controller and the
	offline bench.
]=]
local Powertrain = {}
BikeDynamics.Powertrain = Powertrain

-- Full-throttle engine torque at rpm from the dyno table (linear between points).
function Powertrain.engineTorque(drivetrain, rpm)
	local curve = drivetrain.TorqueCurve

	if rpm <= curve[1][1] then
		return curve[1][2]
	end

	for index = 2, #curve do
		local lower = curve[index - 1]
		local upper = curve[index]

		if rpm <= upper[1] then
			return lower[2] + (upper[2] - lower[2]) * (rpm - lower[1]) / (upper[1] - lower[1])
		end
	end

	return curve[#curve][2]
end

-- Highest torque on the full-throttle curve.
function Powertrain.peakTorque(drivetrain)
	local peak = 0

	for _, point in drivetrain.TorqueCurve do
		peak = math.max(peak, point[2])
	end

	return peak
end

-- Lowest engine speed at which the full-throttle torque reaches its peak.
function Powertrain.peakTorqueRPM(drivetrain)
	local peak = Powertrain.peakTorque(drivetrain)

	for _, point in drivetrain.TorqueCurve do
		if point[2] >= peak then
			return point[1]
		end
	end

	return drivetrain.RedlineRPM
end

-- Closed-throttle drag of the engine: a part that stays at any speed
-- (EngineBrakePumpingShare of the drag at the limiter: pumping against the
-- shut throttle) plus friction that grows with rpm.
function Powertrain.engineBrakeTorque(drivetrain, rpm)
	local constant = clamp(drivetrain.EngineBrakePumpingShare or 0.2, 0, 1)

	return Powertrain.peakTorque(drivetrain)
		* drivetrain.EngineBrakeTorqueRatio
		* (constant + (1 - constant) * clamp(rpm / drivetrain.RevLimitRPM, 0, 1))
end

-- Net crank torque at rpm for a throttle opening (0..1): the full-load
-- curve (after drivetrain losses) scaled by throttle, minus the losses of
-- the closed part of the throttle.
function Powertrain.netTorque(drivetrain, rpm, throttle)
	return throttle * Powertrain.engineTorque(drivetrain, rpm) * drivetrain.Efficiency
		- (1 - throttle) * Powertrain.engineBrakeTorque(drivetrain, rpm)
end

--[=[
	Crank inertia from the free-rev time: at full throttle in neutral,
	I * d(omega)/dt = T(omega), so t = I * integral(d omega / T) from idle
	to the limiter.
]=]
function Powertrain.engineInertia(drivetrain)
	local steps = 64
	local low = drivetrain.IdleRPM
	local high = math.max(drivetrain.RevLimitRPM, low + 1)
	local stepOmega = (high - low) * RAD_PER_RPM / steps
	local integral = 0

	for index = 1, steps do
		local rpm = low + (high - low) * (index - 0.5) / steps

		integral += stepOmega / math.max(Powertrain.netTorque(drivetrain, rpm, 1), EPSILON)
	end

	return math.max(drivetrain.FreeRevTime, 0.01) / integral
end

--[=[
	Friction torque the centrifugal clutch can carry at engine speed rpm:
	the shoes press outward with centrifugal force (proportional to rpm^2)
	against their springs, from zero at ClutchEngageRPM to full capacity
	at ClutchLockRPM.
]=]
function Powertrain.clutchCapacity(drivetrain, rpm)
	local engage = drivetrain.ClutchEngageRPM
	local lock = math.max(drivetrain.ClutchLockRPM, engage + 1)
	local fraction = clamp((rpm * rpm - engage * engage) / (lock * lock - engage * engage), 0, 1)

	return fraction * drivetrain.ClutchCapacityRatio * Powertrain.peakTorque(drivetrain)
end

-- Gear ratio times final drive; 0 in neutral.
function Powertrain.overallRatio(drivetrain, gear)
	local ratio = drivetrain.GearRatios[gear]

	return ratio and ratio * drivetrain.FinalDriveRatio or 0
end

-- Wheel speed (rad/s) at which the engine reaches the rev limiter in a gear.
function Powertrain.revLimitWheelOmega(drivetrain, gearRatio)
	return drivetrain.RevLimitRPM * RAD_PER_RPM / (gearRatio * drivetrain.FinalDriveRatio)
end

-- Highest engine speed in reverse, where the ride-by-wire throttle holds
-- the engine (ReverseRevLimitRPM, never above the rev limit; the rev limit
-- when it is not set).
function Powertrain.reverseLimitRPM(drivetrain)
	return math.min(drivetrain.ReverseRevLimitRPM or drivetrain.RevLimitRPM, drivetrain.RevLimitRPM)
end

-- Reverse gear ratio (before the final drive): the one that puts the
-- reverse rev limit at ReverseTopSpeed for a rear wheel of this radius;
-- nil when the bike has no reverse.
function Powertrain.reverseRatio(drivetrain, rearRadius)
	local topSpeed = drivetrain.ReverseTopSpeed

	if topSpeed == nil or topSpeed <= 0 then
		return nil
	end

	return Powertrain.reverseLimitRPM(drivetrain) * RAD_PER_RPM * rearRadius / (topSpeed * drivetrain.FinalDriveRatio)
end

-- Every BasePart under root.
local function partsOf(root)
	local parts = {}

	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

-- Frame at `origin` looking at `target`, upright along `up`.
local function frameToward(origin, target, up)
	local look = (target - origin).Unit
	local right = look:Cross(up).Unit

	return CFrame.fromMatrix(origin, right, right:Cross(look))
end

-- World CFrame of an attachment marker inside a group.
local function markerCFrame(group, name)
	local marker = group and group:FindFirstChild(name, true)

	if marker and marker:IsA("Attachment") and marker.Parent:IsA("BasePart") then
		return marker.Parent.CFrame * marker.CFrame
	end

	return nil
end

--[=[
	Optional exterior shell (config.Rig.Exterior): a Model whose child models
	say how their parts move.

		Body        fixed to the chassis
		Steering    turns with the handlebar
		Fork        turns and strokes with the front suspension
		FrontWheel  turns, strokes and spins with the front wheel
		RearWheel   strokes and spins with the rear wheel
		Swingarm    pivots about its "Pivot" attachment to follow the rear axle

	Anything else is fixed to the chassis. Each wheel group marks the wheel
	center with an "Axle" attachment; the shell is first moved so those sit
	on the physics wheel centers. The shell only looks: its parts are
	massless, never collide and are not raycast, and the rig's placeholder
	visuals are hidden. Returns the number of shell parts.
]=]
local function attachExterior(exterior, rig, frame, frontWheel, rearWheel, fork, seat)
	local frameCFrame = frame.CFrame
	local parts = partsOf(exterior)
	local frontAxle = markerCFrame(exterior:FindFirstChild("FrontWheel"), "Axle")
	local rearAxle = markerCFrame(exterior:FindFirstChild("RearWheel"), "Axle")

	if frontAxle and rearAxle then
		local shell = frameToward(rearAxle.Position, frontAxle.Position, rearAxle.UpVector)
		local wheels = frameToward(rearWheel.CFrame.Position, frontWheel.CFrame.Position, frameCFrame.UpVector)
		local placement = wheels * shell:Inverse()

		for _, part in parts do
			part.CFrame = placement * part.CFrame
		end
	end

	local welds = Instance.new("Folder")
	welds.Name = "ExteriorWelds"
	welds.Parent = rig

	-- Welds a shell part to its group's root part.
	local function weld(base, part)
		local constraint = Instance.new("WeldConstraint")
		constraint.Part0 = base
		constraint.Part1 = part
		constraint.Parent = welds
	end

	-- One root part on a Motor6D from the chassis (joint frame c0 in chassis
	-- space), the rest welded to it.
	local function drive(groupParts, name, c0)
		local root = groupParts[1]
		local joint = Instance.new("Motor6D")
		joint.Name = name
		joint.Part0 = frame
		joint.Part1 = root
		joint.C0 = c0
		joint.C1 = root.CFrame:ToObjectSpace(frameCFrame * c0)
		joint.Parent = rig

		for index = 2, #groupParts do
			weld(root, groupParts[index])
		end

		return root
	end

	local steeringRoot = nil
	local driven = {}

	local steering = exterior:FindFirstChild("Steering")
	local steeringParts = steering and partsOf(steering) or {}

	if #steeringParts > 0 then
		steeringRoot = drive(steeringParts, NAMES.SteerJoint, frameCFrame:ToObjectSpace(steeringParts[1].CFrame))
	end

	local swingarm = exterior:FindFirstChild("Swingarm")
	local swingarmParts = swingarm and partsOf(swingarm) or {}
	local pivot = swingarm and markerCFrame(swingarm, "Pivot")

	if #swingarmParts > 0 and pivot then
		-- Joint frame at the pivot with the chassis axes: the swingarm turns
		-- about the chassis right axis there.
		drive(swingarmParts, NAMES.SwingarmJoint, CFrame.new(frameCFrame:PointToObjectSpace(pivot.Position)))
	end

	for _, part in steeringParts do
		driven[part] = true
	end

	if pivot then
		for _, part in swingarmParts do
			driven[part] = true
		end
	end

	-- Groups that ride on a rig part already moved by updateVisuals.
	local carriers = {
		Fork = fork or steeringRoot or frame,
		FrontWheel = frontWheel,
		RearWheel = rearWheel,
	}

	for _, part in parts do
		if not driven[part] then
			local group = part

			while group.Parent ~= exterior do
				group = group.Parent
			end

			weld(carriers[group.Name] or frame, part)
		end
	end

	for _, part in parts do
		part.Massless = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Anchored = false
	end

	for _, placeholder in { frame, frontWheel, rearWheel, fork or frame, seat or frame } do
		placeholder.Transparency = 1
	end

	return #parts
end

--[=[
	Server-only. Converts the authored model into the raycast rig: removes
	the old physical joints, makes wheels/fork visual, adds axle masses,
	ballast, a body collider, contact forces and the roll constraint, and
	attaches the exterior shell if the bike has one.
]=]
function BikeDynamics.buildRig(bike, config)
	local rigConfig = config.Rig
	local massConfig = config.Mass
	local exterior = findExterior(bike, rigConfig)
	local frame = findPart(bike, rigConfig.ChassisPart, true, exterior)
	local frontWheel = findPart(bike, rigConfig.FrontWheel, true, exterior)
	local rearWheel = findPart(bike, rigConfig.RearWheel, true, exterior)
	local fork = rigConfig.FrontFork and findPart(bike, rigConfig.FrontFork, false, exterior)
	local seat = findRigInstance(bike, "VehicleSeat", nil, exterior)

	-- Authored poses in chassis space, captured before anything moves.
	frame.Anchored = true

	local frameCFrame = frame.CFrame
	local frontRest = frameCFrame:ToObjectSpace(frontWheel.CFrame)
	local rearRest = frameCFrame:ToObjectSpace(rearWheel.CFrame)
	local forkRest = fork and frameCFrame:ToObjectSpace(fork.CFrame)

	local previousRig = bike:FindFirstChild(NAMES.Folder)

	if previousRig then
		previousRig:Destroy()
	end

	for _, descendant in bike:GetDescendants() do
		if LEGACY_ACTUATOR_CLASSES[descendant.ClassName] or descendant:IsA("BodyMover") then
			descendant:Destroy()
		end
	end

	for _, name in {
		NAMES.RollAttachment,
		NAMES.UprightAttachment,
		NAMES.FrontContact,
		NAMES.RearContact,
		NAMES.AeroAttachment,
		NAMES.TorqueAttachment,
	} do
		local stale = frame:FindFirstChild(name)

		if stale then
			stale:Destroy()
		end
	end

	local rig = Instance.new("Folder")
	rig.Name = NAMES.Folder

	-- Welds a rig part to the chassis frame.
	local function weldToFrame(part)
		local weld = Instance.new("WeldConstraint")
		weld.Name = part.Name .. "Weld"
		weld.Part0 = frame
		weld.Part1 = part
		weld.Parent = rig
	end

	-- A looks-only part: massless, no collisions, touches or raycasts.
	local function makeVisual(part)
		part.Anchored = false
		part.Massless = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end

	-- A Motor6D from the frame that moves a visual part (wheel, fork).
	local function makeJoint(name, part, restCFrame)
		makeVisual(part)

		local joint = Instance.new("Motor6D")
		joint.Name = name
		joint.C0 = restCFrame
		joint.C1 = CFrame.identity
		joint.Part0 = frame
		joint.Part1 = part
		joint.Parent = rig

		return joint
	end

	makeJoint(NAMES.FrontWheelJoint, frontWheel, frontRest)
	makeJoint(NAMES.RearWheelJoint, rearWheel, rearRest)

	if fork then
		makeJoint(NAMES.ForkJoint, fork, forkRest)
	end

	-- The seat rides on the chassis whether or not the model brought its own
	-- weld (a second weld between the same parts changes nothing).
	if seat then
		seat.Anchored = false
		seat.Massless = true
		seat.CanCollide = false
		weldToFrame(seat)
	end

	bike:SetAttribute(
		NAMES.ExteriorAttribute,
		exterior and attachExterior(exterior, rig, frame, frontWheel, rearWheel, fork, seat) or 0
	)

	-- An invisible part that carries a share of the bike's mass.
	local function makeMassPart(name, size, cframe, mass)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = cframe
		part.Transparency = 1
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = false

		local volume = size.X * size.Y * size.Z
		local density = mass / math.max(volume, EPSILON)

		if density > 100 or density < 0.0001 then
			warn(string.format(
				"BikeDynamics: %s needs density %.4f outside Roblox limits; mass will differ.",
				name,
				density
			))
		end

		part.CustomPhysicalProperties = PhysicalProperties.new(clamp(density, 0.0001, 100), 0, 0)
		part.Parent = rig
		weldToFrame(part)

		return part
	end

	-- Wheel mass rides with the chassis at each axle. It sets realistic yaw
	-- and pitch inertia; the visual wheels themselves are massless.
	for _, entry in { { NAMES.FrontAxleMass, frontWheel, frontRest }, { NAMES.RearAxleMass, rearWheel, rearRest } } do
		local wheel = entry[2]
		local radius = wheelRadius(wheel)

		makeMassPart(
			entry[1],
			Vector3.new(wheel.Size.X, radius, radius),
			frameCFrame * CFrame.new(entry[3].Position),
			wheelMass(wheel, massConfig)
		)
	end

	makeMassPart(
		NAMES.Ballast,
		massConfig.BallastSize,
		frameCFrame * CFrame.new(massConfig.BallastLocalPosition),
		massConfig.BallastMass
	)

	-- Body collider from the axle height up, spanning both tires. Anything
	-- lower is terrain for the tire model; anything higher is a wall.
	local frontRadius = wheelRadius(frontWheel)
	local rearRadius = wheelRadius(rearWheel)
	local groundY = math.min(frontRest.Y - frontRadius, rearRest.Y - rearRadius)
	local bottomY = groundY + math.max(frontRadius, rearRadius) * rigConfig.ColliderClearanceRatio
	local topY = math.max(frame.Size.Y * 0.5, bottomY + 0.2)
	local frontZ = math.min(frontRest.Z - frontRadius, rearRest.Z - rearRadius)
	local backZ = math.max(frontRest.Z + frontRadius, rearRest.Z + rearRadius)
	local width = math.max(frontWheel.Size.X, rearWheel.Size.X, frame.Size.X)

	local collider = Instance.new("Part")
	collider.Name = NAMES.Collider
	collider.Size = Vector3.new(width, topY - bottomY, backZ - frontZ)
	collider.CFrame = frameCFrame
		* CFrame.new((frontRest.X + rearRest.X) * 0.5, (topY + bottomY) * 0.5, (frontZ + backZ) * 0.5)
	collider.Transparency = 1
	collider.Anchored = false
	collider.CanCollide = true
	collider.CanTouch = false
	collider.CanQuery = true
	collider.Massless = true
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
	collider.Parent = rig
	weldToFrame(collider)

	-- An attachment on the frame (contact points, force origins).
	local function makeAttachment(name, cframe)
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.CFrame = cframe
		attachment.Parent = frame

		return attachment
	end

	for _, entry in { { NAMES.FrontContact, NAMES.FrontForce }, { NAMES.RearContact, NAMES.RearForce } } do
		local attachment = makeAttachment(entry[1], CFrame.identity)
		local force = Instance.new("VectorForce")
		force.Name = entry[2]
		force.Attachment0 = attachment
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass = false
		force.Force = Vector3.zero
		force.Parent = rig
	end

	-- Air drag acts through the center of mass.
	local aeroForce = Instance.new("VectorForce")
	aeroForce.Name = NAMES.AeroForce
	aeroForce.Attachment0 = makeAttachment(NAMES.AeroAttachment, CFrame.identity)
	aeroForce.RelativeTo = Enum.ActuatorRelativeTo.World
	aeroForce.ApplyAtCenterOfMass = true
	aeroForce.Force = Vector3.zero
	aeroForce.Parent = rig

	-- Pure torque on the chassis: the wheels' suspension forces act at the
	-- axles (the tire forces are applied at the contacts), and spinning the
	-- wheels and engine up or down twists the chassis the other way.
	local chassisTorque = Instance.new("Torque")
	chassisTorque.Name = NAMES.ChassisTorque
	chassisTorque.Attachment0 = makeAttachment(NAMES.TorqueAttachment, CFrame.identity)
	chassisTorque.RelativeTo = Enum.ActuatorRelativeTo.World
	chassisTorque.Torque = Vector3.zero
	chassisTorque.Parent = rig

	-- Primary axis = chassis right (roll-only mode) or chassis up (upright).
	local rollAttachment = makeAttachment(NAMES.RollAttachment, CFrame.identity)
	makeAttachment(NAMES.UprightAttachment, CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, -Vector3.xAxis))

	local align = Instance.new("AlignOrientation")
	align.Name = NAMES.RollAlign
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = rollAttachment
	align.AlignType = Enum.AlignType.PrimaryAxisPerpendicular
	align.PrimaryAxis = WORLD_UP
	align.RigidityEnabled = true
	align.ReactionTorqueEnabled = false
	align.Parent = rig

	rig.Parent = bike

	frame.Massless = false
	frame.CanCollide = false
	frame.RootPriority = 127
	frame.Anchored = false
	bike.PrimaryPart = frame
	bike:SetAttribute(NAMES.ReadyAttribute, true)

	return rig
end

-- The chassis part and the seat of a bike (not those in its exterior).
function BikeDynamics.rigParts(bike, config)
	local exterior = findExterior(bike, config.Rig)

	return findPart(bike, config.Rig.ChassisPart, false, exterior), findRigInstance(bike, "VehicleSeat", nil, exterior)
end

--[=[
	Client-side. With StreamingEnabled the bike's parts stream in only near
	the player (and out again far away). Returns nil when every instance
	BikeDynamics.new and VisualRig need is on this client now, otherwise the
	name of the first one missing.
]=]
function BikeDynamics.rigMissing(bike, config)
	local frame = findPart(bike, config.Rig.ChassisPart, false, findExterior(bike, config.Rig))
	local rig = bike:FindFirstChild(NAMES.Folder)

	if frame == nil then
		return config.Rig.ChassisPart
	end

	if findRigInstance(bike, "VehicleSeat", nil, findExterior(bike, config.Rig)) == nil then
		return "VehicleSeat"
	end

	if rig == nil then
		return NAMES.Folder
	end

	for _, name in { NAMES.FrontWheelJoint, NAMES.RearWheelJoint } do
		local joint = rig:FindFirstChild(name)

		if joint == nil or joint.Part1 == nil or not joint.Part1:IsDescendantOf(bike) then
			return name
		end
	end

	for _, name in { NAMES.FrontForce, NAMES.RearForce, NAMES.AeroForce, NAMES.ChassisTorque, NAMES.RollAlign } do
		if rig:FindFirstChild(name) == nil then
			return name
		end
	end

	for _, name in {
		NAMES.FrontContact,
		NAMES.RearContact,
		NAMES.RollAttachment,
		NAMES.UprightAttachment,
		NAMES.AeroAttachment,
		NAMES.TorqueAttachment,
	} do
		if frame:FindFirstChild(name) == nil then
			return name
		end
	end

	return nil
end

--[=[
	Client-side. Waits until the rig is on this client (see rigMissing).
	Returns nil when ready, otherwise what is still missing after the
	timeout.
]=]
function BikeDynamics.waitForRig(bike, config, timeout)
	local deadline = os.clock() + (timeout or 10)
	local missing = BikeDynamics.rigMissing(bike, config)

	while missing do
		if os.clock() >= deadline then
			return missing
		end

		task.wait()
		missing = BikeDynamics.rigMissing(bike, config)
	end

	return nil
end

-- Telescopic fork: the steering axis is also the front suspension axis.
-- Returns the axis and a point on it (chassis space).
local function steeringOf(frontJoint, forkJoint)
	if forkJoint == nil then
		return Vector3.yAxis, frontJoint.C0.Position
	end

	local axis = forkJoint.C0.UpVector

	return axis.Y < 0 and -axis or axis, forkJoint.C0.Position
end

-- One wheel's suspension, tire and contact state, from its joint and the config.
local function makeWheel(joint, force, attachment, suspensionAxis, suspension, config, isFront)
	local part = joint.Part1
	local restCFrame = joint.C0
	local radius = wheelRadius(part)
	local width = part.Size.X
	local profileRadius = math.min(width * 0.5, radius * 0.45)
	local coreRadius = radius - profileRadius
	local travel = suspension.Travel
	local sag = travel * suspension.SagRatio
	local staticExtension = travel - sag
	local mass = wheelMass(part, config.Mass)
	local sampleCount = math.max(3, math.floor(config.Tire.ProfileSamples))
	local samples = {}

	-- Core circle of the torus in wheel space (X axle, Y up, -Z forward),
	-- from the rear (-90 deg) through the bottom to the front (+90 deg).
	for index = 0, sampleCount - 1 do
		local angle = -math.pi * 0.5 + math.pi * index / (sampleCount - 1)
		table.insert(samples, Vector3.new(0, -math.cos(angle), -math.sin(angle)) * coreRadius)
	end

	return {
		isFront = isFront,
		coreRadius = coreRadius,
		sampleSpacing = math.pi / (sampleCount - 1),
		-- Contact normal found last frame; the sample arc is centered on it.
		probeNormal = nil,
		joint = joint,
		force = force,
		attachment = attachment,
		restCFrame = restCFrame,
		restRotation = restCFrame.Rotation,
		axis = suspensionAxis,
		mount = restCFrame.Position + suspensionAxis * staticExtension,
		radius = radius,
		width = width,
		profileRadius = profileRadius,
		samples = samples,
		travel = travel,
		sag = sag,
		staticExtension = staticExtension,
		bumpStopStart = travel * (1 - config.Suspension.BumpStopRange),
		castMargin = radius * 0.5,
		probeExtra = radius * 0.5,
		suspension = suspension,
		mass = mass,
		spinInertia = math.max(config.Mass.WheelSpinInertiaRatio * mass * radius * radius, 0.001),
		omega = 0,
		driveTorque = 0,
		driveTarget = 0,
		brakeTorque = 0,
		rollingTorque = 0,
		driveLambda = 0,
		brakeLambda = 0,
		rollingLambda = 0,
		absLimit = math.huge,
		absPressure = 1,
		absActive = false,
		grounded = false,
		extension = travel,
		compression = 0,
		-- Unsprung wheel: suspension stroke (0 = fully extended) and its rate,
		-- carried between frames; the tire is a radial spring under it.
		unsprungMass = math.max(mass, 0.01),
		lastLoad = 0,
		stroke = sag,
		strokeRate = 0,
		axialVelocity = 0,
		lambdaSuspension = 0,
		lambdaTop = 0,
		lambdaBottom = 0,
		tireRate = 0,
		tireDamping = 0,
		-- Tire state carried between frames: slips set the point on the
		-- force curve, forces feed the relaxation (carcass) model.
		slipRatio = 0,
		slipTan = 0,
		slipForceX = 0,
		slipForceY = 0,
		relaxationLength = radius * config.Tire.RelaxationLengthRatio,
		longitudinalRelaxationLength = radius * config.Tire.LongitudinalRelaxationLengthRatio,
		contact = {},
		telemetry = {},
	}
end

-- The physics model of one bike, on the rig BikeServer built. options:
-- world (raycasts, gravity) and players (characters to ignore).
function BikeDynamics.new(bike, config, options)
	options = options or {}

	local self = setmetatable({}, BikeDynamics)
	local rig = bike:FindFirstChild(NAMES.Folder)

	assert(rig, "BikeDynamics: BikeRig is missing; BikeServer builds it.")

	self.bike = bike
	self.config = config
	self.world = options.world or workspace
	self.players = options.players

	if self.players == nil and typeof(game) == "Instance" then
		self.players = game:GetService("Players")
	end

	local exterior = findExterior(bike, config.Rig)

	self.exterior = exterior
	self.frame = findPart(bike, config.Rig.ChassisPart, true, exterior)
	self.seat = findRigInstance(bike, "VehicleSeat", nil, exterior)
	self.align = rig:FindFirstChild(NAMES.RollAlign)
	self.rollAttachment = self.frame:FindFirstChild(NAMES.RollAttachment)
	self.uprightAttachment = self.frame:FindFirstChild(NAMES.UprightAttachment)

	local frontJoint = rig:FindFirstChild(NAMES.FrontWheelJoint)
	local rearJoint = rig:FindFirstChild(NAMES.RearWheelJoint)

	assert(frontJoint and rearJoint and self.align, "BikeDynamics: rig is incomplete.")

	local steerAxis, steerPivot = steeringOf(frontJoint, rig:FindFirstChild(NAMES.ForkJoint))

	self.steerAxis = steerAxis
	self.steerPivot = steerPivot
	self.rake = math.acos(clamp(steerAxis.Y, -1, 1))

	self.front = makeWheel(
		frontJoint,
		rig:FindFirstChild(NAMES.FrontForce),
		self.frame:FindFirstChild(NAMES.FrontContact),
		steerAxis,
		config.Suspension.Front,
		config,
		true
	)
	self.rear = makeWheel(
		rearJoint,
		rig:FindFirstChild(NAMES.RearForce),
		self.frame:FindFirstChild(NAMES.RearContact),
		Vector3.yAxis,
		config.Suspension.Rear,
		config,
		false
	)
	self.wheels = { self.front, self.rear }
	self.wheelbase = math.max(
		math.abs(self.front.restCFrame.Position.Z - self.rear.restCFrame.Position.Z),
		0.1
	)

	-- The visual parts and what they show (BikeDynamics:visualState).
	self.visualRig = BikeDynamics.VisualRig.new(rig)
	self.visual = {
		handlebar = 0,
		frontTravel = 0,
		rearTravel = 0,
		frontOmega = 0,
		rearOmega = 0,
	}

	self.aeroForce = rig:FindFirstChild(NAMES.AeroForce)
	self.chassisTorque = rig:FindFirstChild(NAMES.ChassisTorque)
	self.lateralCurve = makeTireCurve(config.Tire.LateralShape, config.Tire.LateralCurvature)
	self.longitudinalCurve = makeTireCurve(config.Tire.LongitudinalShape, config.Tire.LongitudinalCurvature)

	-- Engine crank: one more spinning body in the solve, coupled to the rear
	-- wheel by the clutch and the gearing.
	self.engine = {
		omega = 0,
		inertia = Powertrain.engineInertia(config.Drivetrain),
		limitLambda = 0,
		idleLambda = 0,
		clutchLambda = 0,
	}

	self.raycastParams = RaycastParams.new()
	self.raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self.raycastParams.IgnoreWater = true
	self.raycastParams.RespectCanCollide = true

	self.steerFiltered = 0
	self.leanCommand = 0
	self.roll = 0
	self.rollRate = 0
	self.groundSteer = 0
	self.handlebar = 0
	-- Riding pose: shown speed / real speed, the cosmetic lean the chassis
	-- carries on top of the roll state, and the handlebar shown.
	self.poseRatio = 1
	self.leanOffset = 0
	self.displayHandlebar = 0
	self.lastForwardSpeed = 0
	self.forwardAcceleration = 0
	self.airDensity = DEFAULT_AIR_DENSITY
	self.wind = Vector3.zero
	self.frontalArea = 0
	self.recovering = false
	self.recoveryTimer = 0
	self.massTimer = 0
	self.alignMode = nil
	self.lastFlatForward = Vector3.new(0, 0, -1)
	self.lastCourseHeading = nil
	self.courseRate = 0
	self.lastOccupant = false

	self.state = {
		speed = 0,
		forwardSpeed = 0,
		lean = 0,
		leanTarget = 0,
		leanCommand = 0,
		balanceLean = 0,
		poseRatio = 1,
		leanCap = 0,
		muAvailable = config.Tire.Friction,
		groundSteer = 0,
		handlebar = 0,
		displayHandlebar = 0,
		leanSteerBlend = 0,
		rollRate = 0,
		countersteer = false,
		drag = 0,
		rollingResistance = 0,
		frontalArea = 0,
		yawRate = 0,
		targetYawRate = 0,
		courseRate = 0,
		pathRadius = 0,
		targetRadius = 0,
		slipAngle = 0,
		recovering = false,
		mass = 0,
		forwardAcceleration = 0,
		-- Powertrain (filled when controls.engine is used).
		engineRPM = 0,
		engineTorque = 0,
		clutchTorque = 0,
		clutchCapacity = 0,
		clutchSlipRPM = 0,
		clutchLocked = false,
		gearRatio = 0,
		wheelDriveTorque = 0,
		revLimited = false,
		front = self.front.telemetry,
		rear = self.rear.telemetry,
	}

	self:_refreshFilter()
	self:_refreshMassProperties()
	self:reset()

	return self
end

-- Mass, center of mass and inertia of the chassis assembly, plus everything
-- derived from them: static corner loads, spring rates and damping.
function BikeDynamics:_refreshMassProperties()
	local frame = self.frame
	local frameCFrame = frame.CFrame
	local mass = math.max(frame.AssemblyMass, EPSILON)
	local centerLocal = frameCFrame:PointToObjectSpace(frame.AssemblyCenterOfMass)
	local inertia = mat3Zero()
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	local rider = self.seat and self.seat.Occupant and self.seat.Occupant.Parent

	for _, part in frame:GetConnectedParts(true) do
		-- The exterior shell is looks only: the rig sets the physics, so a
		-- bike handles the same with or without a shell.
		if not part:IsA("BasePart") or (self.exterior and part:IsDescendantOf(self.exterior)) then
			continue
		end

		local relative = frameCFrame:ToObjectSpace(part.CFrame)

		-- Silhouette seen from the front: every rig part meets the air,
		-- including massless visuals. The rider's avatar is replaced by a
		-- fixed seated silhouette below, so every avatar and riding pose
		-- meets the same air.
		if not (rider and part:IsDescendantOf(rider)) then
			local half = part.Size * 0.5
			local right, up, back = relative.RightVector, relative.UpVector, -relative.LookVector
			local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
			local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z

			minX = math.min(minX, relative.Position.X - extentX)
			maxX = math.max(maxX, relative.Position.X + extentX)
			minY = math.min(minY, relative.Position.Y - extentY)
			maxY = math.max(maxY, relative.Position.Y + extentY)
		end

		if part == frame or not part.Massless then
			local partMass = part:GetMass()

			if partMass > 0 then
				local momentX, momentY, momentZ = partPrincipalInertia(part, partMass)

				mat3AddOuter(inertia, relative.RightVector, momentX)
				mat3AddOuter(inertia, relative.UpVector, momentY)
				mat3AddOuter(inertia, -relative.LookVector, momentZ)

				local offset = relative.Position - centerLocal
				local distanceSquared = offset:Dot(offset)

				inertia[1] += partMass * distanceSquared
				inertia[5] += partMass * distanceSquared
				inertia[9] += partMass * distanceSquared
				mat3AddOuter(inertia, offset, -partMass)
			end
		end
	end

	if rider then
		local aero = self.config.Aero
		local seatTop = frameCFrame:PointToObjectSpace(self.seat.CFrame * Vector3.new(0, self.seat.Size.Y * 0.5, 0))

		minX = math.min(minX, seatTop.X - aero.RiderWidth * 0.5)
		maxX = math.max(maxX, seatTop.X + aero.RiderWidth * 0.5)
		maxY = math.max(maxY, seatTop.Y + aero.RiderHeight)
	end

	local inverseInertia = mat3Inverse(inertia)

	if inverseInertia == nil then
		-- Degenerate geometry: fall back to a solid sphere of the same mass.
		local moment = 0.4 * mass
		inverseInertia = { 1 / moment, 0, 0, 0, 1 / moment, 0, 0, 0, 1 / moment }
	end

	self.mass = mass
	self.centerLocal = centerLocal
	self.inverseInertiaLocal = inverseInertia
	-- Moment of inertia about the roll (forward, chassis Z) axis through the
	-- center of mass.
	self.rollInertia = math.max(inertia[9], EPSILON)

	local gravity = math.max(self.world.Gravity, EPSILON)
	local front = self.front
	local rear = self.rear
	local frontZ = front.restCFrame.Position.Z
	local rearZ = rear.restCFrame.Position.Z
	local rearShare = clamp((centerLocal.Z - frontZ) / (rearZ - frontZ), 0.05, 0.95)
	local groundY = math.min(
		front.restCFrame.Position.Y - front.radius,
		rear.restCFrame.Position.Y - rear.radius
	)

	self.centerHeight = math.max(centerLocal.Y - groundY, 0.1)
	self.gravityRollMoment = mass * gravity * self.centerHeight
	-- Horizontal distance from the rear contact to the center of mass (the
	-- "b" of the bicycle model).
	self.rearToCenter = math.max(rearZ - centerLocal.Z, 0)

	if minX < maxX and minY < maxY then
		self.frontalArea = (maxX - minX) * (maxY - minY) * self.config.Aero.FrontalAreaFillRatio
	end

	-- Air of whatever map the bike is in (older engines lack the properties).
	local densityRead, density = pcall(function()
		return self.world.AirDensity
	end)
	local windRead, wind = pcall(function()
		return self.world.GlobalWind
	end)

	self.airDensity = densityRead and type(density) == "number" and density or DEFAULT_AIR_DENSITY
	self.wind = windRead and typeof(wind) == "Vector3" and wind or Vector3.zero

	local suspensionConfig = self.config.Suspension

	for _, wheel in self.wheels do
		local share = wheel.isFront and (1 - rearShare) or rearShare
		local staticLoad = mass * gravity * share
		local cornerMass = staticLoad / gravity
		local omega = 2 * math.pi * wheel.suspension.Frequency
		-- Tire: a radial spring that gives TireDeflection under the static
		-- load, lightly damped against the unsprung wheel.
		local tireRate = staticLoad / math.max(suspensionConfig.TireDeflection, EPSILON)
		-- Ride rate = suspension and tire springs in series; the suspension
		-- spring is chosen so the corner rides at the configured frequency.
		local rideRate = math.min(cornerMass * omega * omega, tireRate * 0.9)
		local verticalSpringRate = rideRate * tireRate / (tireRate - rideRate)
		-- Spring and damper act along the suspension axis. A contact force N
		-- on flat ground strokes it by N * cos(axis tilt), and each unit of
		-- stroke moves the chassis 1 / cos(axis tilt) vertically, so axial
		-- values carry cos^2 to keep the configured vertical frequency.
		local axisCosine = math.max(wheel.axis.Y, MIN_AXIS_NORMAL_DOT)
		local axisCosineSquared = axisCosine * axisCosine
		local rate = verticalSpringRate * axisCosineSquared
		local critical = 2 * cornerMass * omega * axisCosineSquared
		local staticForce = staticLoad * axisCosine
		local preload = staticForce - rate * wheel.sag

		wheel.tireRate = tireRate
		wheel.tireDamping = 2
			* suspensionConfig.TireDampingRatio
			* math.sqrt(tireRate * wheel.unsprungMass)

		-- A spring stiff enough for the ride frequency may need less force
		-- than the load to reach the sag (low gravity maps): it cannot pull,
		-- so the bike just rides a little higher.
		if preload < 0 and not wheel.preloadWarned and self.config.Diagnostics and self.config.Diagnostics.Enabled then
			wheel.preloadWarned = true
			warn(string.format(
				"BikeDynamics: in this gravity the %s spring settles %.3f studs short of its sag (no preload left); lower Suspension Frequency or SagRatio to change that.",
				wheel.isFront and "front" or "rear",
				-preload / math.max(rate, EPSILON)
			))
		end

		wheel.staticLoad = staticLoad
		wheel.staticForce = staticForce
		wheel.rate = rate
		wheel.dampingBump = critical * wheel.suspension.BumpDampingRatio
		wheel.dampingRebound = critical * wheel.suspension.ReboundDampingRatio
	end

	self.state.mass = mass
	self.state.frontalArea = self.frontalArea
end

-- Raycasts ignore the bike itself and the players' characters.
function BikeDynamics:_refreshFilter()
	local list = { self.bike }

	if self.players then
		for _, player in self.players:GetPlayers() do
			if player.Character then
				table.insert(list, player.Character)
			end
		end
	elseif self.seat and self.seat.Occupant and self.seat.Occupant.Parent then
		table.insert(list, self.seat.Occupant.Parent)
	end

	self.raycastParams.FilterDescendantsInstances = list
end

-- Clears per-ride state. Call when this machine takes over the bike.
function BikeDynamics:reset()
	local frame = self.frame
	local frameCFrame = frame.CFrame
	local look = frameCFrame.LookVector
	local forwardSpeed = frame.AssemblyLinearVelocity:Dot(look)

	for _, wheel in self.wheels do
		wheel.omega = forwardSpeed / wheel.radius
		wheel.grounded = false
		wheel.slipRatio = 0
		wheel.slipTan = 0
		wheel.slipForceX = 0
		wheel.slipForceY = 0
		wheel.absActive = false
		wheel.absPressure = 1
		wheel.strokeRate = 0
		wheel.probeNormal = nil

		-- Wheel let down onto whatever is under it, the tire just carrying
		-- its static deflection, as a bike set down on its wheels.
		local hit, axisWorld, _, normal = self:_probe(wheel, frameCFrame)

		if hit then
			local groundStroke = wheel.travel - (hit.Distance - wheel.castMargin)
			local axisDot = math.max(axisWorld:Dot(normal), MIN_CONTACT_NORMAL_DOT)

			wheel.stroke = clamp(groundStroke - self.config.Suspension.TireDeflection / axisDot, 0, wheel.travel)
		else
			wheel.stroke = 0
		end
	end

	-- A running engine is picked up at idle; a stopped one spins down.
	self.engine.omega = self.config.Drivetrain.IdleRPM * RAD_PER_RPM
	self.state.engineRPM = self.config.Drivetrain.IdleRPM

	-- Controllers read the state before the first step.
	self.state.forwardSpeed = forwardSpeed
	self.state.speed = math.abs(forwardSpeed)
	self.state.rearWheelSpeed = forwardSpeed

	self.steerFiltered = 0
	self.leanCommand = self:_measureLean(frameCFrame)
	self.roll = self.leanCommand
	self.rollRate = 0
	self.poseRatio = 1
	self.leanOffset = 0
	self.groundSteer = 0
	self.displayHandlebar = 0
	self.lastForwardSpeed = forwardSpeed
	self.forwardAcceleration = 0
	self.recovering = false
	self.recoveryTimer = 0
	self.lastCourseHeading = nil
	self.courseRate = 0
	self.alignMode = nil
end

-- The frame's roll angle (+ = leaning left).
function BikeDynamics:_measureLean(frameCFrame)
	local right = frameCFrame.RightVector
	local up = frameCFrame.UpVector

	return math.atan2(right.Y, up.Y)
end

-- The AlignOrientation's job: hold only the roll (RollOnly), pull the bike
-- upright (Upright) or lift it back up after a fall (Recovery).
function BikeDynamics:_setAlignMode(mode)
	if self.alignMode == mode then
		return
	end

	self.alignMode = mode

	local align = self.align

	if mode == "RollOnly" then
		align.Attachment0 = self.rollAttachment
		align.AlignType = Enum.AlignType.PrimaryAxisPerpendicular
		align.RigidityEnabled = true
	else
		local leanConfig = self.config.Lean
		local recoveryConfig = self.config.Recovery
		local recovering = mode == "Recovery"

		align.Attachment0 = self.uprightAttachment
		align.AlignType = Enum.AlignType.PrimaryAxisParallel
		align.RigidityEnabled = false
		align.MaxTorque = self.gravityRollMoment
			* (recovering and recoveryConfig.TorqueRatio or leanConfig.UprightTorqueRatio)
		align.Responsiveness = recovering and recoveryConfig.Responsiveness or leanConfig.UprightResponsiveness
		-- Upright fallback: fast enough to swing the full lean range at the
		-- rider's roll frequency.
		align.MaxAngularVelocity = recovering and recoveryConfig.MaxAngularVelocity
			or 2 * math.pi * leanConfig.RiderRollFrequency * math.rad(leanConfig.MaxLeanAngle)
	end
end

-- A bike lying past TriggerAngle for TriggerTime is lifted back up until
-- it is within ReleaseAngle.
function BikeDynamics:_updateRecovery(deltaTime, frameCFrame)
	local recoveryConfig = self.config.Recovery
	local upright = frameCFrame.UpVector.Y

	if upright < math.cos(math.rad(recoveryConfig.TriggerAngle)) then
		self.recoveryTimer += deltaTime
	else
		self.recoveryTimer = 0
	end

	if not self.recovering and self.recoveryTimer >= recoveryConfig.TriggerTime then
		self.recovering = true
	elseif self.recovering and upright >= math.cos(math.rad(recoveryConfig.ReleaseAngle)) then
		self.recovering = false
		self.leanCommand = self:_measureLean(frameCFrame)
		self.roll = self.leanCommand
		self.rollRate = 0
		self.poseRatio = 1
		self.leanOffset = 0
	end

	self.state.recovering = self.recovering
end

-- Sweeps the tire torus along the suspension axis. Returns the first hit.
function BikeDynamics:_probe(wheel, frameCFrame)
	local mount = wheel.mount
	local rotation = wheel.restRotation

	if wheel.isFront and math.abs(self.handlebar) > EPSILON then
		local steer = CFrame.fromAxisAngle(self.steerAxis, self.handlebar)
		mount = self.steerPivot + steer:VectorToWorldSpace(mount - self.steerPivot)
		rotation = steer * rotation
	end

	local axisWorld = frameCFrame:VectorToWorldSpace(wheel.axis)
	local wheelRotation = frameCFrame.Rotation * rotation
	local mountWorld = frameCFrame:PointToWorldSpace(mount)
	local origin = mountWorld + axisWorld * wheel.castMargin
	local direction = axisWorld * -(wheel.castMargin + wheel.travel + wheel.probeExtra)
	local best = nil
	-- The tire is round, so the arc of samples may turn about the axle:
	-- center it on last frame's contact. On steady ground a sample then sits
	-- right at the contact point; an arc fixed to the chassis missed it by
	-- the chassis pitch and tilted the normal by about as much, which pushed
	-- back on the bike under acceleration and forward under braking. The
	-- samples repeat every sampleSpacing, so the arc turns only as far as
	-- puts the nearest one on the contact: that works at any chassis pitch
	-- (a nose-high landing, a steep curb edge).
	local arcRotation = wheelRotation
	local reference = wheel.probeNormal

	if reference then
		local axle = wheelRotation.RightVector
		local inPlane = reference - axle * reference:Dot(axle)

		if inPlane.Magnitude > EPSILON then
			local down = -inPlane.Unit
			local chassisDown = -wheelRotation.UpVector
			local turn = math.atan2(chassisDown:Cross(down):Dot(axle), chassisDown:Dot(down))

			turn -= wheel.sampleSpacing * math.floor(turn / wheel.sampleSpacing + 0.5)

			arcRotation = CFrame.fromAxisAngle(axle, turn) * wheelRotation
		end
	end

	for _, offset in wheel.samples do
		local hit = self.world:Spherecast(
			origin + arcRotation:VectorToWorldSpace(offset),
			wheel.profileRadius,
			direction,
			self.raycastParams
		)

		if hit and hit.Normal:Dot(axisWorld) >= MIN_CONTACT_NORMAL_DOT then
			if best == nil or hit.Distance < best.Distance then
				best = hit
			end
		end
	end

	if best == nil then
		return nil, axisWorld, mountWorld, nil
	end

	-- Contact normal of the round tire: from the contact point toward the
	-- nearest point of the tire's core circle. The samples alone would tilt
	-- it toward whichever sample grazed an edge (up to half a sample
	-- spacing), which makes curb edges look much steeper than they are.
	local normal = best.Normal
	local center = origin - axisWorld * best.Distance
	local axle = wheelRotation.RightVector
	local toPoint = best.Position - center
	local inPlane = toPoint - axle * toPoint:Dot(axle)

	if inPlane.Magnitude > EPSILON then
		local towardCore = center + inPlane.Unit * wheel.coreRadius - best.Position

		if towardCore.Magnitude > EPSILON and towardCore.Unit:Dot(axisWorld) >= MIN_CONTACT_NORMAL_DOT then
			normal = towardCore.Unit
		end
	end

	return best, axisWorld, mountWorld, normal
end

--[=[
	Finds the ground under a wheel. groundStroke is the suspension stroke at
	which an undeformed tire would just touch it; the tire is pressed in by
	however far the wheel's actual stroke falls short of that.

	The contact is swept over the frame: the ground is probed again where
	the wheel will be at the end of the frame, and the contact normal leans
	only as far as the ground actually rises along that path. At walking
	pace this is the round tire's own geometry; at speed, where a curb is
	climbed within a single frame, it is the frame's average slope. Either
	way lifting the bike costs exactly the speed it should, whatever point
	of the frame the edge happened to be sampled at.
]=]
function BikeDynamics:_updateContact(wheel, frameCFrame, center, wheelVelocity, deltaTime)
	local hit, axisWorld, mountWorld, normal = self:_probe(wheel, frameCFrame)
	local telemetry = wheel.telemetry
	local contact = wheel.contact

	wheel.probeNormal = hit and normal or nil
	wheel.axisWorld = axisWorld
	wheel.mountWorld = mountWorld

	if hit then
		local point = hit.Position
		local groundStroke = wheel.travel - (hit.Distance - wheel.castMargin)
		local travelStep = wheelVelocity * deltaTime

		if travelStep.Magnitude > SWEEP_MIN_DISTANCE then
			local sweptHit, _, _, sweptNormal = self:_probe(wheel, frameCFrame + travelStep)

			if sweptHit then
				-- Were the ground the contact's own plane, moving the wheel by
				-- travelStep would change the cast distance by
				-- (travelStep . n) / (axis . n). Where the second cast finds the
				-- ground rising ahead faster than that, the normal leans back in
				-- the direction of travel to match. Where an edge that leans the
				-- contact back is cleared within the frame, the normal turns
				-- toward the one found at the end of the frame, as far as needed
				-- to match (along and across the travel alike, since both come
				-- from the same edge). Flat and evenly sloped ground stay
				-- exactly as they are.
				local castChange = sweptHit.Distance - hit.Distance
				local approach = travelStep:Dot(normal)
				local alongAxis = normal:Dot(axisWorld)
				local planeChange = approach / math.max(alongAxis, EPSILON)
				local swept = nil

				if castChange < planeChange - EPSILON then
					-- Rising ahead: lean back along the travel on the contact plane.
					local inPlane = travelStep - normal * approach
					local inPlaneLength = inPlane.Magnitude

					if inPlaneLength > EPSILON then
						local along = inPlane / inPlaneLength
						local denominator = inPlaneLength - castChange * axisWorld:Dot(along)

						if denominator > EPSILON then
							local lean = (castChange * alongAxis - approach) / denominator

							swept = (normal + along * math.min(lean, 0)).Unit
						end
					end
				elseif approach < 0 then
					-- Edge cleared within the frame: blend toward the end normal.
					local turn = sweptNormal - normal
					local denominator = travelStep:Dot(turn) - castChange * axisWorld:Dot(turn)

					if math.abs(denominator) > EPSILON then
						local blend = clamp((castChange * alongAxis - approach) / denominator, 0, 1)

						swept = (normal + turn * blend).Unit
					end
				end

				if swept and swept:Dot(axisWorld) >= MIN_CONTACT_NORMAL_DOT then
					normal = swept
				end
			end
		end

		contact.found = true
		contact.groundStroke = groundStroke
		contact.point = point
		contact.offset = point - center
		contact.normal = normal
		contact.axisWorld = axisWorld
		contact.groundVelocity = surfaceVelocity(hit.Instance, point)
		contact.friction = contactFriction(hit, self.config.Tire)

		wheel.grounded = groundStroke > wheel.stroke - TIRE_TOUCH_TOLERANCE

		return
	end

	contact.found = false
	wheel.grounded = false
end

-- The rider and the roll: a lean target from the steer input within the
-- lock, yaw-rate and grip limits; the handlebar steers to reach it
-- (countersteering), and the roll and the shown riding pose follow.
function BikeDynamics:_updateRider(deltaTime, controls, forwardSpeed, lean, pitchSine)
	local config = self.config
	local steeringConfig = config.Steering
	local leanConfig = config.Lean
	-- Only gravity's share across the roll axis tips the bike over: on a
	-- slope pitched by theta that is g cos(theta).
	local gravity = math.max(self.world.Gravity * math.sqrt(math.max(1 - pitchSine * pitchSine, 0)), EPSILON)
	local state = self.state
	local speed = math.abs(forwardSpeed)
	local parked = controls.parked == true
	local muAvailable = math.huge
	local grounded = false

	for _, wheel in self.wheels do
		if wheel.grounded then
			grounded = true
			muAvailable = math.min(muAvailable, wheel.contact.friction)
		end
	end

	if muAvailable == math.huge then
		muAvailable = state.muAvailable
	end

	-- Three physical limits on the turn the rider can ask for: steering lock
	-- (walking pace), rider yaw rate (normal riding), tire grip (lean cap).
	local leanCap = math.min(
		math.rad(leanConfig.MaxLeanAngle),
		math.atan(muAvailable * leanConfig.LeanGripUsage)
	)
	local wheelbase = self.wheelbase
	local maxSteer = math.rad(steeringConfig.MaxGroundSteerAngle)
	local maxSteerRate = math.rad(leanConfig.MaxSteerRate)
	local curvatureLock = math.tan(maxSteer) / wheelbase
	local speedSquared = speed * speed
	local curvatureCap = curvatureLock

	if speedSquared > EPSILON then
		curvatureCap = math.min(curvatureCap, gravity * math.tan(leanCap) / speedSquared)
	end

	if speed > EPSILON then
		curvatureCap = math.min(curvatureCap, math.rad(leanConfig.MaxYawRate) / speed)
	end

	local input = clamp(controls.steer or 0, -1, 1)

	if self.recovering or parked then
		input = 0
	end

	local response = steeringConfig.InputResponse

	if math.abs(input) < math.abs(self.steerFiltered) or input * self.steerFiltered < 0 then
		response = steeringConfig.InputReturnResponse
	end

	self.steerFiltered = approach(self.steerFiltered, input, response, deltaTime)

	local curvatureInput = self.steerFiltered * curvatureCap

	-- Bicycle model quantities.
	local mass = self.mass
	local height = self.centerHeight
	local toCenter = self.rearToCenter
	local gravityMoment = mass * gravity * height
	-- Roll inertia about the tire contact line (parallel axis theorem).
	local rollInertia = self.rollInertia + mass * height * height
	-- Wheel spin angular momentum, positive when rolling forward.
	local frontMomentum = self.front.spinInertia * self.front.omega
	local spinMomentum = frontMomentum + self.rear.spinInertia * self.rear.omega

	local rawAcceleration = (forwardSpeed - self.lastForwardSpeed) / deltaTime

	self.lastForwardSpeed = forwardSpeed
	self.forwardAcceleration = approach(
		self.forwardAcceleration,
		rawAcceleration,
		ACCELERATION_FILTER_RESPONSE,
		deltaTime
	)

	local acceleration = self.forwardAcceleration

	state.forwardAcceleration = acceleration

	-- Steady-turn lean for the requested path including the gyroscopic
	-- moment of the wheels: m g h sin(roll) = m a h cos(roll) + H r with
	-- a = v^2 k and r = v k.
	local leanTarget = math.atan(
		(speedSquared * curvatureInput + spinMomentum * speed * curvatureInput / (mass * height)) / gravity
	)

	leanTarget = clamp(leanTarget, -leanCap, leanCap)

	-- Steering authority: path acceleration the handlebar can create (lock
	-- plus countersteer rate) against the gravity moment at a reference lean.
	local steerAcceleration = (speedSquared * math.tan(maxSteer) + toCenter * speed * maxSteerRate) / wheelbase
	local authority = steerAcceleration / (gravity * math.sin(math.rad(leanConfig.BalanceReferenceLean)))
	local balanceWeight = smoothstep(leanConfig.AssistAuthorityStart, leanConfig.AssistAuthorityEnd, authority)

	if parked or self.recovering or forwardSpeed <= 0 or not grounded then
		balanceWeight = 0
	end

	-- Something external (a collision) moved the chassis: continue from there.
	if math.abs(lean - self.roll) > ROLL_RESYNC_ANGLE then
		self.roll = lean
		self.rollRate = 0
	end

	local roll = self.roll
	local rollRate = self.rollRate
	local steer = self.groundSteer
	-- How quickly the rider wants the lean to settle.
	local rollOmega = 2 * math.pi * leanConfig.RiderRollFrequency
	local rollDamping = 2 * leanConfig.RiderRollDampingRatio * rollOmega

	-- Walking pace: handlebar steering toward the requested curvature.
	local steerByHand = clamp(math.atan(wheelbase * curvatureInput), -maxSteer, maxSteer)
	local steerByBalance = steerByHand

	-- Riding: the rider picks the steering rate that produces the roll
	-- acceleration it wants (the roll equation below, solved for steer').
	-- Leaning into a turn therefore starts by steering away from it.
	if balanceWeight > 0 then
		local desiredRollAcceleration = rollOmega * rollOmega * (leanTarget - roll) - rollDamping * rollRate
		local cosRoll = math.cos(roll)
		local tanSteer = math.tan(steer)
		local yawRate = speed * tanSteer / wheelbase
		local numerator = gravityMoment * math.sin(roll)
			- mass * height * cosRoll * (speedSquared + toCenter * acceleration) * tanSteer / wheelbase
			- spinMomentum * yawRate
			- rollInertia * desiredRollAcceleration
		local denominator = mass * height * cosRoll * toCenter * speed * (1 + tanSteer * tanSteer) / wheelbase
			+ frontMomentum

		if denominator > EPSILON then
			local steerRate = clamp(numerator / denominator, -maxSteerRate, maxSteerRate)

			steerByBalance = clamp(steer + steerRate * deltaTime, -maxSteer, maxSteer)
		end
	end

	local newSteer = moveToward(
		steer,
		steerByHand + (steerByBalance - steerByHand) * balanceWeight,
		maxSteerRate * deltaTime
	)
	local steerRate = (newSteer - steer) / deltaTime
	local tanSteer = math.tan(newSteer)

	-- Path acceleration of the center of mass for the steering actually
	-- applied (bicycle model), capped by what the tires can grip.
	local lateralAcceleration = 0

	if grounded then
		lateralAcceleration = (
			(speedSquared + toCenter * acceleration) * tanSteer
			+ toCenter * speed * steerRate * (1 + tanSteer * tanSteer)
		) / wheelbase
		lateralAcceleration = clamp(lateralAcceleration, -muAvailable * gravity, muAvailable * gravity)
	end

	-- Gyroscopic moments of the spinning wheels from yawing and from
	-- steering the front wheel.
	local gyroscopicMoment = -spinMomentum * speed * tanSteer / wheelbase - frontMomentum * steerRate
	-- Feet and body support where steering alone cannot hold the bike up:
	-- the roll moment the steering leaves missing for the rider's wanted
	-- roll motion, up to what feet and body can push, fading out as the
	-- steering takes over. A support that only pulls toward the target
	-- (a spring) is weaker than gravity once it has faded below m g h, and
	-- the bike fell outward of slow turns.
	local supportLimit = (1 - balanceWeight) * leanConfig.AssistMomentRatio * gravityMoment
	local substep = deltaTime / ROLL_SUBSTEPS

	for _ = 1, ROLL_SUBSTEPS do
		local moment
		local inertia

		if grounded then
			-- I roll'' = m g h sin(roll) - m h a_lat cos(roll) + gyroscopic
			moment = gravityMoment * math.sin(roll)
				- mass * height * lateralAcceleration * math.cos(roll)
				+ gyroscopicMoment
			inertia = rollInertia
		else
			-- In the air gravity has no moment about the center of mass.
			moment = -self.rollInertia * leanConfig.AirborneRollDamping * rollRate
			inertia = self.rollInertia
		end

		local wanted = inertia * (rollOmega * rollOmega * (leanTarget - roll) - rollDamping * rollRate)

		moment += clamp(wanted - moment, -supportLimit, supportLimit)
		rollRate += moment / inertia * substep
		roll += rollRate * substep
	end

	-- Hard lean limit (falling over is not modeled yet).
	local hardLimit = math.rad(leanConfig.MaxLeanAngle)

	if math.abs(roll) > hardLimit then
		roll = math.sign(roll) * hardLimit

		if rollRate * roll > 0 then
			rollRate = 0
		end
	end

	self.roll = roll
	self.rollRate = rollRate

	-- Riding pose (see the module header): the chassis is held at the lean
	-- the same yaw rate needs at the shown speed. In the air the pose keeps
	-- what it had at take-off.
	if parked or self.recovering or leanConfig.ConstraintMode ~= "RollOnly" then
		self.poseRatio = 1
	elseif grounded then
		local poseTarget = forwardSpeed > 0 and self:_poseSpeedRatio(speed, gravity) or 1

		self.poseRatio = approach(self.poseRatio, poseTarget, POSE_RATIO_RESPONSE, deltaTime)
	end

	local poseRatio = self.poseRatio
	-- The extra lean drawn is at most what the tightest turn the rider can
	-- ask for at this speed shows, so a knock (a collision) is not drawn
	-- larger than it is; and the drawn lean stays inside the grip lean cap
	-- unless the bike itself is already past it.
	local fullTurnLean = clamp(
		math.atan((speedSquared * curvatureCap + spinMomentum * speed * curvatureCap / (mass * height)) / gravity),
		0,
		leanCap
	)
	local maxPoseLean = math.atan(math.tan(fullTurnLean) * poseRatio) - fullTurnLean
	local poseLean = clamp(math.atan(math.tan(roll) * poseRatio) - roll, -maxPoseLean, maxPoseLean)
	local shownLimit = math.max(math.abs(roll), math.min(leanCap, hardLimit))
	local shownLean = clamp(roll + poseLean, -shownLimit, shownLimit)

	self.leanCommand = shownLean
	self.leanOffset = shownLean - roll
	self.groundSteer = newSteer

	-- Handlebar angle that gives this ground angle on a leaned bike with this rake.
	local rakeCosine = math.max(math.cos(self.rake), 0.1)

	self.handlebar = math.atan(tanSteer * math.cos(lean) / rakeCosine)
	-- Shown handlebar: the ground angle this yaw rate needs at the shown
	-- speed, on the chassis at the shown lean.
	self.displayHandlebar = math.atan(tanSteer / poseRatio * math.cos(shownLean) / rakeCosine)

	state.muAvailable = muAvailable
	state.leanCap = leanCap
	state.leanTarget = leanTarget
	state.leanCommand = shownLean
	state.balanceLean = roll
	state.poseRatio = poseRatio
	state.rollRate = rollRate
	-- Front wheel turned against the requested turn: countersteering.
	state.countersteer = math.abs(newSteer) > math.rad(0.2) and newSteer * curvatureInput < 0
	state.leanSteerBlend = balanceWeight
	state.groundSteer = newSteer
	state.handlebar = self.handlebar
	state.displayHandlebar = self.displayHandlebar
	state.targetRadius = math.abs(curvatureInput) > EPSILON and 1 / math.abs(curvatureInput) or 0
	state.targetYawRate = speed * curvatureInput
end

-- Riding pose: ratio q of the speed whose pose is shown to the real speed.
-- In a steady turn tan(steer) / tan(lean) = L g / v^2. Below
-- v_ref = sqrt(L g / SteerLeanRatio) the handlebar outweighs the lean, so
-- the pose of the same yaw rate at v_ref is shown: q = v_ref / v, at most
-- MaxSpeedRatio. Toward walking pace the real handlebar comes back, as a
-- rider's does when the feet go down.
function BikeDynamics:_poseSpeedRatio(speed, gravity)
	local poseConfig = self.config.Pose

	if poseConfig == nil or speed <= EPSILON then
		return 1
	end

	local maxRatio = math.max(poseConfig.MaxSpeedRatio, 1)
	local referenceSpeed = math.sqrt(self.wheelbase * gravity / math.max(poseConfig.SteerLeanRatio, EPSILON))
	local ratio = clamp(referenceSpeed / speed, 1, maxRatio)

	return 1 + (ratio - 1) * smoothstep(0, referenceSpeed / maxRatio, speed)
end

-- Points the AlignOrientation at the lean command (upright while recovering).
function BikeDynamics:_updateAlignTarget(frameCFrame)
	local mode = self.config.Lean.ConstraintMode

	if self.recovering then
		self:_setAlignMode("Recovery")
		self.align.PrimaryAxis = WORLD_UP

		return
	end

	self:_setAlignMode(mode == "Upright" and "Upright" or "RollOnly")

	-- Target up: lean command rotated about the current forward axis, with
	-- the current pitch kept so the suspension owns pitch.
	local forward = frameCFrame.LookVector
	local referenceUp = safeUnit(WORLD_UP - forward * forward:Dot(WORLD_UP), frameCFrame.UpVector)
	local referenceRight = forward:Cross(referenceUp)

	self.align.PrimaryAxis = referenceUp * math.cos(self.leanCommand)
		- referenceRight * math.sin(self.leanCommand)
end

-- Course rate, body slip angle and path radius from the velocity.
function BikeDynamics:_updateTrajectory(deltaTime, velocity, frameCFrame)
	local state = self.state
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = horizontal.Magnitude

	if speed < COURSE_MINIMUM_SPEED then
		self.lastCourseHeading = nil
		self.courseRate = 0
		state.slipAngle = 0
		state.courseRate = 0
		state.pathRadius = 0

		return
	end

	-- Same sign convention as yaw: positive turns -Z toward -X (left).
	local look = frameCFrame.LookVector
	local courseHeading = math.atan2(-horizontal.X, -horizontal.Z)
	local bodyHeading = math.atan2(-look.X, -look.Z)

	if self.lastCourseHeading ~= nil then
		local rawRate = wrapAngle(courseHeading - self.lastCourseHeading) / deltaTime
		self.courseRate = approach(self.courseRate, rawRate, COURSE_RATE_RESPONSE, deltaTime)
	end

	self.lastCourseHeading = courseHeading

	state.slipAngle = wrapAngle(courseHeading - bodyHeading)
	state.courseRate = self.courseRate
	state.pathRadius = math.abs(self.courseRate) > math.rad(1) and speed / math.abs(self.courseRate) or 0
end

--[=[
	Advances the bike by one physics frame. Call from RunService.PreSimulation
	on the machine that owns the assembly.

	controls = {
		steer: number, -- -1 (right) .. 1 (left)
		engine: { -- the rider's engine and gearbox (RiderControls fills this)
			running: boolean,
			throttle: number, -- 0..1
			gearRatio: number, -- gear ratio x final drive, 0 = neutral
			clutch: number, -- 0..1, scales the centrifugal clutch (open while shifting)
		}?,
		-- Without engine: an external motor on the rear wheel (offline bench).
		driveTorque: number?, -- rear motor torque limit
		driveTargetOmega: number?, -- rear wheel speed the motor drives toward (rad/s, forward +)
		frontBrakeTorque: number,
		rearBrakeTorque: number,
		abs: boolean?, -- anti-lock brakes
		parked: boolean?, -- no rider: the stand holds the bike, no steering balance
	}
]=]
function BikeDynamics:step(deltaTime, controls)
	if deltaTime <= 0 then
		return self.state
	end

	deltaTime = math.min(deltaTime, MAX_STEP)
	controls = controls or {}

	local config = self.config
	local suspensionConfig = config.Suspension
	local tireConfig = config.Tire
	local frame = self.frame
	local state = self.state

	self.massTimer += deltaTime

	local occupied = self.seat ~= nil and self.seat.Occupant ~= nil

	if self.massTimer >= MASS_REFRESH_INTERVAL or occupied ~= self.lastOccupant then
		self.massTimer = 0
		self.lastOccupant = occupied
		self:_refreshMassProperties()
		self:_refreshFilter()
	end

	local gravity = self.world.Gravity
	local mass = self.mass
	local inverseMass = 1 / mass
	local center = frame.AssemblyCenterOfMass
	local velocity = frame.AssemblyLinearVelocity
	local angularVelocity = frame.AssemblyAngularVelocity
	-- The chassis is drawn with the riding pose's cosmetic lean on top of its
	-- physical roll, turned about the center of mass. Contacts, tires,
	-- forces and the roll state all use the physical pose (frameCFrame); the
	-- forces are applied to the drawn chassis at the same world points, so
	-- they move it exactly as they would move the physical one.
	local bodyCFrame = frame.CFrame
	local look = bodyCFrame.LookVector
	local frameCFrame = bodyCFrame

	if self.leanOffset ~= 0 then
		-- Turning about the forward axis by +a lowers the lean by a.
		frameCFrame = CFrame.new(center) * CFrame.fromAxisAngle(look, self.leanOffset) * CFrame.new(-center) * bodyCFrame
	end

	local flatForward = safeUnit(Vector3.new(look.X, 0, look.Z), self.lastFlatForward)
	local forwardSpeed = velocity:Dot(flatForward)
	local speed = math.abs(forwardSpeed)
	local lean = self:_measureLean(frameCFrame)
	-- Lean of the drawn chassis at the start of the frame.
	local bodyLean = lean + self.leanOffset

	self.lastFlatForward = flatForward

	self:_updateRecovery(deltaTime, bodyCFrame)

	for _, wheel in self.wheels do
		local wheelPoint = frameCFrame:PointToWorldSpace(wheel.restCFrame.Position)

		self:_updateContact(
			wheel,
			frameCFrame,
			center,
			velocity + angularVelocity:Cross(wheelPoint - center),
			deltaTime
		)
	end

	-- Speed along the path: while a tire touches the ground the chassis
	-- forward follows the slope, so a climb or a descent reads its whole
	-- speed (as the wheel does), not only the horizontal part. In the air,
	-- the horizontal speed.
	if self.front.grounded or self.rear.grounded then
		forwardSpeed = velocity:Dot(look)
		speed = math.abs(forwardSpeed)
	end

	self:_updateRider(deltaTime, controls, forwardSpeed, lean, look.Y)
	self:_updateAlignTarget(frameCFrame)

	-- Inverse inertia in world space with rotation about the roll axis
	-- removed: the rigid roll constraint absorbs any roll torque.
	local inverseInertiaLocal = self.inverseInertiaLocal
	local rollAxis = look

	-- I^-1 * torque, in world space.
	local function inverseInertiaWorld(torque)
		return frameCFrame:VectorToWorldSpace(
			mat3MulVector(inverseInertiaLocal, frameCFrame:VectorToObjectSpace(torque))
		)
	end

	local rollResponse = inverseInertiaWorld(rollAxis)
	local rollResponseDot = rollAxis:Dot(rollResponse)
	local rollHeld = not self.recovering and self.alignMode == "RollOnly" and rollResponseDot > EPSILON

	-- Angular response to a torque, without the roll the align constraint holds.
	local function angularResponse(torque)
		local response = inverseInertiaWorld(torque)

		if rollHeld then
			response -= rollResponse * (rollResponse:Dot(torque) / rollResponseDot)
		end

		return response
	end

	-- 1 / effective mass of the chassis at offset along a unit direction.
	local function inverseEffectiveMass(offset, direction)
		local arm = offset:Cross(direction)

		return inverseMass + arm:Dot(angularResponse(arm))
	end

	-- Air drag through the center of mass: 1/2 rho Cd A |v_air| v_air.
	local airVelocity = velocity - self.wind
	local drag = airVelocity
		* (-0.5 * self.airDensity * config.Aero.DragCoefficient * self.frontalArea * airVelocity.Magnitude)

	-- Predicted velocities at the end of the frame under gravity and drag;
	-- the suspension and tires are solved below as velocity constraints, so
	-- they answer both this frame.
	local linear = velocity + (Vector3.new(0, -gravity, 0) + drag * inverseMass) * deltaTime
	local angular = angularVelocity
	local slipFloor = tireConfig.SlipReferenceMinimumSpeed
	local lateralCurve = self.lateralCurve
	local longitudinalCurve = self.longitudinalCurve
	local rollingResistance = 0
	local brakeConfig = config.Brakes
	local absEnabled = controls.abs == true and not controls.parked
	local absMinimumSpeed = brakeConfig.ABSMinimumSpeed or 0
	-- Share of the peak force the tire gives at the ABS target slip.
	local absForceShare = clamp(tireCurveValue(longitudinalCurve, brakeConfig.ABSSlipRatio or 0.85), 0, 1)

	for _, wheel in self.wheels do
		wheel.driveTorque = 0
		wheel.driveTarget = 0
		wheel.brakeTorque = 0
		wheel.rollingTorque = 0
		wheel.driveLambda = 0
		wheel.brakeLambda = 0
		wheel.rollingLambda = 0
		wheel.absLimit = math.huge
	end

	self.front.brakeTorque = math.max(controls.frontBrakeTorque or 0, 0)
	self.rear.brakeTorque = math.max(controls.rearBrakeTorque or 0, 0)

	-- Engine: integrate its own torque over the frame, then let the solve
	-- below share momentum with the rear wheel through the clutch. The
	-- rev limiter (fuel cut) can only take away the fuel's torque; the idle
	-- controller can add up to the full-load torque at idle.
	local engineControl = controls.engine
	local engine = self.engine
	local engineSpinStart = engine.omega
	local gearRatio = 0
	local clutchLimit = 0
	local limiterLimit = 0
	local idleLimit = 0
	local engineTorque = 0

	if engineControl then
		local drivetrain = config.Drivetrain
		local running = engineControl.running == true
		local throttle = running and clamp(engineControl.throttle or 0, 0, 1) or 0
		-- Torque and clutch capacity both at the frame's starting speed.
		local rpm = engine.omega / RAD_PER_RPM
		local fuelTorque = throttle * Powertrain.engineTorque(drivetrain, rpm) * drivetrain.Efficiency

		engineTorque = fuelTorque - (1 - throttle) * Powertrain.engineBrakeTorque(drivetrain, rpm)
		engine.omega = math.max(engine.omega + engineTorque * deltaTime / engine.inertia, 0)
		engine.limitOmega = drivetrain.RevLimitRPM * RAD_PER_RPM
		engine.idleOmega = drivetrain.IdleRPM * RAD_PER_RPM
		limiterLimit = fuelTorque * deltaTime

		if running then
			idleLimit = Powertrain.engineTorque(drivetrain, drivetrain.IdleRPM) * deltaTime
		end

		-- Negative in reverse: the crank still turns forward, the wheel back.
		gearRatio = engineControl.gearRatio or 0

		if gearRatio ~= 0 then
			clutchLimit = Powertrain.clutchCapacity(drivetrain, rpm)
				* clamp(engineControl.clutch or 1, 0, 1)
				* deltaTime
		end
	else
		self.rear.driveTorque = math.max(controls.driveTorque or 0, 0)
		self.rear.driveTarget = controls.driveTargetOmega or 0
	end

	engine.limitLambda = 0
	engine.idleLambda = 0
	engine.clutchLambda = 0

	for _, wheel in self.wheels do
		local telemetry = wheel.telemetry
		local contact = wheel.contact

		contact.active = false
		contact.held = false
		telemetry.grounded = wheel.grounded
		telemetry.saturated = false
		telemetry.hardStop = false

		-- Suspension: a spring-damper along the axis between the chassis and
		-- the unsprung wheel, whether or not the tire touches anything.
		local axis = wheel.axisWorld
		local stroke = wheel.stroke
		local axle = wheel.mountWorld - axis * (wheel.travel - stroke)
		local axleOffset = axle - center
		-- Preload around the static ride height, progressive bump rubber over
		-- the last part of the stroke.
		local springForce = wheel.staticForce + wheel.rate * (stroke - wheel.sag)
		local springRate = wheel.rate

		if stroke > wheel.bumpStopStart then
			local range = math.max(wheel.travel - wheel.bumpStopStart, EPSILON)
			local depth = stroke - wheel.bumpStopStart
			local gainRate = suspensionConfig.BumpStopGain * wheel.rate

			springForce += gainRate * depth * depth / (2 * range)
			springRate += gainRate * depth / range
		end

		-- Damper: rebound stays linear; compression turns digressive above the
		-- knee speed, where a fork's high-speed valve opens.
		local damping = wheel.dampingRebound

		if wheel.strokeRate > 0 then
			local knee = suspensionConfig.HighSpeedDampingStart

			damping = wheel.dampingBump

			if wheel.strokeRate > knee then
				damping *= (knee + suspensionConfig.HighSpeedDampingRatio * (wheel.strokeRate - knee))
					/ wheel.strokeRate
			end
		end

		-- Implicit spring-damper as a soft constraint (backward Euler):
		-- softness = 1 / ((k dt + c) dt), target rate = F / (k dt + c).
		local suspensionStiffness = springRate * deltaTime + damping

		wheel.axle = axle
		wheel.axleOffset = axleOffset
		wheel.spinStart = wheel.omega
		-- The wheel's weight is already part of the chassis assembly; here it
		-- only adds its inertia along the axis.
		wheel.axialVelocity = (velocity + angularVelocity:Cross(axleOffset)):Dot(axis) + wheel.strokeRate
		wheel.springForce = springForce
		wheel.suspensionSoft = 1 / math.max(suspensionStiffness * deltaTime, EPSILON)
		wheel.suspensionBias = springForce / math.max(suspensionStiffness, EPSILON)
		wheel.suspensionInverseMass = 1 / wheel.unsprungMass + inverseEffectiveMass(axleOffset, axis)
		wheel.lambdaSuspension = 0
		wheel.lambdaTop = 0
		wheel.lambdaBottom = 0

		if contact.found then
			local normal = contact.normal
			local offset = contact.offset
			-- Tire: a radial spring pressed in along the contact normal by how
			-- far the wheel sits below the ground stroke. Its share along the
			-- suspension axis moves the wheel; the rest reaches the chassis
			-- through the fork, which also carries the contact force's moment
			-- (the wheel turns with the chassis in every way but spin). So the
			-- chassis feels the whole contact force at the contact point, less
			-- the axial share at the axle that the wheel's own spring answers.
			local axisDot = math.max(axis:Dot(normal), MIN_CONTACT_NORMAL_DOT)
			local normalPerp = normal - axis * axisDot
			local deflection = (contact.groundStroke - stroke) * axisDot
			local tireForce = wheel.tireRate * deflection
			-- No damping before the tire has touched (a gap is not a damper).
			local tireStiffness = wheel.tireRate * deltaTime + (deflection > 0 and wheel.tireDamping or 0)
			local relative = velocity + angularVelocity:Cross(offset) - contact.groundVelocity
			-- Load for the tire model: what the tire carried over the last
			-- frame (the solved contact force), or its spring now if more.
			local normalForce = math.max(wheel.lastLoad, tireForce, 0)

			contact.active = true
			contact.axisDot = axisDot
			contact.normalPerp = normalPerp
			contact.springForce = normalForce
			contact.normalSoft = 1 / math.max(tireStiffness * deltaTime, EPSILON)
			contact.normalBias = tireForce / math.max(tireStiffness, EPSILON)
			-- Angular arm of the chassis part of the contact impulse.
			contact.normalArm = offset:Cross(normal) - axleOffset:Cross(axis) * axisDot
			contact.normalInverseMass = axisDot * axisDot / wheel.unsprungMass
				+ inverseMass * normalPerp:Dot(normalPerp)
				+ contact.normalArm:Dot(angularResponse(contact.normalArm))
			contact.lambdaNormal = 0
			contact.px = 0
			contact.py = 0
			contact.saturated = false

			-- Tire frame on the contact plane. The front heading is turned by
			-- the ground steer angle about the contact normal.
			local heading = look

			if wheel.isFront then
				heading = rotateAroundAxis(look, normal, self.groundSteer)
			end

			local tangent = safeUnit(heading - normal * heading:Dot(normal), nil)

			contact.hasTire = tangent ~= nil

			-- Rolling resistance: a load-proportional drag torque on the wheel,
			-- solved like a brake so it never pushes the bike backward.
			wheel.rollingTorque = tireConfig.RollingResistance * normalForce * wheel.radius
			rollingResistance += tireConfig.RollingResistance * normalForce

			if contact.hasTire then
				local lateral = normal:Cross(tangent)
				local camber = math.asin(clamp(frameCFrame.RightVector:Dot(normal), -1, 1))
				local referenceSpeed = math.max(
					math.abs(relative:Dot(tangent)),
					math.abs(wheel.omega * wheel.radius),
					slipFloor
				)
				-- The spring force this frame is the tire load estimate.
				local load = math.max(normalForce, EPSILON)
				local loadImpulse = load * deltaTime

				-- Load sensitivity: friction and stiffness per unit load fall as
				-- the tire is loaded beyond its static load.
				local extraLoad = load / math.max(wheel.staticLoad, EPSILON) - 1
				local friction = contact.friction
					* clamp(1 - tireConfig.FrictionLoadSensitivity * extraLoad, 0.5, 1.5)
				local stiffnessScale = clamp(1 - tireConfig.StiffnessLoadSensitivity * extraLoad, 0.5, 1.5)
				local longitudinalStiffness = tireConfig.LongitudinalStiffness * stiffnessScale
				local corneringStiffness = tireConfig.CorneringStiffness * stiffnessScale

				-- Magic Formula peak slips: initial slope k = mu * C * B / slip_peak.
				local peakSlipRatio = friction * longitudinalCurve.slope / longitudinalStiffness
				local peakSlipTan = friction * lateralCurve.slope / corneringStiffness

				-- Combined slip (similarity method) from where the tire was last
				-- frame. The force curve enters the implicit solve as its secant
				-- stiffness there, and grip beyond the peak falls off.
				local slipX = wheel.slipRatio / peakSlipRatio
				local slipY = wheel.slipTan / peakSlipTan
				local combinedSlip = math.sqrt(slipX * slipX + slipY * slipY)
				local secantX, secantY, gripFactor = 1, 1, 1

				if combinedSlip > 1e-4 then
					local weightX = slipX * slipX / (combinedSlip * combinedSlip)
					local value = weightX * tireCurveValue(longitudinalCurve, combinedSlip)
						+ (1 - weightX) * tireCurveValue(lateralCurve, combinedSlip)

					secantX = math.max(value / (longitudinalCurve.slope * combinedSlip), 0.02)
					secantY = math.max(value / (lateralCurve.slope * combinedSlip), 0.02)

					if combinedSlip > 1 then
						gripFactor = math.max(value, 0.05)
					end
				end

				local stiffnessX = longitudinalStiffness * secantX * load
				local stiffnessY = corneringStiffness * secantY * load

				contact.tangent = tangent
				contact.lateral = lateral
				contact.camber = camber
				contact.frictionLimit = friction * gripFactor
				-- Implicit tire: slip damper c = stiffness / V, softness 1/(c dt).
				contact.softX = referenceSpeed / (stiffnessX * deltaTime)
				contact.softY = referenceSpeed / (stiffnessY * deltaTime)
				contact.biasX = 0
				contact.biasY = 0

				-- Relaxation length: the carcass is a spring (stiffness / sigma)
				-- in series with the slip damper, so force builds up over the
				-- distance sigma instead of instantly. Off near standstill,
				-- where it would leave an undamped spring.
				local relaxationFade = smoothstep(slipFloor, 4 * slipFloor, referenceSpeed)
				local sigmaY = wheel.relaxationLength * relaxationFade
				local sigmaX = wheel.longitudinalRelaxationLength * relaxationFade

				if sigmaY > EPSILON then
					local carcass = stiffnessY / sigmaY

					contact.softY += 1 / (carcass * deltaTime * deltaTime)
					contact.biasY = wheel.slipForceY / (carcass * deltaTime)
				end

				if sigmaX > EPSILON then
					local carcass = stiffnessX / sigmaX

					contact.softX += 1 / (carcass * deltaTime * deltaTime)
					contact.biasX = wheel.slipForceX / (carcass * deltaTime)
				end

				contact.camberImpulse = tireConfig.CamberStiffness
					* loadImpulse
					* math.tan(clamp(camber, -MAX_CAMBER, MAX_CAMBER))
				contact.inverseMassX = inverseEffectiveMass(offset, tangent)
					+ wheel.radius * wheel.radius / wheel.spinInertia
				contact.inverseMassY = inverseEffectiveMass(offset, lateral)
				contact.referenceSpeed = referenceSpeed

				-- A stopped wheel the brake holds (nothing driving it) turns with
				-- the chassis as one body: the tire pushes the chassis directly
				-- and the brake carries the torque, up to its capacity. Solved
				-- through the light wheel instead, each push would mostly spin
				-- the wheel, and a braked bike would creep down a slope.
				local driven = wheel == self.rear and (wheel.driveTorque > 0 or clutchLimit > 0)
				local patchVelocity = relative - normal * relative:Dot(normal)
				local patchSpeed = math.max(patchVelocity.Magnitude, math.abs(wheel.omega * wheel.radius))

				contact.held = wheel.brakeTorque > 0 and not driven and patchSpeed < STICK_SPEED_SHARE * slipFloor
				contact.inverseMassHeldX = inverseEffectiveMass(offset, tangent)

				if contact.held then
					wheel.omega = 0
				end

				-- ABS: the brake may use the longitudinal grip the tire has at the
				-- target slip (a share of the peak, read off the force curve),
				-- within what the friction circle leaves beside the lateral
				-- force. Its valve drops the pressure while the tire is past its
				-- peak (so the tire spins the wheel back up) and builds it back
				-- once the tire grips again.
				local axleOffset = offset + normal * wheel.radius
				local axleSpeed = (velocity + angularVelocity:Cross(axleOffset) - contact.groundVelocity):Dot(tangent)

				contact.absActive = absEnabled and math.abs(axleSpeed) > absMinimumSpeed
				contact.absFriction = friction * absForceShare

				if contact.absActive and wheel.brakeTorque > 0 then
					if combinedSlip > 1 and wheel.slipRatio * axleSpeed < 0 then
						wheel.absPressure = math.max(
							wheel.absPressure - ABS_DUMP_RATE * (combinedSlip - 1) * deltaTime,
							0
						)
					else
						wheel.absPressure = math.min(wheel.absPressure + ABS_BUILD_RATE * deltaTime, 1)
					end
				else
					wheel.absPressure = 1
				end

				contact.absScale = wheel.absPressure
				-- The brake also has to slow the wheel's own spin as fast as the
				-- bike is slowing down.
				contact.absSpinImpulse = wheel.spinInertia
					* math.max(-self.forwardAcceleration * math.sign(axleSpeed), 0)
					* deltaTime
					/ wheel.radius

				telemetry.friction = friction
				telemetry.peakSlipRatio = peakSlipRatio
				telemetry.normalizedSlip = combinedSlip
			end
		end
	end

	-- The rigid roll constraint turns the chassis to the new lean command
	-- this frame; tires see the physical share of that roll motion at the
	-- contact patch (the riding pose's share is only drawn).
	local heldBodyCFrame = bodyCFrame

	if rollHeld then
		local rollRate = -(self.roll - lean) / deltaTime

		angular = angular - rollAxis * angular:Dot(rollAxis) + rollAxis * rollRate
		heldBodyCFrame = CFrame.new(center)
			* CFrame.fromAxisAngle(rollAxis, bodyLean - self.leanCommand)
			* CFrame.new(-center)
			* bodyCFrame
	end

	local inverseStepTime = 1 / deltaTime
	local engineInertia = engine.inertia
	local rearWheel = self.rear
	local clutchInverseMass = 1 / engineInertia + gearRatio * gearRatio / rearWheel.spinInertia

	-- Projected Gauss-Seidel over engine, clutch, wheel spin, suspension and
	-- tire rows.
	local iterations = SOLVER_ITERATIONS

	for _, wheel in self.wheels do
		if wheel.contact.active and wheel.contact.held then
			iterations = HELD_SOLVER_ITERATIONS
		end
	end

	for _ = 1, iterations do
		if limiterLimit > 0 then
			-- Rev limiter: crank speed at most the limit, by cutting fuel.
			local accumulated = clamp(
				engine.limitLambda + (engine.limitOmega - engine.omega) * engineInertia,
				-limiterLimit,
				0
			)

			engine.omega += (accumulated - engine.limitLambda) / engineInertia
			engine.limitLambda = accumulated
		end

		if idleLimit > 0 then
			-- Idle control: crank speed at least idle.
			local accumulated = clamp(
				engine.idleLambda + (engine.idleOmega - engine.omega) * engineInertia,
				0,
				idleLimit
			)

			engine.omega += (accumulated - engine.idleLambda) / engineInertia
			engine.idleLambda = accumulated
		end

		if clutchLimit > 0 then
			-- Clutch: dry friction between the crank and the gearbox input
			-- (rear wheel speed times the overall ratio). It locks while the
			-- torque it has to carry stays within its capacity, else slips.
			-- Slipper: when the gearbox would drive the engine past the rev
			-- limit (a downshift at speed), it slips and holds the engine at
			-- the limit instead, braking the wheel with the engine's drag
			-- there, so the rear wheel never locks and the engine never
			-- over-revs.
			-- As a slipper its target is the limit, which the wheel's speed
			-- does not move: only the crank's inertia answers the slip.
			local slipper = gearRatio * rearWheel.omega > engine.limitOmega
			local slip = engine.omega - (slipper and engine.limitOmega or gearRatio * rearWheel.omega)
			local accumulated = clamp(
				engine.clutchLambda + (slipper and slip * engineInertia or slip / clutchInverseMass),
				-clutchLimit,
				clutchLimit
			)
			local delta = accumulated - engine.clutchLambda

			engine.omega -= delta / engineInertia
			rearWheel.omega += gearRatio * delta / rearWheel.spinInertia
			engine.clutchLambda = accumulated
		end

		for _, wheel in self.wheels do
			local spinInertia = wheel.spinInertia
			local contact = wheel.contact
			-- The brake holds this wheel still: the tire row carries its torque.
			local held = contact.active and contact.held

			if wheel.driveTorque > 0 then
				local limit = wheel.driveTorque * deltaTime
				local accumulated = clamp(
					wheel.driveLambda + (wheel.driveTarget - wheel.omega) * spinInertia,
					-limit,
					limit
				)

				wheel.omega += (accumulated - wheel.driveLambda) / spinInertia
				wheel.driveLambda = accumulated
			end

			if wheel.rollingTorque > 0 and not held then
				local limit = wheel.rollingTorque * deltaTime
				local accumulated = clamp(wheel.rollingLambda - wheel.omega * spinInertia, -limit, limit)

				wheel.omega += (accumulated - wheel.rollingLambda) / spinInertia
				wheel.rollingLambda = accumulated
			end

			if wheel.brakeTorque > 0 and not held then
				local limit = wheel.brakeTorque * deltaTime

				-- ABS: no more brake torque than the tire can turn into grip
				-- at the target slip (plus what slows the wheel's own spin).
				wheel.absLimit = math.huge

				if contact.active and contact.hasTire and contact.absActive then
					local available = contact.absFriction * contact.lambdaNormal
					local longitudinal = math.sqrt(math.max(
						available * available - contact.py * contact.py,
						(ABS_MINIMUM_FORCE_SHARE * available) ^ 2
					))
					local absLimit = (longitudinal * wheel.radius + contact.absSpinImpulse) * contact.absScale

					if absLimit < limit then
						limit = absLimit
						wheel.absLimit = absLimit
					end
				end

				local accumulated = clamp(wheel.brakeLambda - wheel.omega * spinInertia, -limit, limit)

				wheel.omega += (accumulated - wheel.brakeLambda) / spinInertia
				wheel.brakeLambda = accumulated
			end

			-- Suspension between the chassis and the unsprung wheel: spring and
			-- damper, then the top-out and bottom-out ends of the stroke. A
			-- positive impulse pushes the wheel out along -axis and the chassis
			-- up along the axis (at the axle); the stroke rate is the wheel's
			-- axial speed relative to the chassis.
			do
				local axis = wheel.axisWorld
				local axleOffset = wheel.axleOffset
				local rowInverseMass = wheel.suspensionInverseMass
				local rate = wheel.axialVelocity - (linear + angular:Cross(axleOffset)):Dot(axis)
				local springDelta = (rate - wheel.suspensionSoft * wheel.lambdaSuspension + wheel.suspensionBias)
					/ (rowInverseMass + wheel.suspensionSoft)

				rate -= springDelta * rowInverseMass

				-- Top-out: the stroke cannot go below fully extended.
				local topped = math.max(
					wheel.lambdaTop + (-wheel.stroke * inverseStepTime - rate) / rowInverseMass,
					0
				)
				local topDelta = topped - wheel.lambdaTop

				rate += topDelta * rowInverseMass

				-- Bottom-out: the fork's hydraulic stop ends the stroke without a
				-- rebound (an inelastic stop).
				local bottomed = math.max(
					wheel.lambdaBottom + (rate - (wheel.travel - wheel.stroke) * inverseStepTime) / rowInverseMass,
					0
				)
				local net = springDelta - topDelta + (bottomed - wheel.lambdaBottom)

				wheel.lambdaSuspension += springDelta
				wheel.lambdaTop = topped
				wheel.lambdaBottom = bottomed
				wheel.axialVelocity -= net / wheel.unsprungMass
				linear += axis * (net * inverseMass)
				angular += angularResponse(axleOffset:Cross(axis * net))
			end

			if contact.active then
				local offset = contact.offset
				local normal = contact.normal

				-- Tire radial spring, push only: its share along the axis moves
				-- the wheel, the chassis takes the rest (see the setup above).
				do
					local normalPerp = contact.normalPerp
					local normalArm = contact.normalArm
					local normalSpeed = linear:Dot(normalPerp)
						+ angular:Dot(normalArm)
						+ wheel.axialVelocity * contact.axisDot
						- contact.groundVelocity:Dot(normal)
					local residual = normalSpeed + contact.normalSoft * contact.lambdaNormal - contact.normalBias
					local accumulated = math.max(
						contact.lambdaNormal - residual / (contact.normalInverseMass + contact.normalSoft),
						0
					)
					local delta = accumulated - contact.lambdaNormal

					contact.lambdaNormal = accumulated
					wheel.axialVelocity += delta * contact.axisDot / wheel.unsprungMass
					linear += normalPerp * (delta * inverseMass)
					angular += angularResponse(normalArm * delta)
				end

				if contact.hasTire then
					local tangent = contact.tangent
					local lateral = contact.lateral

					-- Longitudinal: slip = wheel surface speed - ground speed.
					local relative = linear + angular:Cross(offset) - contact.groundVelocity
					local slip = wheel.omega * wheel.radius - relative:Dot(tangent)

					if held then
						-- The wheel stays still; the brake answers the tire's
						-- torque on it up to its capacity (beyond that it slips,
						-- and next frame the wheel turns).
						local deltaX = (slip - contact.softX * contact.px + contact.biasX)
							/ (contact.inverseMassHeldX + contact.softX)
						local limit = wheel.brakeTorque * deltaTime
						local hold = clamp(wheel.brakeLambda + deltaX * wheel.radius, -limit, limit)

						deltaX = (hold - wheel.brakeLambda) / wheel.radius
						wheel.brakeLambda = hold
						contact.px += deltaX
						linear += tangent * (deltaX * inverseMass)
						angular += angularResponse(offset:Cross(tangent * deltaX))
					else
						local deltaX = (slip - contact.softX * contact.px + contact.biasX)
							/ (contact.inverseMassX + contact.softX)

						contact.px += deltaX
						linear += tangent * (deltaX * inverseMass)
						angular += angularResponse(offset:Cross(tangent * deltaX))
						wheel.omega -= deltaX * wheel.radius / spinInertia
					end

					-- Lateral: slip-angle force plus camber thrust.
					relative = linear + angular:Cross(offset) - contact.groundVelocity

					local lateralSpeed = relative:Dot(lateral)
					local deltaY = -(lateralSpeed + contact.softY * (contact.py - contact.camberImpulse) - contact.biasY)
						/ (contact.inverseMassY + contact.softY)

					contact.py += deltaY
					linear += lateral * (deltaY * inverseMass)
					angular += angularResponse(offset:Cross(lateral * deltaY))

					-- Friction circle on the accumulated impulse, shrunk past the
					-- peak of the force curve (sliding grip).
					local limit = contact.frictionLimit * contact.lambdaNormal
					local magnitude = math.sqrt(contact.px * contact.px + contact.py * contact.py)

					if magnitude > limit then
						local scale = limit / math.max(magnitude, EPSILON)
						local clampedX = contact.px * scale
						local clampedY = contact.py * scale
						local correctionX = clampedX - contact.px
						local correction = tangent * correctionX + lateral * (clampedY - contact.py)

						contact.px = clampedX
						contact.py = clampedY
						contact.saturated = true
						linear += correction * inverseMass
						angular += angularResponse(offset:Cross(correction))

						if held then
							wheel.brakeLambda += correctionX * wheel.radius
						else
							wheel.omega -= correctionX * wheel.radius / spinInertia
						end
					end
				end
			end
		end
	end

	-- Apply the solved impulses as a constant force over this frame.
	local inverseStep = 1 / deltaTime
	-- Torque the tire VectorForces cannot carry: the wheels pass their
	-- suspension forces to the chassis at the axles, and spinning a wheel
	-- (or the crank) up twists the chassis the other way. Forward rolling
	-- spins about -right, so a spin-up turns the chassis about +right:
	-- throttle in the air lifts the nose, braking drops it.
	local chassisTorque = Vector3.zero
	local spinAxis = frameCFrame.RightVector

	for _, wheel in self.wheels do
		local contact = wheel.contact
		local telemetry = wheel.telemetry
		local brakeLimit = wheel.brakeTorque * deltaTime
		local axis = wheel.axisWorld

		-- Move the wheel along its axis with the solved speeds.
		local strokeRate = wheel.axialVelocity - (linear + angular:Cross(wheel.axleOffset)):Dot(axis)
		local stroke = wheel.stroke + strokeRate * deltaTime

		if stroke < 0 then
			stroke = 0
			strokeRate = math.max(strokeRate, 0)
		elseif stroke > wheel.travel then
			stroke = wheel.travel
			strokeRate = math.min(strokeRate, 0)
		end

		wheel.stroke = stroke
		wheel.strokeRate = strokeRate
		wheel.compression = stroke
		wheel.extension = wheel.travel - stroke

		-- The suspension pushes the chassis along the axis through the axle;
		-- the tire's force across the axis acts at the contact.
		local axleForce = axis * ((wheel.lambdaSuspension - wheel.lambdaTop + wheel.lambdaBottom) * inverseStep)
		local applicationPoint = wheel.axle

		telemetry.omega = wheel.omega
		telemetry.compression = stroke
		telemetry.extension = wheel.extension
		telemetry.hardStop = wheel.lambdaBottom > 0
		telemetry.springForce = wheel.springForce
		telemetry.brakeTorque = math.abs(wheel.brakeLambda) * inverseStep
		-- ABS is working when it holds the brake below what the rider asks.
		wheel.absActive = brakeLimit > 0
			and wheel.absLimit < brakeLimit
			and math.abs(wheel.brakeLambda) >= wheel.absLimit * 0.98
		telemetry.absActive = wheel.absActive

		chassisTorque += spinAxis * (wheel.spinInertia * (wheel.omega - wheel.spinStart) * inverseStep)

		if contact.active then
			local force = axleForce + contact.normalPerp * (contact.lambdaNormal * inverseStep)

			if contact.hasTire then
				force += contact.tangent * (contact.px * inverseStep)
					+ contact.lateral * (contact.py * inverseStep)

				local relative = linear + angular:Cross(contact.offset) - contact.groundVelocity
				local longitudinalSpeed = relative:Dot(contact.tangent)

				telemetry.slipSpeed = wheel.omega * wheel.radius - longitudinalSpeed
				telemetry.slipRatio = telemetry.slipSpeed / contact.referenceSpeed
				telemetry.lateralSlip = relative:Dot(contact.lateral)
				telemetry.slipAngle = math.atan2(telemetry.lateralSlip, math.max(math.abs(longitudinalSpeed), slipFloor))
				telemetry.camber = contact.camber
				telemetry.longitudinalForce = contact.px * inverseStep

				-- Where the tire ends up on its force curve, and the force its
				-- carcass now carries, for the next frame.
				wheel.slipRatio = telemetry.slipRatio
				wheel.slipTan = telemetry.lateralSlip / math.max(math.abs(longitudinalSpeed), slipFloor)
				wheel.slipForceX = contact.px * inverseStep
				wheel.slipForceY = (contact.py - contact.camberImpulse) * inverseStep
			else
				telemetry.slipSpeed = 0
				telemetry.slipRatio = 0
				telemetry.lateralSlip = 0
				telemetry.slipAngle = 0
				telemetry.longitudinalForce = 0
				wheel.slipRatio = 0
				wheel.slipTan = 0
				wheel.slipForceX = 0
				wheel.slipForceY = 0
			end

			telemetry.load = contact.lambdaNormal * inverseStep
			telemetry.grounded = contact.lambdaNormal > 0
			wheel.lastLoad = telemetry.load
			telemetry.saturated = contact.saturated

			applicationPoint = contact.point
			wheel.force.Force = force
		else
			telemetry.load = 0
			telemetry.friction = 0
			wheel.lastLoad = 0
			telemetry.slipSpeed = 0
			telemetry.slipRatio = 0
			telemetry.lateralSlip = 0
			telemetry.slipAngle = 0
			telemetry.longitudinalForce = 0
			telemetry.normalizedSlip = 0
			wheel.slipRatio = 0
			wheel.slipTan = 0
			wheel.slipForceX = 0
			wheel.slipForceY = 0
			wheel.force.Force = axleForce
		end

		-- The VectorForce sits at the contact point. The chassis should feel
		-- the contact force there, but the axial share the wheel's spring
		-- answers acts at the axle: move that difference to the axle.
		-- The attachment lives on the drawn chassis, which the rigid roll
		-- constraint turns to its new lean right away: place it for that
		-- pose, at the world point of the physical contact.
		wheel.attachment.Position = heldBodyCFrame:PointToObjectSpace(applicationPoint)

		if contact.active then
			local unbalanced = axleForce - axis * (contact.lambdaNormal * contact.axisDot * inverseStep)

			chassisTorque += (wheel.axle - applicationPoint):Cross(unbalanced)
		end
	end

	if engineControl then
		-- The crank turns the same way as the wheels.
		chassisTorque += spinAxis * (engine.inertia * (engine.omega - engineSpinStart) * inverseStep)
	end

	if self.chassisTorque then
		self.chassisTorque.Torque = chassisTorque
	end

	if self.aeroForce then
		self.aeroForce.Force = drag
	end

	self:_updateTrajectory(deltaTime, velocity, frameCFrame)

	state.speed = speed
	state.forwardSpeed = forwardSpeed
	state.lean = lean
	state.yawRate = angularVelocity:Dot(WORLD_UP)
	state.rearWheelSpeed = self.rear.omega * self.rear.radius
	state.rearGrounded = self.rear.grounded
	state.frontGrounded = self.front.grounded
	state.drag = drag.Magnitude
	state.rollingResistance = rollingResistance

	if engineControl then
		state.engineRPM = engine.omega / RAD_PER_RPM
		state.engineTorque = engineTorque + (engine.limitLambda + engine.idleLambda) * inverseStep
		state.clutchTorque = engine.clutchLambda * inverseStep
		state.clutchCapacity = clutchLimit * inverseStep
		state.clutchSlipRPM = gearRatio ~= 0 and (engine.omega - gearRatio * rearWheel.omega) / RAD_PER_RPM or 0
		-- Locked: the clutch carried what was needed without reaching its
		-- capacity, and is not slipping as a slipper (the gearbox would turn
		-- the engine past the rev limit).
		state.clutchLocked = clutchLimit > 0
			and math.abs(engine.clutchLambda) < clutchLimit * 0.999
			and gearRatio * rearWheel.omega <= engine.limitOmega
		state.gearRatio = gearRatio
		state.wheelDriveTorque = state.clutchTorque * gearRatio
		state.revLimited = engine.limitLambda < -EPSILON
	else
		state.engineTorque = 0
		state.clutchTorque = 0
		state.clutchCapacity = 0
		state.clutchSlipRPM = 0
		state.clutchLocked = false
		state.gearRatio = 0
		state.wheelDriveTorque = rearWheel.driveLambda * inverseStep
		state.revLimited = false
	end

	return state
end

--[=[
	Brake torques for the rider's lever (pressure 0..1, both brakes) and
	pedal (rearPressure 0..1, rear brake alone). The lever asks for
	pressure * MaxDeceleration * g on level ground and splits it in the
	ideal ratio for that deceleration: with load transfer the front carries
	(b + (a/g) h) / L of the weight, so giving it that share of the braking
	makes both tires use the same fraction of their grip. Each brake also
	slows its own wheel's spin.
]=]
function BikeDynamics:brakeTorques(pressure, rearPressure)
	local brakeConfig = self.config.Brakes
	local gravity = math.max(self.world.Gravity, EPSILON)
	local deceleration = clamp(pressure or 0, 0, 1) * brakeConfig.MaxDeceleration * gravity
	local frontShare = clamp(
		(self.rearToCenter + deceleration / gravity * self.centerHeight) / self.wheelbase,
		0,
		1
	)
	local force = self.mass * deceleration
	local front = self.front
	local rear = self.rear
	local frontTorque = force * frontShare * front.radius + front.spinInertia * deceleration / front.radius
	local rearTorque = force * (1 - frontShare) * rear.radius + rear.spinInertia * deceleration / rear.radius
	local pedalDeceleration = clamp(rearPressure or 0, 0, 1) * brakeConfig.RearDeceleration * gravity
	local pedalTorque = pedalDeceleration * (self.mass * rear.radius + rear.spinInertia / rear.radius)

	return frontTorque, math.max(rearTorque, pedalTorque)
end

-- Holding torques of the parking brake (front, rear).
function BikeDynamics:parkingBrakeTorques()
	local holding = self.config.Brakes.ParkingCapacity * self.mass * math.max(self.world.Gravity, EPSILON)

	return holding * self.front.radius, holding * self.rear.radius
end

-- What the visual parts show for the current physics state: the handlebar
-- of the riding pose (the physical one at riding speed), each wheel's
-- suspension travel from its static position (compression positive) and
-- spin rate. The rider's client also sends it to the other players.
function BikeDynamics:visualState()
	local visual = self.visual

	visual.handlebar = self.displayHandlebar
	visual.frontTravel = self.front.staticExtension - self.front.extension
	visual.rearTravel = self.rear.staticExtension - self.rear.extension
	visual.frontOmega = self.front.omega
	visual.rearOmega = self.rear.omega

	return visual
end

-- Wheel spin, suspension travel and steering for the visual parts.
-- Motor6D.Transform is applied right before physics, so call this from
-- PreSimulation after step().
function BikeDynamics:updateVisuals(deltaTime)
	self.visualRig:apply(deltaTime, self:visualState())
end

-- Puts visual parts back to their authored pose.
function BikeDynamics:resetVisuals()
	self.visualRig:reset()
end

--[=[
	VisualRig

	The bike's visual joints (wheels, fork, and the exterior's handlebar and
	swingarm) and the pose a riding state gives them. The rider's client
	drives it from BikeDynamics:visualState(); the other players' clients
	drive it from the state the rider sends (BikeVisualSync), because joint
	Transforms do not replicate.
]=]
local VisualRig = {}
VisualRig.__index = VisualRig
BikeDynamics.VisualRig = VisualRig

-- Pose state of one visual wheel joint (suspension stroke and spin).
local function visualWheel(joint, axis)
	local rest = joint.C0

	return {
		joint = joint,
		rest = rest,
		-- Suspension axis in chassis space.
		axis = axis,
		-- Forward roll moves the contact patch backward: a negative turn
		-- about the wheel's own axle when the axle points to the chassis
		-- right.
		spinSign = rest.RightVector.X >= 0 and 1 or -1,
		spinAngle = 0,
	}
end

-- Nil if the rig has no wheel joints yet.
function VisualRig.new(rig)
	local frontJoint = rig:FindFirstChild(NAMES.FrontWheelJoint)
	local rearJoint = rig:FindFirstChild(NAMES.RearWheelJoint)

	if not (frontJoint and rearJoint) then
		return nil
	end

	local forkJoint = rig:FindFirstChild(NAMES.ForkJoint)
	local steerAxis, steerPivot = steeringOf(frontJoint, forkJoint)
	local self = setmetatable({
		front = visualWheel(frontJoint, steerAxis),
		rear = visualWheel(rearJoint, Vector3.yAxis),
		forkJoint = forkJoint,
		-- Exterior shell joints (absent without an exterior).
		steerJoint = rig:FindFirstChild(NAMES.SteerJoint),
		swingarmJoint = rig:FindFirstChild(NAMES.SwingarmJoint),
		steerAxis = steerAxis,
		steerPivot = steerPivot,
	}, VisualRig)

	if self.swingarmJoint then
		-- Swingarm at rest, from its pivot to the rear axle (chassis space).
		self.swingarmArm = self.rear.rest.Position - self.swingarmJoint.C0.Position
	end

	return self
end

--[=[
	Poses the visual parts for `state` (see BikeDynamics:visualState):
	handlebar (rad), frontTravel and rearTravel (studs, compression
	positive), frontOmega and rearOmega (rad/s; the wheels turn by them over
	deltaTime).
]=]
function VisualRig:apply(deltaTime, state)
	local steer = nil

	if math.abs(state.handlebar) > EPSILON then
		steer = CFrame.new(self.steerPivot)
			* CFrame.fromAxisAngle(self.steerAxis, state.handlebar)
			* CFrame.new(-self.steerPivot)
	end

	local front = self.front
	local rear = self.rear

	front.spinAngle = (front.spinAngle + state.frontOmega * deltaTime) % (2 * math.pi)
	rear.spinAngle = (rear.spinAngle + state.rearOmega * deltaTime) % (2 * math.pi)

	local frontDisplacement = front.axis * state.frontTravel
	local rearDisplacement = rear.axis * state.rearTravel
	local frontTarget = CFrame.new(frontDisplacement) * front.rest * CFrame.Angles(-front.spinSign * front.spinAngle, 0, 0)

	if steer then
		frontTarget = steer * frontTarget
	end

	front.joint.Transform = front.rest:Inverse() * frontTarget
	rear.joint.Transform = rear.rest:Inverse()
		* CFrame.new(rearDisplacement)
		* rear.rest
		* CFrame.Angles(-rear.spinSign * rear.spinAngle, 0, 0)

	if self.forkJoint then
		local forkRest = self.forkJoint.C0
		local target = CFrame.new(frontDisplacement) * forkRest

		if steer then
			target = steer * target
		end

		self.forkJoint.Transform = forkRest:Inverse() * target
	end

	-- Exterior handlebar: turns like the fork but does not stroke.
	if self.steerJoint then
		local steerRest = self.steerJoint.C0

		self.steerJoint.Transform = steer and steerRest:Inverse() * steer * steerRest or CFrame.identity
	end

	-- Exterior swingarm: turns about its pivot (chassis right axis) to the
	-- angle that keeps the rear axle on it.
	if self.swingarmJoint then
		local arm = self.swingarmArm
		local moved = arm + rearDisplacement
		local angle = math.atan2(moved.Z, moved.Y) - math.atan2(arm.Z, arm.Y)

		self.swingarmJoint.Transform = CFrame.Angles(angle, 0, 0)
	end
end

-- Puts the visual parts back to their authored pose.
function VisualRig:reset()
	for _, joint in { self.front.joint, self.rear.joint, self.forkJoint, self.steerJoint, self.swingarmJoint } do
		if joint then
			joint.Transform = CFrame.identity
		end
	end
end

--[=[
	RiderControls

	Turns rider input into the controls for BikeDynamics:step on the
	machine that rides the bike (and in the offline bench):

	- Brakes: lever and pedal pressure ramps, the linked split from
	  BikeDynamics:brakeTorques, ABS on/off.
	- Traction control: throttle is scaled back when the rear tire slips
	  past its peak slip (from the tire model), on the ground or in the air.
	- Gearbox: manual sequential, 1-N-2-3-4-5-6 like a motorcycle's. The
	  rider shifts with paddles (shiftUp / shiftDown); a full click from 1st
	  goes to 2nd and neutral sits between them (selectNeutral). Out of
	  neutral, down is 1st; up is 2nd when standing or slow and, while
	  rolling, the gear that puts the engine nearest its torque peak without
	  passing the redline. A shift opens the clutch, rev-matches the engine
	  (ignition cut going up, throttle blip going down), selects the gear and
	  closes the clutch, carrying only the torque the rider asks for until
	  the speeds match; the centrifugal clutch does the rest (no clutch
	  lever). Every shift is taken at once, at any speed: a downshift the
	  road speed would over-rev makes the engine jump to the limiter while
	  the clutch slips (a slipper clutch) until the speed fits the gear.
	- At a standstill: coming to a stop selects neutral, and the rider
	  shifts out of it as always (W alone only revs the engine). In neutral
	  the brake (S) held ReverseDelay longer selects reverse, a real gear
	  that makes ReverseTopSpeed at ReverseRevLimitRPM, where the
	  ride-by-wire throttle holds the engine (it never revs out backing
	  up). In reverse S is the throttle and W the brake; W (once slow) or
	  up leaves it for 1st.

	input = {
		throttle, brake, rearBrake, steer: number,
		engineOn: boolean,
	}
]=]
local RiderControls = {}
RiderControls.__index = RiderControls
BikeDynamics.RiderControls = RiderControls

-- The ride-by-wire throttle holding the engine at a speed (rev matching,
-- the reverse rev limit) opens fully within this far below it, as a share
-- of the rev limit (so it suits any engine's rev range).
local HOLD_BAND_SHARE = 0.06
-- Crank and gearbox speeds this close (share of the rev limit) count as matched.
local SHIFT_SYNC_SHARE = 0.025
-- An engine within this share of the rev limit counts as limiting.
local REV_LIMIT_SHARE = 0.004
-- A shift that has not synchronized after this long closes the clutch anyway (s).
local SHIFT_SYNC_TIMEOUT = 0.4
-- Throttle below this counts as closed.
local CLOSED_THROTTLE = 0.05
-- Gear number of reverse (selected from a standstill, not by the paddles).
local REVERSE = -1
-- Slower than this (studs/s) the bike stands still. Coming to a stop after
-- riding faster than ROLLING_SPEED selects neutral (Drivetrain.AutoNeutral).
local STOPPED_SPEED = 0.5
local ROLLING_SPEED = 2
-- W takes 1st out of reverse below this speed (studs/s).
local START_SPEED = 2
-- A brake lever pulled this far counts as held for reverse.
local REVERSE_BRAKE_INPUT = 0.5

RiderControls.REVERSE = REVERSE

-- The ride-by-wire throttle that holds the engine at targetRPM: the
-- opening at which its torque balances its own drag there, plus a push
-- toward it across HOLD_BAND_SHARE of the rev limit.
local function holdThrottle(drivetrain, targetRPM, engineRPM)
	local drag = Powertrain.engineBrakeTorque(drivetrain, targetRPM)
	local balance = drag / math.max(Powertrain.engineTorque(drivetrain, targetRPM) * drivetrain.Efficiency + drag, EPSILON)

	return clamp(balance + (targetRPM - engineRPM) / (HOLD_BAND_SHARE * drivetrain.RevLimitRPM), 0, 1)
end

-- Rider controls for one BikeDynamics: gearbox, brakes, traction control.
function RiderControls.new(dynamics)
	local config = dynamics.config
	local drivetrain = config.Drivetrain
	local self = setmetatable({
		dynamics = dynamics,
		config = config,
		gearCount = #drivetrain.GearRatios,
		reverseRatio = Powertrain.reverseRatio(drivetrain, dynamics.rear.radius),
		reverseLimitRPM = Powertrain.reverseLimitRPM(drivetrain),
		controls = {
			steer = 0,
			engine = {
				running = false,
				throttle = 0,
				gearRatio = 0,
				clutch = 1,
			},
			frontBrakeTorque = 0,
			rearBrakeTorque = 0,
			abs = config.Brakes.ABS ~= false,
		},
	}, RiderControls)

	self:reset()

	return self
end

-- Back to the start gear with everything released (when a ride begins).
function RiderControls:reset()
	self.gear = clamp(self.config.Drivetrain.StartGear or 1, 0, self.gearCount)
	self.shift = nil
	self.pendingShift = 0
	self.brakePressure = 0
	self.rearPressure = 0
	self.tractionScale = 1
	self.throttle = 0
	self.driveState = "DRIVE"
	-- How long the brake has been held at a standstill, and whether the
	-- bike has ridden since it last stood still.
	self.reverseTimer = 0
	self.rolled = false
end

-- Gear ratio times final drive for a gear, negative in reverse; 0 in neutral.
function RiderControls:overallRatio(gear)
	local drivetrain = self.config.Drivetrain

	if gear == REVERSE then
		return self.reverseRatio and -self.reverseRatio * drivetrain.FinalDriveRatio or 0
	end

	return Powertrain.overallRatio(drivetrain, gear)
end

-- Engine rpm in a gear when the rear wheel rolls at the road speed.
function RiderControls:roadRPM(gear)
	local dynamics = self.dynamics
	local wheelOmega = math.abs(dynamics.state.forwardSpeed or 0) / dynamics.rear.radius

	return wheelOmega * math.abs(self:overallRatio(gear)) / RAD_PER_RPM
end

-- Engine rpm in a gear at the rear wheel's actual speed (what the clutch meets).
function RiderControls:_wheelRPM(gear)
	return math.abs(self.dynamics.rear.omega) * math.abs(self:overallRatio(gear)) / RAD_PER_RPM
end

-- Next gear of the 1-N-2-3-4-5-6 pattern: a full click from 1st reaches
-- 2nd; from neutral, up is 2nd and down is 1st. Up out of reverse is 1st.
function RiderControls:_nextGear(direction)
	if self.gear == REVERSE then
		return direction > 0 and 1 or REVERSE
	end

	if self.gear == 0 then
		if direction < 0 then
			return 1
		end

		return self:_matchedGear()
	end

	return clamp(self.gear + direction, 1, self.gearCount)
end

-- Up out of neutral while rolling: the gear that puts the engine nearest
-- the speed where its torque peaks, never past the redline; 2nd when
-- standing or slow (the gear a full click up from neutral reaches).
function RiderControls:_matchedGear()
	local drivetrain = self.config.Drivetrain
	local target = Powertrain.peakTorqueRPM(drivetrain)
	local best = math.min(2, self.gearCount)
	local bestGap = math.huge

	for gear = best, self.gearCount do
		local rpm = self:roadRPM(gear)
		local gap = math.abs(rpm - target)

		if rpm <= drivetrain.RedlineRPM and gap < bestGap then
			best = gear
			bestGap = gap
		end
	end

	-- Faster than any gear allows below the redline: the top gear.
	if self:roadRPM(self.gearCount) > drivetrain.RedlineRPM then
		best = self.gearCount
	end

	return best
end

-- Starts a shift to target; false if one is under way or target is invalid.
function RiderControls:_beginShift(target)
	if self.shift or target == self.gear or target < 0 or target > self.gearCount then
		return false
	end

	self.shift = {
		target = target,
		direction = target > self.gear and 1 or -1,
		phase = "open",
		timer = 0,
	}

	return true
end

-- A paddle click: shift now, or after the shift under way.
function RiderControls:_requestShift(direction)
	if self.shift then
		-- Taken as soon as the current shift finishes.
		self.pendingShift = direction

		return
	end

	-- Taken at once at any speed: a downshift that the road speed would
	-- over-rev is caught by the slipper clutch (see step), so the engine
	-- jumps to the limiter and the clutch slips until the speed fits.
	self:_beginShift(self:_nextGear(direction))
end

-- Paddle up (LeftShift, R1).
function RiderControls:shiftUp()
	self:_requestShift(1)
end

-- Paddle down (RightShift, L1).
function RiderControls:shiftDown()
	self:_requestShift(-1)
end

-- Both paddles: neutral at once, from any gear, cancelling a shift under way.
function RiderControls:selectNeutral()
	self.shift = nil
	self.pendingShift = 0
	self.gear = 0
end

-- Gear help at a standstill (throttle W, brake lever S):
--   - coming to a stop in gear with the throttle closed selects neutral,
--     as a rider does (Drivetrain.AutoNeutral); a gear picked while
--     standing stays in. Out of neutral the rider shifts as always (down
--     1st, up 2nd); W in neutral only revs the engine
--   - S held for Drivetrain.ReverseDelay in neutral at a standstill, with
--     the throttle closed, selects reverse
--   - W in reverse, nearly stopped, takes 1st (the one gear change made
--     for the rider)
function RiderControls:_updateGearHelp(deltaTime, throttleInput, brakeInput, running)
	local drivetrain = self.config.Drivetrain
	local speed = math.abs(self.dynamics.state.forwardSpeed or 0)
	local stopped = speed < STOPPED_SPEED
	local throttleClosed = throttleInput < CLOSED_THROTTLE

	if speed > ROLLING_SPEED then
		self.rolled = true
	elseif stopped and throttleClosed then
		if self.rolled and drivetrain.AutoNeutral and self.gear > 0 then
			self:selectNeutral()
		end

		self.rolled = false
	end

	if self.gear == REVERSE and running and not throttleClosed and speed < START_SPEED and self.shift == nil then
		-- Nothing to match this slow (the centrifugal clutch is open at
		-- idle): 1st goes straight in, so riding off is as quick as in 1st.
		self.pendingShift = 0
		self.gear = 1
	end

	if self.reverseRatio
		and running
		and stopped
		and throttleClosed
		and brakeInput >= REVERSE_BRAKE_INPUT
		and self.gear == 0
		and self.shift == nil
	then
		self.reverseTimer += deltaTime

		if self.reverseTimer >= (drivetrain.ReverseDelay or 0) then
			self.shift = nil
			self.pendingShift = 0
			self.gear = REVERSE
			self.reverseTimer = 0
		end
	else
		self.reverseTimer = 0
	end
end

-- Brake pressure follows the lever over ApplyTime / ReleaseTime.
local function rampPressure(current, target, deltaTime, brakeConfig)
	if target > current then
		return math.min(current + deltaTime / math.max(brakeConfig.ApplyTime, EPSILON), target)
	end

	return math.max(current - deltaTime / math.max(brakeConfig.ReleaseTime, EPSILON), target)
end

-- Traction control: throttle scaled back while the rear tire slips past its peak.
function RiderControls:_updateTraction(deltaTime)
	local drivetrain = self.config.Drivetrain
	local state = self.dynamics.state
	local speed = math.abs(state.forwardSpeed or 0)
	local peakSlip = state.rear.peakSlipRatio

	if peakSlip == nil or peakSlip <= 0 then
		peakSlip = 0.12
	end

	-- Wheel surface speed over the ground speed at the rear contact (both
	-- at the end of the last step); in the air, against the bike's speed.
	local slipSpeed

	if state.rearGrounded then
		-- Along the way the engine drives the wheel (backward in reverse).
		slipSpeed = (state.rear.slipSpeed or 0) * (self.gear == REVERSE and -1 or 1)
	else
		slipSpeed = math.abs(state.rearWheelSpeed or 0) - speed
	end

	local slipStart = peakSlip * drivetrain.TractionSlipStartRatio
	local slipFullCut = peakSlip * drivetrain.TractionSlipFullCutRatio
	local slipRatio = math.max(slipSpeed, 0) / math.max(speed, drivetrain.TractionSlipReferenceSpeed)
	local target = 1 - clamp((slipRatio - slipStart) / math.max(slipFullCut - slipStart, 1e-3), 0, 1)
	local response = target < self.tractionScale and drivetrain.TractionCutResponse
		or drivetrain.TractionRecoveryResponse

	self.tractionScale = approach(self.tractionScale, target, response, deltaTime)
end

-- Advances an ongoing shift; returns the clutch command and, while the
-- engine is being rev-matched, the throttle that does it.
function RiderControls:_updateShift(deltaTime)
	local shift = self.shift

	if shift == nil then
		return 1, nil
	end

	local drivetrain = self.config.Drivetrain
	local state = self.dynamics.state

	shift.timer += deltaTime

	if shift.phase == "open" and shift.timer >= drivetrain.ShiftTime then
		self.gear = shift.target
		shift.phase = "sync"
		shift.timer = 0
	end

	if shift.target == 0 then
		-- Into neutral: nothing to synchronize. (Out of neutral the gear is
		-- still 0 while the shift opens; that one synchronizes as usual.)
		if self.gear == 0 then
			self.shift = nil
		end

		return 0, nil
	end

	-- Rev-match target: the gearbox speed in the new gear, at most the rev
	-- limit (beyond it the slipper clutch takes over). The throttle holds
	-- the engine there: the blip lands on the target however strong the
	-- engine's drag.
	local targetRPM = math.min(self:_wheelRPM(shift.target), drivetrain.RevLimitRPM)
	local matchThrottle = holdThrottle(drivetrain, targetRPM, state.engineRPM)

	if shift.phase == "open" then
		return 0, matchThrottle
	end

	if targetRPM < drivetrain.ClutchEngageRPM then
		-- Nearly stopped: the centrifugal clutch takes up the drive by itself.
		self.shift = nil

		return 1, nil
	end

	local synced = math.abs(state.engineRPM - targetRPM) < SHIFT_SYNC_SHARE * drivetrain.RevLimitRPM

	if (synced and shift.timer >= drivetrain.ClutchEngageTime)
		or shift.timer >= drivetrain.ClutchEngageTime + SHIFT_SYNC_TIMEOUT
	then
		self.shift = nil

		return 1, nil
	end

	-- Close the clutch only as far as the torque the rider asks for, so the
	-- engine's spin is traded smoothly instead of as a jolt.
	local rpm = math.max(state.engineRPM, drivetrain.IdleRPM)
	local demand = math.max(
		self.throttleInput * Powertrain.engineTorque(drivetrain, rpm) * drivetrain.Efficiency,
		Powertrain.engineBrakeTorque(drivetrain, rpm)
	)
	local capacity = Powertrain.clutchCapacity(drivetrain, rpm)
	local carry = capacity > EPSILON and clamp(demand / capacity, 0.15, 1) or 1
	local ramp = clamp(shift.timer / math.max(drivetrain.ClutchEngageTime, EPSILON), 0, 1)

	if synced then
		return carry + (1 - carry) * ramp, nil
	end

	return carry * ramp, matchThrottle
end

-- One word for what the bike is doing (DRIVE, SHIFT, ABS, ...).
function RiderControls:_updateDriveState(running)
	local drivetrain = self.config.Drivetrain
	local state = self.dynamics.state
	local driveState

	if not running then
		driveState = "ENGINE_OFF"
	elseif state.recovering then
		driveState = "RECOVERY"
	elseif self.shift then
		driveState = "SHIFT"
	elseif self.gear == 0 then
		driveState = "NEUTRAL"
	elseif self.gear == REVERSE then
		driveState = "REVERSE"
	elseif state.front.absActive or state.rear.absActive then
		driveState = "ABS"
	elseif self.brakePressure > 0.02 or self.rearPressure > 0.02 then
		driveState = "BRAKE"
	elseif not state.rearGrounded then
		driveState = "AIRBORNE"
	elseif self.tractionScale < 0.99 and self.throttleInput > CLOSED_THROTTLE then
		driveState = "TRACTION_LIMIT"
	elseif state.revLimited or state.engineRPM >= drivetrain.RevLimitRPM * (1 - REV_LIMIT_SHARE) then
		driveState = "REV_LIMIT"
	elseif self.throttleInput > CLOSED_THROTTLE then
		driveState = state.clutchLocked and "DRIVE" or "LAUNCH"
	else
		driveState = state.clutchLocked and "ENGINE_BRAKE" or "COAST"
	end

	self.driveState = driveState
end

-- One frame of rider control; returns the controls table for step().
function RiderControls:update(deltaTime, input)
	local config = self.config
	local brakeConfig = config.Brakes
	local dynamics = self.dynamics
	local controls = self.controls
	local engineControl = controls.engine
	local running = input.engineOn == true
	local throttleInput = clamp(input.throttle or 0, 0, 1)
	local brakeInput = clamp(input.brake or 0, 0, 1)

	self:_updateGearHelp(deltaTime, throttleInput, brakeInput, running)

	-- In reverse the brake lever (S) is the throttle and W brakes; with both
	-- held, W wins.
	if self.gear == REVERSE then
		throttleInput, brakeInput = throttleInput < CLOSED_THROTTLE and brakeInput or 0, throttleInput
	end

	self.throttleInput = throttleInput

	-- Brakes.
	self.brakePressure = rampPressure(self.brakePressure, brakeInput, deltaTime, brakeConfig)
	self.rearPressure = rampPressure(self.rearPressure, clamp(input.rearBrake or 0, 0, 1), deltaTime, brakeConfig)

	local frontTorque, rearTorque = dynamics:brakeTorques(self.brakePressure, self.rearPressure)

	self:_updateTraction(deltaTime)

	local clutchCommand, matchThrottle = self:_updateShift(deltaTime)

	if self.shift == nil and self.pendingShift ~= 0 then
		local direction = self.pendingShift

		self.pendingShift = 0
		self:_requestShift(direction)
	end

	local throttle = self.throttleInput * self.tractionScale

	if matchThrottle then
		throttle = matchThrottle
	end

	-- Reverse: the throttle closes as the engine nears the reverse rev
	-- limit and holds it there, far below the limiter.
	if self.gear == REVERSE then
		throttle = math.min(throttle, holdThrottle(config.Drivetrain, self.reverseLimitRPM, dynamics.state.engineRPM or 0))
	end

	-- In neutral the clutch is open: the engine revs, the bike stays.
	if self.gear == 0 then
		clutchCommand = 0
	end

	self.throttle = running and throttle or 0

	engineControl.running = running
	engineControl.throttle = self.throttle
	engineControl.gearRatio = self:overallRatio(self.gear)
	engineControl.clutch = clutchCommand
	controls.steer = input.steer or 0
	controls.frontBrakeTorque = frontTorque
	controls.rearBrakeTorque = rearTorque
	controls.abs = brakeConfig.ABS ~= false

	self:_updateDriveState(running)

	return controls
end

return BikeDynamics
