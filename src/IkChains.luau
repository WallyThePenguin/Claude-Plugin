--!strict
-- IkChains: resolve a chain SPEC (a preset name, or an explicit effector+chainRoot pair) on a real rig
-- into the joint data the InverseKinematics solver consumes. Rig-type aware (R6 single-joint limbs vs
-- R15 2-bone limbs). poleDir is a per-limb hint (anchor-local) for the default elbow/knee direction.
-- The effector part is definitionally the last FK joint's Part1, so it is derived, not named.

local RigWorkbench = require(script.Parent.RigWorkbench)

local IkChains = {}

export type Resolved = {
	posedJoints: { Motor6D }, -- joints to WRITE (.Transform)
	fkJoints: { Motor6D }, -- full FK path root->effector (posed + any terminal locator joint)
	anchorPart: BasePart, -- posedJoints[1].Part0
	effectorPart: BasePart, -- the chain tip (fkJoints[#fkJoints].Part1)
	twoBone: boolean, -- exactly a 2-bone limb preset -> analytic solve
	poleDir: Vector3?, -- anchor-local default pole direction (nil = let the solver pick a perpendicular)
}

-- Preset = ordered posed joint names + the FK path (posed + terminal locator) + 2-bone flag + pole hint.
-- R15 limbs are 2-bone (shoulder/elbow to hand); R6 limbs are single-joint (CCD/aim).
type Preset = {
	posed: { string },
	fk: { string },
	twoBone: boolean,
	poleDir: Vector3?,
}

-- pole hints (anchor-local): arms bend back+down, legs (knees) forward+down. Signs verified in live test.
local ARM_POLE = Vector3.new(0, -0.5, 1)
local LEG_POLE = Vector3.new(0, -0.5, -1)

local R15: { [string]: Preset } = {
	rightarm = {
		posed = { "RightShoulder", "RightElbow" },
		fk = { "RightShoulder", "RightElbow", "RightWrist" },
		twoBone = true,
		poleDir = ARM_POLE,
	},
	leftarm = {
		posed = { "LeftShoulder", "LeftElbow" },
		fk = { "LeftShoulder", "LeftElbow", "LeftWrist" },
		twoBone = true,
		poleDir = ARM_POLE,
	},
	rightleg = {
		posed = { "RightHip", "RightKnee" },
		fk = { "RightHip", "RightKnee", "RightAnkle" },
		twoBone = true,
		poleDir = LEG_POLE,
	},
	leftleg = {
		posed = { "LeftHip", "LeftKnee" },
		fk = { "LeftHip", "LeftKnee", "LeftAnkle" },
		twoBone = true,
		poleDir = LEG_POLE,
	},
	spine = {
		posed = { "Root", "Waist", "Neck" },
		fk = { "Root", "Waist", "Neck" },
		twoBone = false,
		poleDir = nil,
	},
}

local R6: { [string]: Preset } = {
	rightarm = {
		posed = { "Right Shoulder" },
		fk = { "Right Shoulder" },
		twoBone = false,
		poleDir = nil,
	},
	leftarm = {
		posed = { "Left Shoulder" },
		fk = { "Left Shoulder" },
		twoBone = false,
		poleDir = nil,
	},
	rightleg = { posed = { "Right Hip" }, fk = { "Right Hip" }, twoBone = false, poleDir = nil },
	leftleg = { posed = { "Left Hip" }, fk = { "Left Hip" }, twoBone = false, poleDir = nil },
	spine = { posed = { "Neck" }, fk = { "Neck" }, twoBone = false, poleDir = nil },
}

-- R15 if it has the R15-only joints (RightShoulder / Waist), else R6.
function IkChains.detectRigType(rig: Instance): string
	if
		RigWorkbench.findJoint(rig, "RightShoulder") ~= nil
		or RigWorkbench.findJoint(rig, "Waist") ~= nil
	then
		return "r15"
	end
	return "r6"
end

function IkChains.presetNames(): { string }
	return { "RightArm", "LeftArm", "RightLeg", "LeftLeg", "Spine" }
end

-- Resolve a list of joint names to Motor6Ds (nil + error on the first miss).
local function joints(rig: Instance, names: { string }): ({ Motor6D }?, string?)
	local out: { Motor6D } = {}
	for _, name in names do
		local m = RigWorkbench.findJoint(rig, name)
		if m == nil then
			return nil, "missing joint '" .. name .. "'"
		end
		table.insert(out, m)
	end
	return out, nil
end

-- Walk Motor6D Part0 links from `effectorJointName` up to `rootJointName`, building the ordered
-- root->tip joint list. nil if they don't connect. (Used by the explicit fallback.)
local function explicitPath(
	rig: Instance,
	effectorJointName: string,
	rootJointName: string
): ({ Motor6D }?, string?)
	local effJoint = RigWorkbench.findJoint(rig, effectorJointName)
	local rootJoint = RigWorkbench.findJoint(rig, rootJointName)
	if effJoint == nil then
		return nil, "no joint named '" .. effectorJointName .. "'"
	end
	if rootJoint == nil then
		return nil, "no joint named '" .. rootJointName .. "'"
	end
	local chain: { Motor6D } = {}
	local cursor: Motor6D? = effJoint
	for _ = 1, 64 do
		if cursor == nil then
			break
		end
		table.insert(chain, 1, cursor)
		if cursor == rootJoint then
			return chain, nil
		end
		local part0 = cursor.Part0
		local found: Motor6D? = nil
		for _, m in RigWorkbench.jointsOf(rig) do
			if m.Part1 == part0 then
				found = m
				break
			end
		end
		cursor = found
	end
	return nil,
		"'" .. rootJointName .. "' is not an ancestor joint of '" .. effectorJointName .. "'"
end

-- spec.chain = preset name; OR spec.effector + spec.chainRoot = explicit joint names.
function IkChains.resolveChain(
	rig: Instance,
	spec: { chain: string?, effector: string?, chainRoot: string? }
): (Resolved?, string?)
	if type(spec.chain) == "string" and spec.chain ~= "" then
		local presets = if IkChains.detectRigType(rig) == "r15" then R15 else R6
		local preset = presets[string.lower(spec.chain)]
		if preset == nil then
			return nil,
				"unknown chain '" .. spec.chain .. "'. Presets: " .. table.concat(
					IkChains.presetNames(),
					", "
				)
		end
		local posed, perr = joints(rig, preset.posed)
		if posed == nil then
			return nil, "chain '" .. spec.chain .. "': " .. tostring(perr)
		end
		local fk, ferr = joints(rig, preset.fk)
		if fk == nil then
			return nil, "chain '" .. spec.chain .. "': " .. tostring(ferr)
		end
		local effectorPart = fk[#fk].Part1
		local anchor = posed[1].Part0
		if effectorPart == nil or not effectorPart:IsA("BasePart") then
			return nil, "chain '" .. spec.chain .. "' has no effector part"
		end
		if anchor == nil or not anchor:IsA("BasePart") then
			return nil, "chain '" .. spec.chain .. "' has no anchor part"
		end
		return {
			posedJoints = posed,
			fkJoints = fk,
			anchorPart = anchor :: BasePart,
			effectorPart = effectorPart :: BasePart,
			twoBone = preset.twoBone,
			poleDir = preset.poleDir,
		},
			nil
	end

	if type(spec.effector) == "string" and type(spec.chainRoot) == "string" then
		local path, err = explicitPath(rig, spec.effector, spec.chainRoot)
		if path == nil then
			return nil, err
		end
		local effectorPart = path[#path].Part1
		local anchor = path[1].Part0
		if
			effectorPart == nil
			or not effectorPart:IsA("BasePart")
			or anchor == nil
			or not anchor:IsA("BasePart")
		then
			return nil, "explicit chain has a missing or non-part Part0/Part1"
		end
		return {
			posedJoints = path,
			fkJoints = path,
			anchorPart = anchor :: BasePart,
			effectorPart = effectorPart :: BasePart,
			twoBone = false, -- explicit chains use CCD (general)
			poleDir = nil,
		},
			nil
	end

	return nil, "ik_reach needs either chain=<preset> or effector=<joint> + chainRoot=<joint>"
end

return IkChains
