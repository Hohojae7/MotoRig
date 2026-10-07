--[[
	BikeConfig

	Physical parameters for the raycast motorcycle (BikeDynamics).

	Units: studs, seconds, degrees, Hz. Values marked "ratio" or
	"coefficient" are dimensionless, so they keep their meaning on any map,
	at any gravity, and for any bike mass. Everything else (spring rates,
	damping, static loads, contact friction, lean limits) is derived at
	runtime from the model geometry, the measured mass, and the surface the
	tire is touching.
]]

local config = {}

config.Rig = {
	ChassisPart = "PrototypeFrame",
	FrontWheel = "FrontWheel",
	RearWheel = "RearWheel",
	-- Optional. Its UpVector is the steering/fork axis; without it the front
	-- suspension axis is the chassis up axis.
	FrontFork = "FrontForkCarrier",

	-- Optional body shell: a Model of this name in the bike. Without it the
	-- placeholder parts above are what you see. Its child models tell how
	-- their parts move: Body (fixed), Steering (turns with the handlebar),
	-- Fork (turns and strokes with the front suspension), FrontWheel and
	-- RearWheel (follow and spin with the wheels), Swingarm (pivots about its
	-- "Pivot" attachment). Each wheel group has an "Axle" attachment at the
	-- wheel center; the shell is moved onto the physics wheels by those.
	-- The shell never changes the physics: its parts are massless, do not
	-- collide and are left out of the air-drag silhouette.
	Exterior = "Exterior",

	-- Height of the body collision box above the ground at rest, as a ratio
	-- of the larger wheel radius. 1.0 = axle height. Obstacles below it are
	-- climbed by the tire model; obstacles above it hit the body like a wall,
	-- which is also where a real wheel stops being able to climb.
	ColliderClearanceRatio = 1.0,
}

config.Mass = {
	-- Avatar parts become massless while riding so handling does not depend
	-- on the rider's avatar package.
	RiderMassless = true,

	-- Low ballast that sets the chassis mass and center of mass.
	BallastMass = 4.4,
	BallastSize = Vector3.new(0.8, 0.4, 1.2),
	BallastLocalPosition = Vector3.new(0, -0.6, 0),

	-- Wheel + tire mass = density * cylinder volume of each visual wheel.
	-- It is carried by the chassis at the axle (yaw/pitch inertia) and also
	-- sets the wheel spin inertia.
	WheelDensity = 0.7,
	-- Spin inertia = ratio * mass * radius^2 (0.5 solid disc, 1.0 thin hoop).
	WheelSpinInertiaRatio = 0.6,
}

config.Suspension = {
	-- Travel: total stroke along the suspension axis (studs).
	-- SagRatio: share of the travel used by the static load. The authored
	--   model pose is treated as the static ride height.
	-- Frequency: ride frequency of the corner (Hz). Spring rate is computed
	--   from the measured static corner load, so ride height and feel stay
	--   the same if mass changes. Rear slightly above front (Olley flat ride).
	-- Damping ratios: fraction of critical damping. Rebound > bump, as on
	--   real dampers.
	Front = {
		Travel = 0.45,
		SagRatio = 0.30,
		Frequency = 4.5,
		BumpDampingRatio = 0.30,
		ReboundDampingRatio = 0.55,
	},
	Rear = {
		Travel = 0.40,
		SagRatio = 0.30,
		Frequency = 5.0,
		BumpDampingRatio = 0.30,
		ReboundDampingRatio = 0.55,
	},

	-- Progressive bump rubber over the last part of the stroke. Gain is the
	-- extra rate at full compression as a multiple of the spring rate. At
	-- full stroke a hydraulic stop ends the travel without a rebound.
	BumpStopRange = 0.15,
	BumpStopGain = 2.0,

	-- High-speed compression damping: above this stroke speed (studs/s) the
	-- fork's high-speed valve opens and damping force grows at only
	-- HighSpeedDampingRatio of the low-speed slope, so sharp edges are not
	-- met with a damper spike. Rebound damping stays linear.
	HighSpeedDampingStart = 2,
	HighSpeedDampingRatio = 0.35,

	-- The wheel is an unsprung mass between the suspension and the tire
	-- (quarter-car model), so an edge hits the wheel first and the
	-- suspension passes it to the chassis.
	-- Tire radial deflection under the static load (studs); it sets the
	-- tire's radial stiffness. The suspension rate is chosen so tire and
	-- spring in series ride at the configured frequency.
	TireDeflection = 0.03,
	-- Tire damping as a fraction of critical for the wheel on its tire.
	TireDampingRatio = 0.2,
}

