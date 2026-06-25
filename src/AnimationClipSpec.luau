--!strict
-- AnimationClipSpec: in-Studio self-test for the PURE AnimationClip logic (no spawn/web). Builds a tiny
-- synthetic Motor6D rig with Instance.new and asserts adjacency/rigRoot/buildPoseTree + normalizeTime.
-- Run via temporarily adding `require(script.AnimationClipSpec).run()` to init.server.luau.

local AnimationClip = require(script.Parent.AnimationClip)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

-- A 3-part chain: HumanoidRootPart -> LowerTorso (joint "Root") -> UpperTorso (joint "Waist").
local function miniRig(): Instance
	local model = Instance.new("Model")
	local function part(name: string): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Parent = model
		return p
	end
	local hrp = part("HumanoidRootPart")
	local lower = part("LowerTorso")
	local upper = part("UpperTorso")
	local function joint(name: string, p0: BasePart, p1: BasePart)
		local m = Instance.new("Motor6D")
		m.Name = name
		m.Part0 = p0
		m.Part1 = p1
		m.Parent = p0
	end
	joint("Root", hrp, lower)
	joint("Waist", lower, upper)
	return model
end

-- A branched rig to test joint-scoping: HRP -> LowerTorso -> { UpperTorso -> { RightUpperArm ->
-- RightLowerArm, LeftUpperArm }, RightUpperLeg }. The right arm + spine carriers should survive a
-- rightArm scope; the left arm + leg branches should be pruned.
local function branchedRig(): Instance
	local model = Instance.new("Model")
	local function part(name: string): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Parent = model
		return p
	end
	local hrp = part("HumanoidRootPart")
	local lower = part("LowerTorso")
	local upper = part("UpperTorso")
	local rua = part("RightUpperArm")
	local rla = part("RightLowerArm")
	local leftArm = part("LeftUpperArm")
	local rightLeg = part("RightUpperLeg")
	local function joint(name: string, p0: BasePart, p1: BasePart)
		local m = Instance.new("Motor6D")
		m.Name = name
		m.Part0 = p0
		m.Part1 = p1
		m.Parent = p0
	end
	joint("Root", hrp, lower)
	joint("Waist", lower, upper)
	joint("RightShoulder", upper, rua)
	joint("RightElbow", rua, rla)
	joint("LeftShoulder", upper, leftArm)
	joint("RightHip", lower, rightLeg)
	return model
end

local function findPose(root: Instance, name: string): Instance?
	if root.Name == name and root:IsA("Pose") then
		return root
	end
	for _, d in root:GetDescendants() do
		if d:IsA("Pose") and d.Name == name then
			return d
		end
	end
	return nil
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeTime rounds to ms and clamps negatives/NaN to 0", function()
		if math.abs(AnimationClip.normalizeTime(0.12345) - 0.123) > 1e-9 then
			return false, "round failed: " .. tostring(AnimationClip.normalizeTime(0.12345))
		end
		if AnimationClip.normalizeTime(-1) ~= 0 then
			return false, "negative not clamped"
		end
		if AnimationClip.normalizeTime(0 / 0) ~= 0 then
			return false, "NaN not clamped"
		end
		return true
	end)

	add("rigRoot returns HumanoidRootPart", function()
		local rig = miniRig()
		local root = AnimationClip.rigRoot(rig)
		if root == nil or root.Name ~= "HumanoidRootPart" then
			return false, "got " .. tostring(root and root.Name)
		end
		return true
	end)

	add("adjacency maps Part0 -> its Motor6Ds", function()
		local rig = miniRig()
		local adj = AnimationClip.adjacency(rig)
		local hrp = rig:FindFirstChild("HumanoidRootPart") :: Instance
		local lower = rig:FindFirstChild("LowerTorso") :: Instance
		if adj[hrp] == nil or #adj[hrp] ~= 1 or adj[hrp][1].Name ~= "Root" then
			return false, "HRP adjacency wrong"
		end
		if adj[lower] == nil or #adj[lower] ~= 1 or adj[lower][1].Name ~= "Waist" then
			return false, "LowerTorso adjacency wrong"
		end
		return true
	end)

	add("buildPoseTree nests poses by part name with the right CFrames", function()
		local rig = miniRig()
		local mark = CFrame.Angles(0, 0, math.rad(-90))
		local tree = AnimationClip.buildPoseTree(rig, { UpperTorso = mark })
		if tree == nil or tree.Name ~= "HumanoidRootPart" then
			return false, "root pose name wrong"
		end
		local lower = findPose(tree, "LowerTorso")
		local upper = findPose(tree, "UpperTorso")
		if lower == nil or upper == nil then
			return false, "missing child poses"
		end
		if upper.Parent ~= lower or lower.Parent ~= tree then
			return false, "pose nesting wrong"
		end
		if (lower :: Pose).CFrame ~= CFrame.identity then
			return false, "LowerTorso should be identity"
		end
		if (upper :: Pose).CFrame ~= mark then
			return false, "UpperTorso CFrame not applied"
		end
		return true
	end)

	add("scopedJointSet rightArm returns the right-arm parts; unknown errors", function()
		local names, err = AnimationClip.scopedJointSet("rightArm")
		if names == nil then
			return false, "rightArm returned nil: " .. tostring(err)
		end
		if #names ~= 3 then
			return false, "expected 3 names, got " .. tostring(#names)
		end
		local set: { [string]: boolean } = {}
		for _, n in names do
			set[n] = true
		end
		if not (set.RightUpperArm and set.RightLowerArm and set.RightHand) then
			return false, "missing an arm part"
		end
		local bad, berr = AnimationClip.scopedJointSet("nope")
		if bad ~= nil or berr == nil then
			return false, "unknown preset should error"
		end
		local upper, uerr = AnimationClip.scopedJointSet("upperBody")
		if upper == nil or #upper ~= 8 then
			return false, "upperBody should return 8 names: " .. tostring(uerr or #upper)
		end
		return true
	end)

	add("scopeIncludeSet adds ancestor carriers and omits siblings", function()
		local rig = branchedRig()
		local set = AnimationClip.scopeIncludeSet(rig, { "RightUpperArm", "RightLowerArm" })
		if not (set.RightUpperArm and set.RightLowerArm) then
			return false, "scoped parts missing"
		end
		if not (set.UpperTorso and set.LowerTorso and set.HumanoidRootPart) then
			return false, "ancestor carriers missing"
		end
		if set.LeftUpperArm or set.RightUpperLeg then
			return false, "a sibling branch leaked into the include set"
		end
		return true
	end)

	add("buildPoseTree with an includeSet prunes sibling branches", function()
		local rig = branchedRig()
		local set = AnimationClip.scopeIncludeSet(rig, { "RightUpperArm", "RightLowerArm" })
		local tree = AnimationClip.buildPoseTree(rig, {}, set)
		if tree == nil then
			return false, "no tree"
		end
		if findPose(tree, "RightLowerArm") == nil then
			return false, "scoped RightLowerArm pose missing"
		end
		if findPose(tree, "UpperTorso") == nil then
			return false, "carrier UpperTorso pose missing"
		end
		if findPose(tree, "LeftUpperArm") ~= nil then
			return false, "LeftUpperArm should be pruned"
		end
		if findPose(tree, "RightUpperLeg") ~= nil then
			return false, "RightUpperLeg should be pruned"
		end
		return true
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[AnimationClipSpec] PASS " .. c.name)
		else
			warn("[AnimationClipSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[AnimationClipSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
