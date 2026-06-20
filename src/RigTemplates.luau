--!strict
-- RigTemplates: blocky humanoid placeholder rig data for RigWorkbench.spawn. Parts are placed at
-- chosen positions; joint C0/C1 are computed from those positions (correct-by-construction), so we
-- never hand-author Roblox's exact matrices. Names follow the R6/R15 conventions so the spawned Model +
-- Humanoid is a valid rig.

local RigTemplates = {}

export type PartDef = { name: string, size: Vector3, pos: Vector3 }
export type JointDef = { name: string, part0: string, part1: string, pivot: Vector3, host: string }
export type Template = { parts: { PartDef }, joints: { JointDef } }

local V = Vector3.new

local r6: Template = {
	parts = {
		{ name = "HumanoidRootPart", size = V(2, 2, 1), pos = V(0, 3, 0) },
		{ name = "Torso", size = V(2, 2, 1), pos = V(0, 3, 0) },
		{ name = "Head", size = V(2, 1, 1), pos = V(0, 4.5, 0) },
		{ name = "Right Arm", size = V(1, 2, 1), pos = V(1.5, 3, 0) },
		{ name = "Left Arm", size = V(1, 2, 1), pos = V(-1.5, 3, 0) },
		{ name = "Right Leg", size = V(1, 2, 1), pos = V(0.5, 1, 0) },
		{ name = "Left Leg", size = V(1, 2, 1), pos = V(-0.5, 1, 0) },
	},
	joints = {
		{
			name = "RootJoint",
			part0 = "HumanoidRootPart",
			part1 = "Torso",
			pivot = V(0, 3, 0),
			host = "HumanoidRootPart",
		},
		{ name = "Neck", part0 = "Torso", part1 = "Head", pivot = V(0, 4, 0), host = "Torso" },
		{
			name = "Right Shoulder",
			part0 = "Torso",
			part1 = "Right Arm",
			pivot = V(1, 4, 0),
			host = "Torso",
		},
		{
			name = "Left Shoulder",
			part0 = "Torso",
			part1 = "Left Arm",
			pivot = V(-1, 4, 0),
			host = "Torso",
		},
		{
			name = "Right Hip",
			part0 = "Torso",
			part1 = "Right Leg",
			pivot = V(0.5, 2, 0),
			host = "Torso",
		},
		{
			name = "Left Hip",
			part0 = "Torso",
			part1 = "Left Leg",
			pivot = V(-0.5, 2, 0),
			host = "Torso",
		},
	},
}