config.Tire = {
	-- Peak friction, combined with the contacted surface using Roblox's
	-- friction rule (FrictionWeight-weighted average), so ice, grass and
	-- plastic maps change grip automatically.
	Friction = 1.0,
	FrictionWeight = 1.0,

	-- Initial tire stiffness per unit normal load (slope of the force curve
	-- at zero slip).
	CorneringStiffness = 14, -- lateral force / load per radian of slip angle
	LongitudinalStiffness = 18, -- longitudinal force / load per unit slip ratio
	CamberStiffness = 0.9, -- camber thrust / load per unit tan(camber)

	-- Pacejka Magic Formula shape (C) and curvature (E). Together with the
	-- stiffness and friction they fix where the force peaks and how much
	-- grip is left once the tire slides (sin(C * pi / 2) of the peak).
	LateralShape = 1.3,
	LateralCurvature = 0.0,
	LongitudinalShape = 1.65,
	LongitudinalCurvature = 0.0,

	-- Load sensitivity: friction and stiffness per unit load drop as the
	-- tire is loaded above its static load (ratio per 100 % extra load).
	FrictionLoadSensitivity = 0.10,
	StiffnessLoadSensitivity = 0.15,

	-- Relaxation length: distance the tire rolls before its force catches
	-- up with a new slip, as a ratio of the wheel radius.
	RelaxationLengthRatio = 0.6,
	LongitudinalRelaxationLengthRatio = 0.3,

	-- Rolling resistance coefficient (resisting force / load).
	RollingResistance = 0.015,

	-- Lower bound (studs/s) of the reference speed used for slip ratio and
	-- slip angle, so slip stays defined when the bike is nearly stopped.
	SlipReferenceMinimumSpeed = 1.0,

	-- Spherecasts on the tire's core circle used to sweep its round profile.
	-- More samples follow sharp edges more closely.
	ProfileSamples = 13,
}

config.Aero = {
	-- Drag = 1/2 * air density * Cd * A * v^2, using Workspace.AirDensity
	-- and Workspace.GlobalWind of whatever map the bike is in.
	DragCoefficient = 0.6,
	-- Frontal area = width x height of the bike and rider silhouette times
	-- this fill ratio (the silhouette is not a full rectangle).
	FrontalAreaFillRatio = 0.6,
	-- The rider's part of the silhouette is a seated rider of this size,
	-- whatever the avatar and its pose: shoulder width and the head top
	-- above the seat (studs). So every avatar rides at the same speeds.
	RiderWidth = 2.0,
	RiderHeight = 3.1,
}

config.Steering = {
	-- Largest front-wheel angle measured on the ground plane.
	MaxGroundSteerAngle = 30,

	-- Rider input smoothing (1/s). Return is faster than turn-in.
	InputResponse = 6,
	InputReturnResponse = 9,
}

