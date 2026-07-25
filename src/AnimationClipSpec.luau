--!strict
-- AnimationClipSpec: in-Studio self-test for the PURE AnimationClip logic (no spawn/web). Builds a tiny
-- synthetic Motor6D rig with Instance.new and asserts adjacency/rigRoot/buildPoseTree + normalizeTime
-- / parsePoseBatch / scopedJointSet / buildScopedPoses / rotationDeltaDeg (the verify-after-apply metric).
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
-- RightLowerArm, LeftUpperArm }, RightUpperLeg }. A rightArm scope keys ONLY the right-arm chain;
-- the ancestor carriers (spine) AND the left-arm/leg branches are all omitted.
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
		if #names ~= 4 then
			return false, "expected 4 names, got " .. tostring(#names)
		end
		local set: { [string]: boolean } = {}
		for _, n in names do
			set[n] = true
		end
		if not (set.RightUpperArm and set.RightLowerArm and set.RightHand and set.Head) then
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

	add("parsePoseBatch parses a valid map name-sorted with missing axes = 0", function()
		local entries, err = AnimationClip.parsePoseBatch({
			RightShoulder = { z = 70 },
			AgentEditGrip = { x = 40 },
		})
		if entries == nil then
			return false, "valid map rejected: " .. tostring(err)
		end
		if #entries ~= 2 then
			return false, "expected 2 entries, got " .. tostring(#entries)
		end
		if entries[1].name ~= "AgentEditGrip" or entries[2].name ~= "RightShoulder" then
			return false, "entries not name-sorted: " .. entries[1].name .. ", " .. entries[2].name
		end
		if entries[1].x ~= 40 or entries[1].y ~= 0 or entries[1].z ~= 0 then
			return false, "AgentEditGrip axes wrong (missing axes should default to 0)"
		end
		if entries[2].z ~= 70 or entries[2].x ~= 0 or entries[2].y ~= 0 then
			return false, "RightShoulder axes wrong"
		end
		local empty, eerr = AnimationClip.parsePoseBatch({})
		if empty == nil or #empty ~= 0 then
			return false, "empty map should parse to {}: " .. tostring(eerr)
		end
		return true
	end)

	add("parsePoseBatch rejects malformed maps without partial results", function()
		local bad1, e1 = AnimationClip.parsePoseBatch({ RightShoulder = 70 })
		if bad1 ~= nil or e1 == nil then
			return false, "non-table entry should error"
		end
		if not string.find(e1 :: string, "RightShoulder", 1, true) then
			return false, "error should name the bad entry: " .. tostring(e1)
		end
		local bad2, e2 = AnimationClip.parsePoseBatch({ RightShoulder = { z = 0 / 0 } })
		if bad2 ~= nil or e2 == nil then
			return false, "NaN axis should error"
		end
		local bad3, e3 = AnimationClip.parsePoseBatch({ RightShoulder = { z = "70" } })
		if bad3 ~= nil or e3 == nil then
			return false, "string axis should error"
		end
		local bad4, e4 = AnimationClip.parsePoseBatch("nope")
		if bad4 ~= nil or e4 == nil then
			return false, "non-table poses should error"
		end
		return true
	end)

	add("rotationDeltaDeg measures the rotation angle, translation-blind + symmetric", function()
		local a = CFrame.Angles(math.rad(140), 0, 0)
		local b = CFrame.Angles(math.rad(143), 0, 0)
		local d = AnimationClip.rotationDeltaDeg(a, b)
		if math.abs(d - 3) > 0.01 then
			return false, "140 vs 143 about X should be 3 deg, got " .. tostring(d)
		end
		if AnimationClip.rotationDeltaDeg(a, a) > 1e-3 then
			return false, "identical rotations should be ~0"
		end
		-- translation must not count (Motor6D.Transform can carry position)
		local c = CFrame.new(5, -2, 7) * CFrame.Angles(0, math.rad(90), 0)
		local dyaw = AnimationClip.rotationDeltaDeg(CFrame.identity, c)
		if math.abs(dyaw - 90) > 0.01 then
			return false, "identity vs translated 90 deg yaw should be 90, got " .. tostring(dyaw)
		end
		if math.abs(AnimationClip.rotationDeltaDeg(c, CFrame.identity) - dyaw) > 1e-6 then
			return false, "delta should be symmetric"
		end
		return true
	end)

	add(
		"rotationDeltaDeg vs the 2deg verify tolerance: catches the live frozen-snapshot lie",
		function()
			-- the live repro: requested RightShoulder (-160, 0, 25) but the stale hold pose (37, 0, 0)
			-- was what got keyed — must be FAR outside tolerance
			local want = CFrame.Angles(math.rad(-160), 0, math.rad(25))
			local stale = CFrame.Angles(math.rad(37), 0, 0)
			local d = AnimationClip.rotationDeltaDeg(want, stale)
			if d <= 2 then
				return false,
					"stale 37 deg hold vs requested -160 deg should exceed 2 deg, got " .. tostring(
						d
					)
			end
			-- a near-exact apply must PASS the tolerance (no false alarms)
			local near = CFrame.Angles(math.rad(-159.2), 0, math.rad(25.4))
			local nd = AnimationClip.rotationDeltaDeg(want, near)
			if nd > 2 then
				return false,
					"a ~1 deg apply error should be within tolerance, got " .. tostring(nd)
			end
			return true
		end
	)

	add("weaponChildNames finds AgentEditGrip Part1 names only", function()
		local rig = branchedRig()
		-- no grip joint yet -> empty
		if #AnimationClip.weaponChildNames(rig) ~= 0 then
			return false, "expected no weapon names on a bare rig"
		end
		-- an AgentEditGrip Motor6D (RightLowerArm stands in for RightHand) -> its Part1 name
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Parent = rig
		local hand = rig:FindFirstChild("RightLowerArm") :: BasePart
		local grip = Instance.new("Motor6D")
		grip.Name = "AgentEditGrip"
		grip.Part0 = hand
		grip.Part1 = handle
		grip.Parent = hand
		local names = AnimationClip.weaponChildNames(rig)
		if #names ~= 1 or names[1] ~= "Handle" then
			return false, "expected {Handle}, got " .. tostring(names[1]) .. " (n=" .. #names .. ")"
		end
		-- a same-named joint with a nil Part1 is skipped
		grip.Part1 = nil
		if #AnimationClip.weaponChildNames(rig) ~= 0 then
			return false, "nil-Part1 grip joint should be skipped"
		end
		return true
	end)

	add("weaponChildNames walks the articulated chain from the grip's Part1", function()
		local rig = branchedRig()
		local function part(name: string): BasePart
			local p = Instance.new("Part")
			p.Name = name
			p.Parent = rig
			return p
		end
		local function joint(name: string, p0: BasePart, p1: BasePart)
			local m = Instance.new("Motor6D")
			m.Name = name
			m.Part0 = p0
			m.Part1 = p1
			m.Parent = p0
		end
		local handle = part("Handle")
		local segA = part("SegA")
		local segB = part("SegB")
		local hand = rig:FindFirstChild("RightLowerArm") :: BasePart
		joint("AgentEditGrip", hand, handle)
		joint("SegA", handle, segA)
		joint("SegB", segA, segB)
		local names = AnimationClip.weaponChildNames(rig)
		if #names ~= 3 or names[1] ~= "Handle" or names[2] ~= "SegA" or names[3] ~= "SegB" then
			return false, "expected {Handle, SegA, SegB}, got {" .. table.concat(names, ", ") .. "}"
		end
		-- body joints (the arm chain ABOVE the grip) must not leak into the weapon channel list
		for _, n in names do
			if n == "RightLowerArm" or n == "RightUpperArm" then
				return false, "body joint leaked into the weapon chain: " .. n
			end
		end
		return true
	end)

	add("weaponChildNames terminates on a pathological joint cycle", function()
		local rig = branchedRig()
		local function part(name: string): BasePart
			local p = Instance.new("Part")
			p.Name = name
			p.Parent = rig
			return p
		end
		local function joint(name: string, p0: BasePart, p1: BasePart)
			local m = Instance.new("Motor6D")
			m.Name = name
			m.Part0 = p0
			m.Part1 = p1
			m.Parent = p0
		end
		local handle = part("Handle")
		local segA = part("SegA")
		local hand = rig:FindFirstChild("RightLowerArm") :: BasePart
		joint("AgentEditGrip", hand, handle)
		joint("SegA", handle, segA)
		joint("CycleBack", segA, handle) -- Handle already seen; must neither loop nor duplicate
		local names = AnimationClip.weaponChildNames(rig)
		if #names ~= 2 or names[1] ~= "Handle" or names[2] ~= "SegA" then
			return false, "expected {Handle, SegA}, got {" .. table.concat(names, ", ") .. "}"
		end
		return true
	end)

	add(
		"buildScopedPoses includes the scoped chain + ancestor carriers, pruning siblings",
		function()
			local rig = branchedRig()
			local tops = AnimationClip.buildScopedPoses(
				rig,
				{},
				{ "RightUpperArm", "RightLowerArm" }
			)
			if #tops ~= 1 then
				return false, "expected a single root top, got " .. tostring(#tops)
			end
			local top = tops[1]
			if top.Name ~= "HumanoidRootPart" then
				return false, "the top should be the rig root HumanoidRootPart, got " .. top.Name
			end
			-- scoped joints present
			if findPose(top, "RightUpperArm") == nil or findPose(top, "RightLowerArm") == nil then
				return false, "scoped arm poses missing"
			end
			-- ancestor carriers present (so the clip plays via RegisterKeyframeSequence)
			if findPose(top, "UpperTorso") == nil or findPose(top, "LowerTorso") == nil then
				return false, "ancestor carrier poses missing"
			end
			-- sibling branches pruned
			if findPose(top, "LeftUpperArm") ~= nil or findPose(top, "RightUpperLeg") ~= nil then
				return false, "a sibling branch leaked in"
			end
			return true
		end
	)

	add("buildScopedPoses nests two scoped branches under their shared carrier", function()
		local rig = branchedRig()
		local tops = AnimationClip.buildScopedPoses(rig, {}, { "RightUpperArm", "LeftUpperArm" })
		if #tops ~= 1 then
			return false, "expected a single root top, got " .. tostring(#tops)
		end
		local top = tops[1]
		if findPose(top, "RightUpperArm") == nil or findPose(top, "LeftUpperArm") == nil then
			return false, "both scoped arms should be present"
		end
		if findPose(top, "UpperTorso") == nil then
			return false, "the shared UpperTorso carrier should be present"
		end
		if findPose(top, "RightUpperLeg") ~= nil then
			return false, "the leg branch should be pruned"
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