local r15: Template = {
	parts = {
		{ name = "HumanoidRootPart", size = V(2, 2, 1), pos = V(0, 4, 0) },
		{ name = "LowerTorso", size = V(2, 0.8, 1), pos = V(0, 3.8, 0) },
		{ name = "UpperTorso", size = V(2, 1.6, 1), pos = V(0, 5.0, 0) },
		{ name = "Head", size = V(1.2, 1.2, 1.2), pos = V(0, 6.4, 0) },
		{ name = "RightUpperArm", size = V(1, 1.4, 1), pos = V(1.5, 4.9, 0) },
		{ name = "RightLowerArm", size = V(1, 1.2, 1), pos = V(1.5, 3.6, 0) },
		{ name = "RightHand", size = V(1, 0.8, 1), pos = V(1.5, 2.6, 0) },
		{ name = "LeftUpperArm", size = V(1, 1.4, 1), pos = V(-1.5, 4.9, 0) },
		{ name = "LeftLowerArm", size = V(1, 1.2, 1), pos = V(-1.5, 3.6, 0) },
		{ name = "LeftHand", size = V(1, 0.8, 1), pos = V(-1.5, 2.6, 0) },
		{ name = "RightUpperLeg", size = V(1, 1.4, 1), pos = V(0.5, 2.7, 0) },
		{ name = "RightLowerLeg", size = V(1, 1.4, 1), pos = V(0.5, 1.3, 0) },
		{ name = "RightFoot", size = V(1, 0.6, 1.2), pos = V(0.5, 0.3, 0) },
		{ name = "LeftUpperLeg", size = V(1, 1.4, 1), pos = V(-0.5, 2.7, 0) },
		{ name = "LeftLowerLeg", size = V(1, 1.4, 1), pos = V(-0.5, 1.3, 0) },
		{ name = "LeftFoot", size = V(1, 0.6, 1.2), pos = V(-0.5, 0.3, 0) },
	},
	joints = {
		{
			name = "Root",
			part0 = "HumanoidRootPart",
			part1 = "LowerTorso",
			pivot = V(0, 3.4, 0),
			host = "HumanoidRootPart",
		},
		{
			name = "Waist",
			part0 = "LowerTorso",
			part1 = "UpperTorso",
			pivot = V(0, 4.2, 0),
			host = "LowerTorso",
		},
		{
			name = "Neck",
			part0 = "UpperTorso",
			part1 = "Head",
			pivot = V(0, 5.8, 0),
			host = "UpperTorso",
		},
		{
			name = "RightShoulder",
			part0 = "UpperTorso",
			part1 = "RightUpperArm",
			pivot = V(1.0, 5.6, 0),
			host = "UpperTorso",
		},
		{
			name = "RightElbow",
			part0 = "RightUpperArm",
			part1 = "RightLowerArm",
			pivot = V(1.5, 4.2, 0),
			host = "RightUpperArm",
		},
		{
			name = "RightWrist",
			part0 = "RightLowerArm",
			part1 = "RightHand",
			pivot = V(1.5, 3.0, 0),
			host = "RightLowerArm",
		},
		{
			name = "LeftShoulder",
			part0 = "UpperTorso",
			part1 = "LeftUpperArm",
			pivot = V(-1.0, 5.6, 0),
			host = "UpperTorso",
		},
		{
			name = "LeftElbow",
			part0 = "LeftUpperArm",
			part1 = "LeftLowerArm",
			pivot = V(-1.5, 4.2, 0),
			host = "LeftUpperArm",
		},
		{
			name = "LeftWrist",
			part0 = "LeftLowerArm",
			part1 = "LeftHand",
			pivot = V(-1.5, 3.0, 0),
			host = "LeftLowerArm",
		},
		{
			name = "RightHip",
			part0 = "LowerTorso",
			part1 = "RightUpperLeg",
			pivot = V(0.5, 3.4, 0),
			host = "LowerTorso",
		},
		{
			name = "RightKnee",
			part0 = "RightUpperLeg",
			part1 = "RightLowerLeg",
			pivot = V(0.5, 2.0, 0),
			host = "RightUpperLeg",
		},
		{
			name = "RightAnkle",
			part0 = "RightLowerLeg",
			part1 = "RightFoot",
			pivot = V(0.5, 0.6, 0),
			host = "RightLowerLeg",
		},
		{
			name = "LeftHip",
			part0 = "LowerTorso",
			part1 = "LeftUpperLeg",
			pivot = V(-0.5, 3.4, 0),
			host = "LowerTorso",
		},
		{
			name = "LeftKnee",
			part0 = "LeftUpperLeg",
			part1 = "LeftLowerLeg",
			pivot = V(-0.5, 2.0, 0),
			host = "LeftUpperLeg",
		},
		{
			name = "LeftAnkle",
			part0 = "LeftLowerLeg",
			part1 = "LeftFoot",
			pivot = V(-0.5, 0.6, 0),
			host = "LeftLowerLeg",
		},
	},
}

local byName: { [string]: Template } = { r6 = r6, r15 = r15 }

-- Official Roblox rig asset ids (loaded via InsertService) — the NATIVE rig, preferred over the
-- programmatic placeholder. r15 = the official "R15 Block Rig". (r6 has no verified id yet → falls back
-- to the programmatic r6 template.)
local nativeAsset: { [string]: number } = { r15 = 16644810619 }

function RigTemplates.get(name: string): Template?
	return byName[string.lower(name)]
end

-- The native Roblox rig asset id for a type, or nil if none (use the programmatic template instead).
function RigTemplates.getNative(name: string): number?
	return nativeAsset[string.lower(name)]
end

return RigTemplates