config.Lean = {
	-- Hard cap; the friction-derived cap atan(mu * LeanGripUsage) is usually
	-- lower and changes with the surface.
	MaxLeanAngle = 45,
	LeanGripUsage = 0.9,

	-- How hard the rider turns at speed (deg/s). The lateral acceleration it
	-- implies sets the lean, so faster riding leans further for the same
	-- input, up to the friction cap.
	MaxYawRate = 100,

	-- Roll follows the bicycle roll equation (gravity, path acceleration,
	-- countersteer, wheel gyroscopic moments). The rider balances it by
	-- steering; these set how quickly the rider wants the lean to settle.
	RiderRollFrequency = 1.2, -- Hz
	RiderRollDampingRatio = 0.85,
	-- Fastest the rider turns the front wheel (deg/s, ground angle).
	MaxSteerRate = 150,

	-- Below the speed where steering alone can hold the bike up, the rider's
	-- feet/body support it. Steering authority = lateral acceleration the
	-- handlebar can create / g * sin(BalanceReferenceLean); support fades
	-- out between the two authority ratios.
	BalanceReferenceLean = 6,
	AssistAuthorityStart = 1,
	AssistAuthorityEnd = 3,
	-- Largest support moment of feet and body, as a multiple of the gravity
	-- roll moment m * g * h (the support gives only what steering lacks).
	AssistMomentRatio = 2,
	-- Roll damping the rider applies in the air (1/s).
	AirborneRollDamping = 2,

	-- "RollOnly": rigid roll constraint, pitch and yaw stay free so the
	--   suspension can pitch the chassis (default).
	-- "Upright": previous non-rigid upright-axis alignment; fallback only.
	ConstraintMode = "RollOnly",

	-- Upright fallback strength. Torque is a multiple of the bike's gravity
	-- roll moment m * g * h.
	UprightTorqueRatio = 6,
	UprightResponsiveness = 25,
}

-- Riding pose shown at low speed (looks only; turning, grip and balance are
-- unchanged). In a steady turn tan(steer) / tan(lean) = wheelbase * g / v^2,
-- so under Roblox gravity this bike steers more than it leans below
-- sqrt(wheelbase * g / SteerLeanRatio) (about 30 studs/s), which looks like
-- a bicycle. Below that speed the bike is shown in the pose it would have
-- turning at the same yaw rate at that speed: handlebar tan / q, lean
-- tan * q, with q = shown speed / real speed. MaxSpeedRatio = 1 turns it off.
config.Pose = {
	SteerLeanRatio = 1.15,
	-- Largest q; toward walking pace the pose blends back to the real one.
	MaxSpeedRatio = 2.5,
}

-- Riding pose of the avatar (looks only: the rider is massless and the
-- drag uses the rider silhouette in config.Aero). Points are in chassis
-- space (the frame part: X right, Y up, -Z forward) for the right side;
-- the left side mirrors them.
config.Rider = {
	-- Center of the right grip at straight handlebar (it turns with the
	-- handlebar), and the right footpeg.
	GripPosition = Vector3.new(0.99, 1.03, -1.32),
	PegPosition = Vector3.new(0.7, -0.65, 1.08),
	-- Where the hips sit, from the top center of the seat part: forward
	-- toward the tank and down onto the visible seat.
	SeatOffset = Vector3.new(0, -0.15, -0.35),
	-- The upper body leans forward until the grips are this share of the
	-- arm's length from the shoulders (elbows a little bent), within these
	-- limits (deg). Solved per avatar, so short and long arms both fit; arms
	-- too short for the grips at the largest lean reach toward them.
	ArmReach = 0.9,
	MinTorsoLean = 10,
	MaxTorsoLean = 60,
	-- Tuck: this much more forward lean (deg), growing from TuckSpeed to
	-- TuckFullSpeed (studs/s).
	TuckLean = 12,
	TuckSpeed = 70,
	TuckFullSpeed = 100,
	-- In a turn the upper body leans further in by this share of the bike's
	-- lean, and the head rolls back toward level by HeadLevel of it.
	BodyLean = 0.25,
	HeadLevel = 0.5,
	-- How fast the tuck follows speed changes (1/s).
	Response = 6,
}

-- Other players see each bike's handlebar, suspension, wheels and rider
-- pose from a small state the rider's client sends (BikeVisualSync).
config.Sync = {
	-- Packets per second from the rider (the server passes at most twice
	-- this many on).
	SendRate = 20,
	-- How fast the shown handlebar and suspension follow the packets (1/s).
	Response = 20,
	-- Seconds without packets before the bike is shown at rest.
	StaleTime = 0.5,
}

