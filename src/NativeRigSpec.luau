--!strict
-- NativeRigSpec: in-Studio self-test for the PURE NativeRig data (JOINT_MAP + PALETTE). No spawn (that
-- yields/web). Run via temporarily adding `require(script.NativeRigSpec).run()` to init.server.luau.

local NativeRig = require(script.Parent.NativeRig)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local R15_PARTS = {
	HumanoidRootPart = true,
	LowerTorso = true,
	UpperTorso = true,
	Head = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
}

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("JOINT_MAP has 15 entries with unique joint names", function()
		local seen, n = {}, 0
		for _, j in NativeRig.JOINT_MAP do
			n += 1
			if seen[j[1]] then
				return false, "duplicate joint " .. j[1]
			end
			seen[j[1]] = true
		end
		return n == 15
	end)

	add("JOINT_MAP part names are all valid R15 parts", function()
		for _, j in NativeRig.JOINT_MAP do
			if not R15_PARTS[j[2]] then
				return false, "bad parent part " .. j[2]
			end
			if not R15_PARTS[j[3]] then
				return false, "bad child part " .. j[3]
			end
		end
		return true
	end)

	add("PALETTE has at least 16 colors", function()
		return #NativeRig.PALETTE >= 16
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
			print("[NativeRigSpec] PASS " .. c.name)
		else
			warn("[NativeRigSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[NativeRigSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
