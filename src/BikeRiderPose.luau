--[[
	BikeRiderPose

	Riding pose of the avatar on the bike. It only changes how the rider
	looks: the rider is massless and the drag uses a fixed rider silhouette
	(config.Aero), so the pose never changes the physics.

	Every physics frame, after the Animator has posed the avatar (sitting),
	the pose overrides the avatar's joint Transforms:
	  - the thighs rest on the seat, the pelvis tipped a little forward
	  - the upper body leans forward until the hands reach the grips with
	    the elbows slightly bent (solved once per avatar, so short and long
	    arms both fit), further in a tuck at speed, and a little further
	    into a turn than the bike
	  - the head looks ahead and stays more level than the bike
	  - the hands hold the grips and turn with the handlebar; the feet rest
	    on the pegs (or reach toward them as far as the legs go)
	Arms and legs are placed with two-bone inverse kinematics, so any R15
	avatar size fits. R6 limbs are one part each and point at the same
	targets.

	Poses are computed in chassis space (the bike's frame part), where the
	seat, grips and pegs are fixed, so the result rides along with the
	bike's motion and lean.
]]

local RiderPose = {}
RiderPose.__index = RiderPose

local UP = Vector3.yAxis
local RIGHT = Vector3.xAxis
local BACK = Vector3.zAxis
local EPSILON = 1e-6
-- Share of the forward lean taken by the pelvis; the waist bends the rest.
local PELVIS_LEAN_SHARE = 0.35
-- Share of the forward lean the head follows (the rest keeps it looking
-- ahead).
local HEAD_LEAN_SHARE = 0.2
-- The legs stretch to at most this share of their length.
local LEG_REACH = 0.97
local LEAN_SOLVE_STEPS = 24

-- Joints by the two body parts they join (parent part, child part).
local R15_JOINTS = {
	root = { "HumanoidRootPart", "LowerTorso" },
	waist = { "LowerTorso", "UpperTorso" },
	neck = { "UpperTorso", "Head" },
	leftShoulder = { "UpperTorso", "LeftUpperArm" },
	leftElbow = { "LeftUpperArm", "LeftLowerArm" },
	leftWrist = { "LeftLowerArm", "LeftHand" },
	rightShoulder = { "UpperTorso", "RightUpperArm" },
	rightElbow = { "RightUpperArm", "RightLowerArm" },
	rightWrist = { "RightLowerArm", "RightHand" },
	leftHip = { "LowerTorso", "LeftUpperLeg" },
	leftKnee = { "LeftUpperLeg", "LeftLowerLeg" },
	leftAnkle = { "LeftLowerLeg", "LeftFoot" },
	rightHip = { "LowerTorso", "RightUpperLeg" },
	rightKnee = { "RightUpperLeg", "RightLowerLeg" },
	rightAnkle = { "RightLowerLeg", "RightFoot" },
}

-- The same for R6 avatars (one part per limb).
local R6_JOINTS = {
	root = { "HumanoidRootPart", "Torso" },
	neck = { "Torso", "Head" },
	leftShoulder = { "Torso", "Left Arm" },
	rightShoulder = { "Torso", "Right Arm" },
	leftHip = { "Torso", "Left Leg" },
	rightHip = { "Torso", "Right Leg" },
}

-- 0 at edge0, 1 at edge1, with a smooth start and end.
local function smoothstep(edge0, edge1, value)
	local t = math.clamp((value - edge0) / math.max(edge1 - edge0, EPSILON), 0, 1)

	return t * t * (3 - 2 * t)
end

-- First-order lag toward target at response (1/s).
local function approach(current, target, response, deltaTime)
	return current + (target - current) * (1 - math.exp(-response * deltaTime))
end

-- The same point on the other side (x mirrored).
local function mirrored(point)
	return Vector3.new(-point.X, point.Y, point.Z)
end

-- Part pose (chassis space) that puts its local point `pivotLocal` at
-- `pivot` with the rotation `rotation`.
local function placed(pivot, rotation, pivotLocal)
	return CFrame.new(pivot) * rotation * CFrame.new(-pivotLocal)
end

-- Rotation that turns a part's bone (local vector from its joint toward
-- its far end) onto `bone`, with the part's X axis turned toward `side`.
local function boneRotation(boneLocal, bone, side)
	local localDown = boneLocal.Unit
	local localSide = (RIGHT - localDown * localDown.X).Unit
	local down = bone.Unit
	local worldSide = side - down * side:Dot(down)

	if worldSide.Magnitude < EPSILON then
		worldSide = RIGHT - down * down.X
	end

	return CFrame.fromMatrix(Vector3.zero, worldSide.Unit, -down)
		* CFrame.fromMatrix(Vector3.zero, localSide, -localDown):Inverse()