-- The rider's camera while riding (BikeCamera, run by BikeCameraClient).
-- Angles in degrees, distances in studs.
config.Camera = {
	-- false leaves the camera to Roblox while riding.
	Enabled = true,

	-- Chase view: looks at a point FocusHeight above the bike's center
	-- from Distance away, Pitch below the horizon. The mouse wheel (I / O)
	-- zooms between MinDistance and MaxDistance (within the place's
	-- Player.CameraMin/MaxZoomDistance); in past MinDistance is the helmet
	-- view.
	FocusHeight = 2.0,
	Distance = 12,
	MinDistance = 7,
	MaxDistance = 30,
	Pitch = 12,

	-- The camera trails the bike like a trailer on a hitch this long: its
	-- heading turns toward the bike's over this much travel, so in a turn
	-- of radius R the bike is seen HitchLength / R radians off its tail,
	-- at any speed. Slow or stopped, it still swings back behind the bike
	-- at RecenterRate (1/s). It turns no faster than MaxFollowRate (1/s),
	-- which keeps the chassis's quick twitches out of the view, and never
	-- lags the bike by more than MaxLag.
	HitchLength = 5,
	RecenterRate = 1.5,
	MaxFollowRate = 10,
	MaxLag = 70,
	-- The view tilts with the road's slope by this share, and with the
	-- bike's lean by LeanRoll of it (0 keeps the horizon level).
	SlopeFollow = 0.75,
	LeanRoll = 0.2,

	-- The camera hangs on a sprung boom: accelerating pushes it back,
	-- braking pulls it in, by a / (2 pi f)^2 at a steady acceleration a
	-- (about 0.75 studs at 0.3 g with these). It swings at most
	-- MaxBoomRatio of the distance.
	BoomFrequency = 1.4,
	BoomDampingRatio = 0.7,
	MaxBoomRatio = 0.3,

	-- Field of view at rest, and how much wider it is at the bike's top
	-- speed (from the gearing).
	FieldOfView = 70,
	SpeedFieldOfView = 12,

	-- Walls and terrain between the bike and the camera pull it in front
	-- of them, this far clear of them; once they are gone it eases back
	-- out at ZoomResponse (1/s). See-through parts, parts with CanCollide
	-- off and characters never do.
	CollisionRadius = 0.4,
	ZoomResponse = 6,

	-- Looking around: right mouse button drag (deg per pixel, times the
	-- player's own camera sensitivity), right stick (deg/s at full tilt)
	-- or a touch drag. The view swings back behind the bike LookReturnDelay
	-- seconds after the last input, at LookReturnRate (1/s).
	MouseSensitivity = 0.35,
	StickTurnRate = 200,
	LookReturnDelay = 1.5,
	LookReturnRate = 3,

	-- Helmet view (V / gamepad Y): from the rider's head, HelmetPitch
	-- below the bike's heading, rolling with the head (config.Rider.HeadLevel).
	HelmetPitch = 6,
	HelmetFieldOfView = 80,
}

config.Recovery = {
	-- A fallen or flipped chassis is lifted back upright.
	TriggerAngle = 70,
	TriggerTime = 0.5,
	ReleaseAngle = 15,
	TorqueRatio = 4,
	Responsiveness = 20,
	MaxAngularVelocity = 6,
}

-- Engine, centrifugal clutch and a manual sequential gearbox. The
-- engine is a rotating mass inside the solver: its torque curve, the
-- clutch friction and the gearing drive the rear wheel, so launch, shifts,
-- engine braking and the rev limiter all follow from the same equations.
-- Gear top speeds come from the rev limiter, the torque curve, drag and
-- rolling resistance; nothing caps them separately.
config.Drivetrain = {
	-- A high-revving inline four with a sports bike's rev range (idle 1700,
	-- limiter 14000), its power sized for this game's speeds.
	-- Engine torque curve at full throttle: { rpm, torque } points,
	-- interpolated linearly (a dyno table). Sized against this bike's weight
	-- in Roblox gravity: 1st gear pulls about 0.38 g (a steady climb of about
	-- 21 degrees) and the launch never lifts the front wheel. The torque
	-- stays flat from the peak to the limiter, so power keeps rising to the
	-- limiter: enough to pull the top gear (6th) to the limiter at about 120
	-- studs/s against drag and rolling resistance.
	TorqueCurve = {
		{ 1700, 4.57 },
		{ 4120, 5.68 },
		{ 6860, 6.56 },
		{ 10430, 7.29 },
		{ 12630, 7.29 },
		{ 14000, 7.29 },
	},
	-- The engine controller holds at least this speed while running.
	IdleRPM = 1700,
	-- Fuel cut. The top speed of each gear is where the engine hits it.
	RevLimitRPM = 14000,
	RedlineRPM = 13700,
	-- Rotating inertia of the engine, set by how long the free engine
	-- (neutral, full throttle) takes to rev from idle to the limiter (s).
	-- Through the gearing it adds effective mass, most in low gears (about
	-- 1.2 times the bike's mass in the short 1st, 15% in 2nd with this
	-- value).
	FreeRevTime = 0.26,
	-- Closed-throttle drag (pumping and friction) at the rev limit as a
	-- ratio of peak torque. A real sports-bike four is near 0.3 (losses
	-- of about 4 bar mean effective pressure at the limiter against 14 bar
	-- at peak torque); this one brakes twice as hard, as a big single
	-- would, for strong engine braking and quickly falling revs.
	EngineBrakeTorqueRatio = 0.6,
	-- Share of that drag that stays at any speed: pumping against the shut
	-- throttle (about a third of the losses at the limiter); the rest is
	-- friction, growing with rpm.
	EngineBrakePumpingShare = 0.35,
	Efficiency = 0.9,

	-- Centrifugal clutch: friction capacity grows with the square of
	-- engine speed, from zero at ClutchEngageRPM to full at ClutchLockRPM.
	-- At idle it is open (no creep, no stall). Opening the throttle makes
	-- it bite, and the bike launches with the engine held at the speed
	-- where clutch capacity meets engine torque.
	ClutchEngageRPM = 2750,
	ClutchLockRPM = 8250,
	-- Full capacity as a multiple of peak engine torque (> 1, so a fully
	-- engaged clutch does not slip under engine torque).
	ClutchCapacityRatio = 1.5,

	-- Six speeds, progressive like a real gearbox: the steps shrink toward
	-- the top (2.81, 1.56, 1.37, 1.15, 1.09), so each upshift at the
	-- limiter lands a little higher (about 5000, 8900, 10000, 12000, 12500
	-- rpm), where drag takes more of the power: above 96 studs/s the
	-- engine stays near its peak power. 1st is a short launch gear up to
	-- walking pace (a Roblox character's 16 studs/s); 2nd is long, from
	-- there to 45. On the big step into 2nd the centrifugal clutch slips
	-- for a moment and holds the engine near 6000 rpm, so it does not bog.
	-- Rev-limit speeds: 16 / 45 / 70 / 96 / 110 / 120 studs/s (a stud is
	-- 0.28 m, so studs/s is about km/h).
	GearRatios = { 5.319, 1.891, 1.216, 0.886, 0.774, 0.709 },
	-- Rev-limit speed of a gear = 14000 rpm * 2pi/60 * 1.125 / (ratio * 19.38).
	FinalDriveRatio = 19.38,

	-- Manual sequential gearbox, 1-N-2-3-4-5-6: the rider shifts with
	-- paddles (LeftShift up, RightShift down, both at once = neutral).
	-- Every shift is taken at once; a slipper clutch catches downshifts
	-- the road speed would over-rev. Gear when a ride starts (0 = neutral).
	StartGear = 0,
	-- Coming to a stop in gear with the throttle closed selects neutral, as
	-- a rider does (a gear picked while standing stays in). Out of neutral
	-- the rider shifts as always: down is 1st, up is 2nd; W alone only
	-- revs the engine.
	AutoNeutral = true,
	-- Reverse, for backing out of a tight spot: standing still in neutral
	-- with the throttle closed, holding the brake (S / L2) ReverseDelay
	-- seconds selects it. Then S is the throttle and W the brake; W, once
	-- the bike is nearly stopped, takes 1st (as does a paddle up). A real
	-- gear that makes ReverseTopSpeed (studs/s) at ReverseRevLimitRPM: in
	-- reverse the ride-by-wire throttle closes as the engine nears that
	-- speed and holds it there, far below the limiter, so backing up never
	-- revs out. 8750 rpm gears reverse like 1st (as most gearboxes do), so
	-- it pulls away and climbs like 1st. ReverseTopSpeed = 0: no reverse.
	ReverseDelay = 1.0,
	ReverseTopSpeed = 10,
	ReverseRevLimitRPM = 8750,
	-- Each shift opens the clutch for ShiftTime while the engine is
	-- rev-matched (ignition cut on upshifts, throttle blip on downshifts),
	-- selects the gear, then closes the clutch over ClutchEngageTime,
	-- carrying only the torque the rider asks for until the speeds match.
	ShiftTime = 0.1,
	ClutchEngageTime = 0.1,

	-- Traction control works on slip ratio relative to the rear tire's
	-- current peak slip (from the tire model), so it holds the tire near
	-- maximum grip on any surface, also while the wheel is in the air.
	TractionSlipReferenceSpeed = 4.0,
	TractionSlipStartRatio = 0.8,
	TractionSlipFullCutRatio = 2.0,
	TractionCutResponse = 35,
	TractionRecoveryResponse = 4,
}

config.Brakes = {
	-- Full brake (S / L2) works both brakes and decelerates the bike at
	-- this fraction of gravity on level ground. The split follows the load
	-- transfer for that deceleration (front share = (b + (a/g) h) / L), so
	-- both tires reach their grip limit together.
	MaxDeceleration = 0.3,
	-- Rear brake alone (B) at full input, fraction of gravity.
	RearDeceleration = 0.12,
	-- Lever and pedal: seconds from released to full pressure, and back.
	ApplyTime = 0.25,
	ReleaseTime = 0.1,

	-- Anti-lock: a brake may only use the grip the tire has at the target
	-- slip (read off the tire's force curve, within what the friction
	-- circle leaves beside cornering force) and lets go when the tire is
	-- past its peak, so the tires keep grip and steering.
	ABS = true,
	-- Target slip as a share of the tire's peak slip (just below the peak
	-- keeps the tire on the stable side of its force curve).
	ABSSlipRatio = 0.85,
	-- Below this speed (studs/s) the brakes simply hold the wheels.
	ABSMinimumSpeed = 3,

	-- The unridden bike's parking brake (both wheels):
	-- holding torque as a multiple of weight times wheel radius.
	ParkingCapacity = 2,
}

