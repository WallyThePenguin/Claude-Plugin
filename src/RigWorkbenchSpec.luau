--!strict
-- RigWorkbenchSpec: in-Studio self-test for the PURE RigWorkbench helpers (no DataModel). Run via
-- temporarily adding `require(script.RigWorkbenchSpec).run()` to init.server.luau, build, reopen Studio,
-- read Output. Mirrors CameraRigSpec.

local RigWorkbench = require(script.Parent.RigWorkbench)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function vClose(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < 1e-4
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("rotationCFrame(0,90,0) maps +X to -Z", function()
		local cf = RigWorkbench.rotationCFrame(0, 90, 0)
		return vClose(cf * Vector3.new(1, 0, 0), Vector3.new(0, 0, -1))
	end)

	add("rotationCFrame(0,0,0) is identity", function()
		return RigWorkbench.rotationCFrame(0, 0, 0) == CFrame.identity
	end)

	add("applyRotation absolute replaces; relative composes", function()
		local r90 = RigWorkbench.rotationCFrame(0, 90, 0)
		local abs = RigWorkbench.applyRotation(r90, r90, false) -- = r90 (90deg): +X -> -Z
		local rel = RigWorkbench.applyRotation(r90, r90, true) -- = 180deg: +X -> -X
		return vClose(abs * Vector3.new(1, 0, 0), Vector3.new(0, 0, -1))
			and vClose(rel * Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0))
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
			print("[RigWorkbenchSpec] PASS " .. c.name)
		else
			warn("[RigWorkbenchSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[RigWorkbenchSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
