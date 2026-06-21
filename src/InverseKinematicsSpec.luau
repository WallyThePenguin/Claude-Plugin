--!strict
-- InverseKinematicsSpec: in-Studio self-test. Pure-math cases run with no DataModel; DataModel cases
-- (added later) spawn a placeholder rig, solve, and clean up. Run via temporarily adding
-- `require(script.InverseKinematicsSpec).run()` to init.server.luau, build, reopen Studio, read Output.
-- Mirrors RigWorkbenchSpec / CameraRigSpec.

local IK = require(script.Parent.InverseKinematics)
local RigWorkbench = require(script.Parent.RigWorkbench)
local IkChains = require(script.Parent.IkChains)

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

	add("solve2Bone places the effector at a reachable target", function()
		local root = Vector3.new(0, 10, 0)
		local target = Vector3.new(3, 8, 0)
		local s = IK.solve2Bone(root, 2, 2, target, Vector3.new(3, 8, 5))
		local effector = s.elbowPos + s.lowerDir * 2
		return vClose(effector, target) and not s.clamped
	end)

	add("solve2Bone clamps an out-of-reach target and straightens", function()
		local root = Vector3.new(0, 10, 0)
		local target = Vector3.new(0, 0, 0) -- 10 studs away; max reach 4
		local s = IK.solve2Bone(root, 2, 2, target, Vector3.new(1, 5, 0))
		return s.clamped and vClose(s.upperDir, s.lowerDir, 1e-2)
	end)

	add("solve2Bone pole flips the elbow side", function()
		local root = Vector3.new(0, 10, 0)
		local target = Vector3.new(0, 7, 0)
		local front = IK.solve2Bone(root, 2, 2, target, Vector3.new(0, 8.5, 5))
		local back = IK.solve2Bone(root, 2, 2, target, Vector3.new(0, 8.5, -5))
		return front.elbowPos.Z > 0.1 and back.elbowPos.Z < -0.1
	end)

	add("solve2BoneTransforms lands the effector on target (via FK)", function()
		local links = {
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) }, -- shoulder -> upper (len 2)
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) }, -- elbow -> lower (len 2)
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, 0, 0) }, -- wrist (terminal, identity)
		}
		local target = Vector3.new(3, -2, 0)
		local transforms =
			IK.solve2BoneTransforms(CFrame.identity, links, target, Vector3.new(3, -2, 5))
		local full = { transforms[1], transforms[2], CFrame.identity }
		local _, eff = IK.forwardFrames(CFrame.identity, links, full)
		return vClose(eff.Position, target, 1e-2)
	end)

	add("solveCCD converges a 3-link chain onto a reachable target", function()
		local links = {
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) },
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) },
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) },
		}
		local start = { CFrame.identity, CFrame.identity, CFrame.identity }
		local target = Vector3.new(4, -3, 0) -- within 6-stud reach
		local transforms = IK.solveCCDTransforms(CFrame.identity, links, start, target, 20)
		local _, eff = IK.forwardFrames(CFrame.identity, links, transforms)
		return vClose(eff.Position, target, 5e-2)
	end)

	add("resolveChain RightArm on a spawned r15 returns shoulder+elbow", function()
		local rig = RigWorkbench.spawn("r15")
		if rig == nil then
			return false, "spawn failed"
		end
		local resolved, err = IkChains.resolveChain(rig, { chain = "RightArm" })
		rig:Destroy()
		if resolved == nil then
			return false, err
		end
		return #resolved.posedJoints == 2
			and resolved.posedJoints[1].Name == "RightShoulder"
			and resolved.posedJoints[2].Name == "RightElbow"
			and resolved.effectorPart.Name == "RightHand"
			and resolved.twoBone == true
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