config.Engine = {
	AutoStartOnMount = true,
	StopOnDismount = true,
}

--[=[
	Engine sound (BikeSound, played on every client by BikeSoundClient).
	The clips are public Roblox Creator Store sounds. Each profile is one
	recorded engine; Profile picks the one that plays, the settings around
	it are shared.

	In a profile, Start/End pick a region of the file (s) and Level is the
	region's measured RMS level (dBFS), so the clips match before the
	loudness model applies. Loops are steady-rpm stretches of the
	recordings; RecordedRPM was measured from the exhaust pulses (a
	four-stroke cylinder fires once every two crank turns, so rpm = 120 *
	the engine-cycle frequency; 30 * the firing frequency of an even-firing
	four), and End is where the waveform lines up with Start within one
	engine cycle, so the loop has no seam. IdleRPM and RevLimitRPM are the
	recorded engine's speed at our Drivetrain.IdleRPM and at our rev
	limiter: our engine (1700-14000 rpm) sounds like the recorded one over
	that range (linear).
]=]
config.Sound = {
	Enabled = true,
	-- "YamahaR1", "HondaCBR600" or "KawasakiZ1R" (see Profiles).
	Profile = "YamahaR1",
	-- Clips are matched to this level (dBFS) before the loudness model.
	ReferenceLevel = -20,
	-- Loudness rise per tenfold engine speed (dB), measured in the Kawasaki
	-- recording: 26-37 dB between its idle and its steady revs.
	LoudnessSlope = 30,
	-- Cylinder charge with the throttle shut, as a share of a full one; the
	-- exhaust pulses scale with it (-9 dB off the throttle).
	ClosedThrottleCharge = 0.35,
	-- The charge follows the throttle over this many crank turns (the
	-- intake fills and empties).
	ChargeRevolutions = 2,
	-- Share of the real loudness range kept. A real engine is about 32 dB
	-- louder at the limiter with the throttle open than idling; keeping
	-- half leaves the idle audible next to other game sounds.
	DynamicRange = 0.5,
	-- Volume at the rev limiter with the throttle open (Roblox Sound volume).
	Volume = 1.2,
	-- Fuel-cut rev limiter: the engine slows this much (rpm) before fuel
	-- returns. The stutter rate follows from the engine's inertia, torque
	-- and drag (BikeSound.limiterCycle: 54 Hz, no fuel 60% of the time;
	-- the tremolo plays at most 20 Hz).
	LimiterHysteresisRPM = 400,
	-- Combustion dies out this fast when the engine is switched off (s).
	StopRelease = 0.04,
	-- Afterfire on the overrun: shutting the throttle at high revs after
	-- a spell of load leaves unburnt fuel that fires in the hot exhaust.
	-- The crackle plays when the throttle stays shut for PopDelay (s;
	-- longer than a shift's ignition cut) after at least PopLoadTime (s)
	-- of load, with the engine above PopRevShare of the limiter, with
	-- PopChance, at PopLevel dB against the engine at the limiter. The
	-- clip is a recorded car's: the client cuts its low end (the car's
	-- burble) and keeps the crackle.
	Pops = { SoundId = 1618282056, Start = 0.04, End = 0.875, Level = -16.6 },
	PopDelay = 0.15,
	PopLoadTime = 0.4,
	PopRevShare = 0.6,
	PopChance = 0.7,
	PopLevel = -6,
	-- It crackles only from PopMinGear up: neutral (revving in place), 1st
	-- and 2nd (pulling away, town speeds) and reverse stay clean.
	PopMinGear = 3,
	-- 3D: full volume within RollOffMinDistance (studs), then falling with
	-- 1 / distance, silent at RollOffMaxDistance.
	RollOffMinDistance = 8,
	RollOffMaxDistance = 500,

	Profiles = {
		-- Yamaha R1, a 1000 cc crossplane inline four: uneven firing (270-180-
		-- 90-180 degrees), so its pulses repeat once per engine cycle (rpm =
		-- 120 * the cycle frequency). Steady holds from 1670 to 12667 rpm
		-- (the 5555 and 12667 ones from the same recordings), the top one
		-- stretched to our limiter. These are uploads by players
		-- (cuteboyesan; the 4417 loop XenoCantFlying), not Roblox-licensed
		-- sounds: they may be taken down, and a bike for sale should not
		-- depend on them.
		YamahaR1 = {
			Name = "Yamaha R1",
			IdleRPM = 1670,
			RevLimitRPM = 14000,
			Loops = {
				{ SoundId = 92159748137553, Start = 2.4, End = 5.493, RecordedRPM = 1670, Level = -21.4 },
				{ SoundId = 136905482683111, Start = 0.8253, End = 6.0032, RecordedRPM = 4417, Level = -15.5 },
				{ SoundId = 103993484556013, Start = 0.3443, End = 2.6068, RecordedRPM = 5555, Level = -10.1 },
				{ SoundId = 117474155086057, Start = 0.5554, End = 6.749, RecordedRPM = 8099, Level = -17.7 },
				{ SoundId = 110452780345800, Start = 0.2569, End = 4.5576, RecordedRPM = 12667, Level = -9.9 },
			},
			-- "Yamaha R1 Startup": the catch and a moment of idle (about 1690 rpm).
			Start = { SoundId = 125245338350455, Start = 0.4, End = 2.195, Level = -16.9, Blend = 0.5 },
			-- A short shutdown from the same set as the top loop.
			Stop = { SoundId = 79874469763423, Start = 0, End = 0.58, Level = -11.1 },
		},
		-- Honda CBR 600, a 600 cc inline four like the R6. Its recordings
		-- reach about 7500 rpm; the steady stretches are the idle, a 4000
		-- rpm hold after the start and the tops of two blips (short loops).
		HondaCBR600 = {
			Name = "Honda CBR600",
			IdleRPM = 1158,
			RevLimitRPM = 7000,
			Loops = {
				{ SoundId = 9114818249, Start = 11.7065, End = 13.2485, RecordedRPM = 1158, Level = -22.3 },
				{ SoundId = 9114817875, Start = 6.8, End = 7.8777, RecordedRPM = 4007, Level = -20.7 },
				{ SoundId = 9114818278, Start = 11.5512, End = 11.8061, RecordedRPM = 5178, Level = -13.1 },
				{ SoundId = 9114818278, Start = 9.7956, End = 10.0664, RecordedRPM = 5759, Level = -10.4 },
			},
			-- Starter, catch and a moment of idle; the loops come in over its
			-- last Blend seconds.
			Start = { SoundId = 9114818092, Start = 0.05, End = 1.45, Level = -25.5, Blend = 0.4 },
			-- Last idle beats and the shutdown, from the idle loop's own recording.
			Stop = { SoundId = 9114818249, Start = 12.9, End = 14.05, Level = -23 },
		},
		-- Kawasaki Z1000 Z1-R, a 1000 cc inline four of the late seventies:
		-- deeper, with long steady revs between 3800 and 4900 rpm.
		KawasakiZ1R = {
			Name = "Kawasaki Z1-R",
			IdleRPM = 1054,
			RevLimitRPM = 6000,
			Loops = {
				{ SoundId = 9114896554, Start = 13.26, End = 14.2561, RecordedRPM = 1054, Level = -28.5 },
				{ SoundId = 9114895897, Start = 31.91, End = 33.4185, RecordedRPM = 3781, Level = -18.8 },
				{ SoundId = 9114895897, Start = 13.09, End = 15.0851, RecordedRPM = 4180, Level = -20.8 },
				{ SoundId = 9114895897, Start = 39.79, End = 41.2757, RecordedRPM = 4846, Level = -17.1 },
			},
			Start = { SoundId = 9114896953, Start = 0.15, End = 2.4, Level = -28, Blend = 0.6 },
			Stop = { SoundId = 9114896554, Start = 18.85, End = 19.6, Level = -28.5 },
		},
	},
}

