--!strict
-- InverseKinematicsSpec: in-Studio self-test. Pure-math cases run with no DataModel; DataModel cases
-- (added later) spawn a placeholder rig, solve, and clean up. Run via temporarily adding
-- `require(script.InverseKinematicsSpec).run()` to init.server.luau, build, reopen Studio, read Output.
-- Mirrors RigWorkbenchSpec / CameraRigSpec.

local IK = require(script.Parent.InverseKinematics)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function vClose(a: Vector3, b: Vector3, tol: number?): boolean
	return (a - b).Magnitude < (tol or 1e-3)
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("rotationBetween maps a onto b", function()
		local r = IK.rotationBetween(Vector3.new(1, 0, 0), Vector3.new(0, 1, 0))
		return vClose(r:VectorToWorldSpace(Vector3.new(1, 0, 0)), Vector3.new(0, 1, 0))
	end)

	add("rotationBetween of parallel vectors is identity", function()
		local r = IK.rotationBetween(Vector3.new(0, 2, 0), Vector3.new(0, 5, 0))
		return r == CFrame.identity
	end)

	add("rotationBetween of opposed vectors is a 180 flip", function()
		local r = IK.rotationBetween(Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0))
		return vClose(r:VectorToWorldSpace(Vector3.new(1, 0, 0)), Vector3.new(-1, 0, 0))
	end)

	add("transformForRotation rotates restFrame about its pivot", function()
		local restFrame = CFrame.new(0, 5, 0)
		local worldRot = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi / 2)
		local t = IK.transformForRotation(restFrame, worldRot)
		local posed = restFrame * t
		local expected = CFrame.new(0, 5, 0) * worldRot
		return vClose(posed.Position, expected.Position)
			and vClose(posed:VectorToWorldSpace(Vector3.new(1, 0, 0)), Vector3.new(0, 0, -1))
	end)

	add("forwardFrames reproduces a straight 2-link chain at rest", function()
		local links = {
			{ c0 = CFrame.new(0, 2, 0), c1 = CFrame.new(0, -2, 0) },
			{ c0 = CFrame.new(0, 2, 0), c1 = CFrame.new(0, -2, 0) },
		}
		local pre, eff =
			IK.forwardFrames(CFrame.identity, links, { CFrame.identity, CFrame.identity })
		return vClose(pre[1].Position, Vector3.new(0, 2, 0))
			and vClose(pre[2].Position, Vector3.new(0, 6, 0))
			and vClose(eff.Position, Vector3.new(0, 8, 0))
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
			print("[InverseKinematicsSpec] PASS " .. c.name)
		else
			warn("[InverseKinematicsSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[InverseKinematicsSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