end

-- Two-bone chain from `root` toward `target` with bone lengths a and b,
-- bending toward `pole`. Returns the middle joint, the reached end, the
-- chain direction and the bend direction.
local function solveLimb(root, target, a, b, pole, reach)
	local offset = target - root
	local length = offset.Magnitude
	local direction = length > EPSILON and offset / length or -UP
	local distance = math.clamp(length, math.abs(a - b) + 1e-3, (a + b) * (reach or 1) - 1e-3)
	local bend = pole - direction * pole:Dot(direction)

	if bend.Magnitude < EPSILON then
		bend = direction:Cross(RIGHT)
	end

	bend = bend.Unit

	local cosine = math.clamp((a * a + distance * distance - b * b) / (2 * a * distance), -1, 1)
	local sine = math.sqrt(1 - cosine * cosine)

	return root + (direction * cosine + bend * sine) * a, root + direction * distance, direction, bend
end

-- A joint the pose can drive: a classic Motor6D, or the AnimationConstraint
-- the Avatar Joint Upgrade (StarterPlayer.AvatarJointUpgrade) puts in its
-- place, whose attachments play the part of C0 and C1. Both take
-- Part1 = Part0 * C0 * Transform * C1^-1.
local function jointRecord(object)
	if object:IsA("Motor6D") then
		if object.Part0 and object.Part1 then
			return { joint = object, part0 = object.Part0, part1 = object.Part1, c0 = object.C0, c1 = object.C1 }
		end
	elseif object:IsA("AnimationConstraint") then
		local attachment0 = object.Attachment0
		local attachment1 = object.Attachment1
		local part0 = attachment0 and attachment0.Parent
		local part1 = attachment1 and attachment1.Parent

		if part0 and part1 and part0:IsA("BasePart") and part1:IsA("BasePart") then
			return { joint = object, part0 = part0, part1 = part1, c0 = attachment0.CFrame, c1 = attachment1.CFrame }
		end
	end

	return nil
end

-- The avatar's joints by the parts they join (names and places of the
-- joint objects differ between rig kinds). Returns the joints, or nil and
-- the first joint not found.
local function findJoints(character, layout)
	local byParts = {}

	for _, descendant in character:GetDescendants() do
		local record = jointRecord(descendant)

		if record then
			byParts[record.part0.Name .. "/" .. record.part1.Name] = record
		end
	end

	local joints = {}

	for key, names in layout do
		local record = byParts[names[1] .. "/" .. names[2]]

		if record == nil then
			return nil, names[1] .. "-" .. names[2]
		end

		joints[key] = record
	end

	return joints
end

-- A two-bone limb: `first` joins it to the body, `second` is the middle
-- joint and `third` holds the hand or foot.
local function twoBoneLimb(first, second, third)
	local upperBone = second.c0.Position - first.c1.Position
	local lowerBone = third.c0.Position - second.c1.Position

	return {
		first = first,
		second = second,
		third = third,
		upperBone = upperBone,
		lowerBone = lowerBone,
		upperLength = upperBone.Magnitude,
		lowerLength = lowerBone.Magnitude,
	}
end

-- A one-part limb (R6): the bone runs from the joint to the far end.
local function onePartLimb(first)
	local part = first.part1

	return {
		first = first,
		bone = Vector3.new(0, -part.Size.Y * 0.5, 0) - first.c1.Position,
	}
end

-- A riding pose for one bike; attach() it to a character.
function RiderPose.new(config)
	return setmetatable({
		config = config.Rider,
		joints = nil,
		character = nil,
		tuck = 0,
	}, RiderPose)
end