-- The ride prompt on the seat (E / gamepad X, held).
config.Mount = {
	HoldDuration = 0.6,
	MaxActivationDistance = 8,
	RequiresLineOfSight = false,
	ActionText = "Ride",
	ObjectText = "MotoRig",
}

--[=[
	The rider's HUD (BikeDashboardClient), shown only to the player on this
	bike, drawn with plain GUI frames (no image assets):
	- bottom right, a tachometer after Forza Horizon's: a hairline ring
	  over a soft shadow with a tick every 1000 rpm and a number every 2000
	  to a little past the rev limiter (0-15 for this engine, so the needle
	  never hits the end), a red arc from RedZoneRPM, the needle's tip at
	  the rim; the gear in a ring in the middle (N green, R amber, red in the
	  red zone as the cue to shift up); ABS and TC lights; the speed in
	  large digits below.
	- bottom left (Hints), one tile per control with its key, for the
	  keyboard or the gamepad, whichever was used last; the tile the bike
	  needs now lights up in blue (engine off, neutral, the red zone).
	- on a touch screen (TouchControls), on-screen controls instead of the
	  tiles: the left thumb leans (drag left or right on the left part of
	  the screen) and shifts (buttons above it), the right thumb holds the
	  throttle or the brake; engine, neutral, view, look back and get off
	  on top. The meter moves to the top right.
]=]
config.Dashboard = {
	Enabled = true,
	-- "km/h", "mph" or "studs/s". A stud is 0.28 m (Roblox's avatar
	-- scale, the scale this bike is built to): 1 stud/s = 1.008 km/h.
	SpeedUnit = "km/h",
	StudLength = 0.28,
	-- Where the tachometer's red arc starts and the gear turns red, the cue
	-- to shift up (rpm). The engine still pulls to the limiter (14000): the
	-- rider has the top of the rev range to shift in, by ear.
	RedZoneRPM = 11000,
	-- The control tiles at the bottom left.
	Hints = true,
	-- On-screen controls on phones and tablets (even with Enabled false:
	-- without them a touch screen cannot ride). false leaves touch to the
	-- map, which can drive the bike through the same local attributes
	-- (BikeTouchThrottle and the rest, see BikeDashboardClient).
	TouchControls = true,
}

-- Development lines in the Output: each bike's rig when it is built, the
-- rider's drive state as it changes and suspension setup warnings. Off
-- for players; true while developing. (Failures always go to the Output.)
config.Diagnostics = {
	Enabled = false,
}

return config