--[=[
	Starts posing `character`, which sits on the bike `dynamics` drives.
	Returns true and a description of the rig, or false and the reason for
	a rig it does not know (the avatar then keeps its own sitting
	animation).
]=]
function RiderPose:attach(character, dynamics)
	self:detach()

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid == nil then
		return false, "no Humanoid"
	end

	local r15 = humanoid.RigType == Enum.HumanoidRigType.R15
	local joints, missing = findJoints(character, r15 and R15_JOINTS or R6_JOINTS)

	if joints == nil then
		return false, string.format("%s joint %s not found", r15 and "R15" or "R6", missing)
	end

	self.character = character
	self.joints = joints
	self.r15 = r15
	self.jointList = {}

	for _, record in joints do
		table.insert(self.jointList, record)
	end

	-- Body measures of this avatar.
	local hipMiddle = (joints.leftHip.c0.Position + joints.rightHip.c0.Position) * 0.5
	local thigh = joints.leftHip.part1.Size

	self.hipMiddle = hipMiddle
	-- The hips sit this high above the seat so the thighs rest on it.
	self.thighRadius = math.min(thigh.X, thigh.Z) * 0.5

	if r15 then
		self.arms = {
			left = twoBoneLimb(joints.leftShoulder, joints.leftElbow, joints.leftWrist),
			right = twoBoneLimb(joints.rightShoulder, joints.rightElbow, joints.rightWrist),
		}
		self.legs = {
			left = twoBoneLimb(joints.leftHip, joints.leftKnee, joints.leftAnkle),
			right = twoBoneLimb(joints.rightHip, joints.rightKnee, joints.rightAnkle),
		}

		local foot = joints.leftAnkle.part1

		-- Ankle above the sole, and the hand's center below the wrist.
		self.ankleHeight = joints.leftAnkle.c1.Position.Y + foot.Size.Y * 0.5
		self.handOffset = joints.leftWrist.c1.Position.Magnitude
		self.reach = (self.arms.right.upperLength + self.arms.right.lowerLength) * self.config.ArmReach
	else
		self.arms = { left = onePartLimb(joints.leftShoulder), right = onePartLimb(joints.rightShoulder) }
		self.legs = { left = onePartLimb(joints.leftHip), right = onePartLimb(joints.rightHip) }
		self.ankleHeight = 0
		self.handOffset = 0
		self.reach = self.arms.right.bone.Magnitude
	end

	self.baseLean = self:_solveLean(self:_seatPoint(dynamics), self.config.GripPosition)

	return true,
		string.format(
			"%s %s, lean %.0f deg",
			r15 and "R15" or "R6",
			joints.root.joint.ClassName,
			math.deg(self.baseLean)
		)
end

-- Puts the avatar back to its own animation.
function RiderPose:detach()
	if self.jointList then
		for _, record in self.jointList do
			if record.joint.Parent then
				record.joint.Transform = CFrame.identity
			end
		end
	end

	self.character = nil
	self.joints = nil
	self.jointList = nil
	self.tuck = 0
end

-- Where the hips sit: the seat's top center plus the configured offset,
-- in chassis space.
function RiderPose:_seatPoint(dynamics)
	local seat = dynamics.seat
	local seatTop = dynamics.frame.CFrame:ToObjectSpace(seat.CFrame * CFrame.new(0, seat.Size.Y * 0.5, 0))

	return seatTop.Position + self.config.SeatOffset
end

-- Pelvis and chest poses for a forward lean and a sideways body roll.
function RiderPose:_torso(seatPoint, lean, roll)
	local joints = self.joints
	local hips = seatPoint + UP * self.thighRadius

	if not self.r15 then
		local torso = placed(hips, CFrame.Angles(0, 0, roll) * CFrame.Angles(-lean, 0, 0), self.hipMiddle)

		return torso, torso
	end

	local pelvis = placed(
		hips,
		CFrame.Angles(0, 0, roll * PELVIS_LEAN_SHARE) * CFrame.Angles(-lean * PELVIS_LEAN_SHARE, 0, 0),
		self.hipMiddle
	)
	local chest = placed(
		pelvis * joints.waist.c0.Position,
		CFrame.Angles(0, 0, roll) * CFrame.Angles(-lean, 0, 0),
		joints.waist.c1.Position
	)

	return pelvis, chest
end

-- Forward lean that puts the shoulders the avatar's comfortable reach from
-- the grips (bisection: leaning further brings the shoulders closer).
function RiderPose:_solveLean(seatPoint, grip)
	local low = math.rad(self.config.MinTorsoLean)
	local high = math.rad(self.config.MaxTorsoLean)
	local shoulder = self.joints.rightShoulder

	for _ = 1, LEAN_SOLVE_STEPS do
		local lean = (low + high) * 0.5
		local _, chest = self:_torso(seatPoint, lean, 0)

		if ((chest * shoulder.c0.Position) - grip).Magnitude > self.reach then
			low = lean
		else
			high = lean
		end
	end

	return (low + high) * 0.5
end

-- Poses a two-bone limb (arm or leg) reaching from root toward target.
local function poseTwoBone(poses, limb, root, target, pole, bendsForward, endRotation)
	local middle, reached, direction, bend =
		solveLimb(root, target, limb.upperLength, limb.lowerLength, pole, bendsForward and 1 or LEG_REACH)
	-- The hinge axis: arms bend the forearm forward, legs the shin back.
	local side = bendsForward and bend:Cross(direction) or direction:Cross(bend)
	local lowerRotation = boneRotation(limb.lowerBone, reached - middle, side)

	poses[limb.first.part1] = placed(root, boneRotation(limb.upperBone, middle - root, side), limb.first.c1.Position)
	poses[limb.second.part1] = placed(middle, lowerRotation, limb.second.c1.Position)
	poses[limb.third.part1] = placed(reached, endRotation or lowerRotation, limb.third.c1.Position)
end

-- Poses a one-part limb (R6) pointing from root at target.
local function poseOnePart(poses, limb, root, target)
	poses[limb.first.part1] = placed(root, boneRotation(limb.bone, target - root, RIGHT), limb.first.c1.Position)
end

--[=[
	Poses the avatar for this frame. Call from PreSimulation, after
	dynamics:updateVisuals (the handlebar angle it shows is the one the
	hands follow).
]=]
function RiderPose:update(deltaTime, dynamics)
	local joints = self.joints

	if joints == nil then
		return
	end

	for _, record in self.jointList do
		if record.joint.Parent == nil then
			-- The avatar was rebuilt (appearance loaded): pose the new rig.
			if not self:attach(self.character, dynamics) then
				return
			end

			joints = self.joints

			break
		end
	end

	local config = self.config
	local chassis = dynamics.frame.CFrame
	local speed = math.abs(dynamics.state.forwardSpeed or 0)

	self.tuck =
		approach(self.tuck, smoothstep(config.TuckSpeed, config.TuckFullSpeed, speed), config.Response, deltaTime)

	-- The bike's lean as drawn (positive to the left).
	local bikeLean = math.asin(math.clamp(chassis.RightVector.Y, -1, 1))
	local lean = self.baseLean + math.rad(config.TuckLean) * self.tuck
	local roll = bikeLean * config.BodyLean
	local seatPoint = self:_seatPoint(dynamics)
	local pelvis, chest = self:_torso(seatPoint, lean, roll)
	local poses = {
		[joints.root.part0] = chassis:ToObjectSpace(joints.root.part0.CFrame),
		[joints.root.part1] = pelvis,
	}

	if self.r15 then
		poses[joints.waist.part1] = chest
	end

	-- Head: looks ahead and rolls back toward level.
	poses[joints.neck.part1] = placed(
		chest * joints.neck.c0.Position,
		CFrame.Angles(0, 0, -bikeLean * config.HeadLevel) * CFrame.Angles(-lean * HEAD_LEAN_SHARE, 0, 0),
		joints.neck.c1.Position
	)

	-- Grips turn with the handlebar shown.
	local steer = CFrame.new(dynamics.steerPivot)
		* CFrame.fromAxisAngle(dynamics.steerAxis, dynamics.displayHandlebar)
		* CFrame.new(-dynamics.steerPivot)

	for _, side in { "left", "right" } do
		local sign = side == "left" and -1 or 1
		local arm = self.arms[side]
		local leg = self.legs[side]
		local grip = steer * (side == "left" and mirrored(config.GripPosition) or config.GripPosition)
		local peg = side == "left" and mirrored(config.PegPosition) or config.PegPosition
		local shoulder = chest * arm.first.c0.Position
		local hip = pelvis * leg.first.c0.Position

		if self.r15 then
			-- The hand's center on the grip: the wrist sits above and behind it.
			local wrist = grip + (UP + BACK).Unit * self.handOffset

			poseTwoBone(poses, arm, shoulder, wrist, Vector3.new(0.6 * sign, -1, 0.3), true)
			poseTwoBone(
				poses,
				leg,
				hip,
				peg + UP * self.ankleHeight,
				Vector3.new(0.35 * sign, 0.2, -1),
				false,
				CFrame.identity
			)
		else
			poseOnePart(poses, arm, shoulder, grip)
			poseOnePart(poses, leg, hip, peg)
		end
	end

	for _, record in self.jointList do
		local pose0 = poses[record.part0]
		local pose1 = poses[record.part1]

		if pose0 and pose1 then
			record.joint.Transform = record.c0:Inverse() * pose0:Inverse() * pose1 * record.c1
		end
	end
end

return RiderPose
