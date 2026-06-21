# IK Grab-and-Place (Slice B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ik_reach` tool that poses a Motor6D rig so a named chain's end-effector reaches a world point or a part — a hybrid IK solver (analytic 2-bone for limbs, CCD for spine/custom) writing `Motor6D.Transform`, live in edit.

**Architecture:** A PURE solver module (`src/InverseKinematics.luau`) does all CFrame math on lists of `{c0, c1}` joint offsets + an anchor CFrame — fully unit-testable. `src/IkChains.luau` resolves a preset name (or explicit effector+chainRoot) on a real rig into the joint list the solver consumes. `src/Tools/Ik.luau` is the thin `ik_reach` descriptor. Everything mirrors slice A (`RigWorkbench`/`RigTemplates`/`Tools/Rig`): pure helpers + a thin DataModel method (`reach`) that writes `.Transform` inside a `ChangeHistoryService` recording.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin, rojo build, selene, stylua. **No local Luau execution** — verification is `selene`/`stylua`/`rojo build` + the in-Studio `InverseKinematicsSpec` (run by the user after a Studio restart) + a live grab-and-place test. The TDD steps below write the spec case (the test) alongside the code; the red→green is observed in-Studio, and locally we gate on the static suite.

**Source of truth:** the design spec [`docs/superpowers/specs/2026-06-21-studio-agent-ik-grab-and-place-design.md`](../specs/2026-06-21-studio-agent-ik-grab-and-place-design.md).

---

## File structure

| File | New/Mod | Responsibility |
|---|---|---|
| `src/InverseKinematics.luau` | new | PURE solver: `rotationBetween`, `transformForRotation`, `forwardFrames`, `solve2Bone`, `solve2BoneTransforms`, `solveCCDTransforms` + the thin DataModel `reach(rig, resolved, targetPos, poleHint?)`. |
| `src/IkChains.luau` | new | `detectRigType(rig)`, preset chain tables (R6/R15), `resolveChain(rig, spec)` → `{ posedJoints, fkJoints, anchorPart, effectorPart, twoBone, poleDir }` or `(nil, err)`. |
| `src/InverseKinematicsSpec.luau` | new | In-Studio self-test (mirrors `RigWorkbenchSpec`): pure-math cases + DataModel cases (resolveChain + reach on a spawned r15). |
| `src/Tools/Ik.luau` | new | The `ik_reach` descriptor; `resolveRig` (path or selection) like `Tools/Rig.luau`. |
| `src/Tools/init.luau` | mod | Register `IkTool.descriptors` (require + append loop). |
| `src/SystemPrompt.luau` | mod | Add `ik_reach` to the tool-list line + the "# Rigs & posing" section. |
| `src/Relay.luau` | none | **No change** — `ik_reach` is absent from `LOCAL_TOOLS`, so `shouldRelayTool` relays it by default (like `pose_joint`). Task 6 verifies this. |

### Solver math reference (derived; the implementation must match)

A `Motor6D` drives `Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()`. The joint's **pre-transform world frame** is `restFrame = Part0World * C0`; a pure-rotation `Transform` rotates the sub-chain about `restFrame.Position` without moving that pivot.

- **`transformForRotation(restFrame, worldRot)` = `restFrame.Rotation:Inverse() * worldRot * restFrame.Rotation`.** This is the world rotation `worldRot` (about the joint pivot) expressed in the joint's local basis. Composing a new rotation onto an existing transform is `newTransform = transformForRotation(restFrame, worldRot) * oldTransform` (left-multiply; derivation: `restFrame * (TFR * oldT) = rotateAboutPivot(worldRot) * (restFrame * oldT)`).
- **Forward kinematics** is computed analytically from the anchor + static `C0`/`C1` — NEVER by reading posed part CFrames back (avoids depending on synchronous engine joint resolution within one tool call). The anchor (chain root's `Part0`, e.g. the torso) is read once.
- **2-bone:** law of cosines gives the elbow angle; place the elbow in the plane of `(target-root)` and the pole; rotate upper bone then lower bone, root-first.

---

## Task 1: Pure rotation/frame helpers + spec scaffold

**Files:**
- Create: `src/InverseKinematics.luau`
- Create: `src/InverseKinematicsSpec.luau`

- [ ] **Step 1: Write `src/InverseKinematics.luau` with the three core helpers**

```lua
--!strict
-- InverseKinematics: PURE IK solver for Motor6D chains. All math operates on an anchor CFrame + a list
-- of {c0, c1} joint offsets (the static rig data) + a list of per-joint Transforms — no DataModel reads,
-- so it is fully unit-testable and never depends on the engine resolving joints synchronously. The thin
-- `reach` method (Task 5) marshals a real rig's Motor6Ds into these pure calls and writes the result to
-- Motor6D.Transform (the channel slice A poses live in edit) inside a ChangeHistory recording.
-- Hybrid: analytic 2-bone for limbs (pole vector), CCD for spine / R6 single-joint / custom chains.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local IK = {}

export type Link = { c0: CFrame, c1: CFrame }
export type Solve2Bone = { elbowPos: Vector3, upperDir: Vector3, lowerDir: Vector3, clamped: boolean }

local EPS = 1e-4

-- World rotation CFrame that maps direction a onto direction b (about the origin). Identity if either
-- is degenerate or already aligned; a 180-degree flip about an arbitrary perpendicular when opposed.
function IK.rotationBetween(a: Vector3, b: Vector3): CFrame
	if a.Magnitude < 1e-6 or b.Magnitude < 1e-6 then
		return CFrame.identity
	end
	local ua, ub = a.Unit, b.Unit
	local dot = math.clamp(ua:Dot(ub), -1, 1)
	if dot > 0.999999 then
		return CFrame.identity
	end
	if dot < -0.999999 then
		local axis = ua:Cross(Vector3.new(1, 0, 0))
		if axis.Magnitude < 1e-3 then
			axis = ua:Cross(Vector3.new(0, 1, 0))
		end
		return CFrame.fromAxisAngle(axis.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(ua:Cross(ub).Unit, math.acos(dot))
end

-- The local-frame Transform that, right-multiplied onto restFrame, rotates the sub-chain by worldRot
-- about the joint pivot. To compose onto an existing transform: TFR(restFrame, worldRot) * oldTransform.
function IK.transformForRotation(restFrame: CFrame, worldRot: CFrame): CFrame
	local r = restFrame.Rotation
	return r:Inverse() * worldRot * r
end

-- Forward kinematics. Returns the PRE-transform world frame of every joint (Part0World*c0, with the
-- transforms of joints ABOVE it applied but its own transform NOT) and the final effector part world
-- (last link's Part1). anchorCF = links[1]'s Part0 world.
function IK.forwardFrames(anchorCF: CFrame, links: { Link }, transforms: { CFrame }): ({ CFrame }, CFrame)
	local preFrames: { CFrame } = table.create(#links)
	local part0World = anchorCF
	for i, link in links do
		local jointFrame = part0World * link.c0
		preFrames[i] = jointFrame
		local t = transforms[i] or CFrame.identity
		part0World = (jointFrame * t) * link.c1:Inverse()
	end
	return preFrames, part0World
end

return IK
```

- [ ] **Step 2: Write `src/InverseKinematicsSpec.luau` with cases for these helpers**

```lua
--!strict
-- InverseKinematicsSpec: in-Studio self-test. Pure-math cases run with no DataModel; DataModel cases
-- (Tasks 4-5) spawn a placeholder rig, solve, and clean up. Run via temporarily adding
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
		-- A joint frame 5 studs up, no rotation; rotate its forward (+X here) by 90deg about Y.
		local restFrame = CFrame.new(0, 5, 0)
		local worldRot = CFrame.fromAxisAngle(Vector3.new(0, 1, 0), math.pi / 2)
		local t = IK.transformForRotation(restFrame, worldRot)
		local posed = restFrame * t
		-- posed should be restFrame rotated by worldRot about its position (which is the origin-Y axis).
		local expected = CFrame.new(0, 5, 0) * worldRot
		return vClose(posed.Position, expected.Position)
			and vClose(posed:VectorToWorldSpace(Vector3.new(1, 0, 0)), Vector3.new(0, 0, -1))
	end)

	add("forwardFrames reproduces a straight 2-link chain at rest", function()
		-- Anchor at origin; link1 c0 puts joint at +Y2 with c1 dropping the part by 2; link2 similar.
		local links = {
			{ c0 = CFrame.new(0, 2, 0), c1 = CFrame.new(0, -2, 0) },
			{ c0 = CFrame.new(0, 2, 0), c1 = CFrame.new(0, -2, 0) },
		}
		local pre, eff = IK.forwardFrames(CFrame.identity, links, { CFrame.identity, CFrame.identity })
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
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua reports no diff; rojo build succeeds (writes `StudioAgent.rbxm`).
(The spec cases themselves run in Studio — see Task 8. Locally we only gate on the static suite.)

- [ ] **Step 4: Commit**

```bash
git add src/InverseKinematics.luau src/InverseKinematicsSpec.luau
git commit -m "feat: IK pure helpers (rotationBetween/transformForRotation/forwardFrames) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Analytic 2-bone solver

**Files:**
- Modify: `src/InverseKinematics.luau` (add `solve2Bone` + `solve2BoneTransforms` before `return IK`)
- Modify: `src/InverseKinematicsSpec.luau` (add cases in `buildCases`)

- [ ] **Step 1: Add `solve2Bone` (geometric) and `solve2BoneTransforms` (returns the two joint Transforms)**

Insert into `src/InverseKinematics.luau` immediately before `return IK`:

```lua
-- Geometric 2-bone solve in world space. Returns the elbow position, the upper/lower bone directions,
-- and whether the target was clamped to the reachable range. l1 = root->mid, l2 = mid->effector.
function IK.solve2Bone(
	rootPos: Vector3,
	l1: number,
	l2: number,
	targetPos: Vector3,
	poleHint: Vector3
): Solve2Bone
	local toTarget = targetPos - rootPos
	local dist = toTarget.Magnitude
	local clamped = false
	local minReach = math.abs(l1 - l2) + 1e-3
	local maxReach = l1 + l2 - 1e-3
	local d = dist
	if d < minReach then
		d, clamped = minReach, true
	elseif d > maxReach then
		d, clamped = maxReach, true
	end
	local dir = if dist > EPS then toTarget.Unit else Vector3.new(0, -1, 0)
	local clampedTarget = rootPos + dir * d
	-- angle at the root between the upper bone and the line to the (clamped) target
	local cosA = math.clamp((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
	local a = math.acos(cosA)
	-- in-plane perpendicular to dir, pointing toward the pole (decides elbow/knee direction)
	local poleVec = poleHint - rootPos
	local perp = poleVec - dir * poleVec:Dot(dir)
	if perp.Magnitude < EPS then
		perp = dir:Cross(Vector3.new(0, 1, 0))
		if perp.Magnitude < EPS then
			perp = dir:Cross(Vector3.new(1, 0, 0))
		end
	end
	perp = perp.Unit
	local upperDir = (dir * math.cos(a) + perp * math.sin(a)).Unit
	local elbowPos = rootPos + upperDir * l1
	local lowerVec = clampedTarget - elbowPos
	local lowerDir = if lowerVec.Magnitude > EPS then lowerVec.Unit else dir
	return { elbowPos = elbowPos, upperDir = upperDir, lowerDir = lowerDir, clamped = clamped }
end

-- Solve a 2-bone limb and return the Transforms for the FIRST TWO links (shoulder, elbow). `links` may
-- include a trailing terminal joint (e.g. the wrist) used only to locate the effector part — it is kept
-- at identity. Root-first: solve the upper bone, recompute the elbow frame via FK, then the lower bone.
function IK.solve2BoneTransforms(
	anchorCF: CFrame,
	links: { Link },
	targetPos: Vector3,
	poleHint: Vector3
): ({ CFrame }, boolean)
	local identityT: { CFrame } = table.create(#links, CFrame.identity)
	local restFrames, effectorRest = IK.forwardFrames(anchorCF, links, identityT)
	local rootPos = restFrames[1].Position
	local elbowRestPos = restFrames[2].Position
	local l1 = (elbowRestPos - rootPos).Magnitude
	local l2 = (effectorRest.Position - elbowRestPos).Magnitude
	local restUpperDir = (elbowRestPos - rootPos).Unit
	local solve = IK.solve2Bone(rootPos, l1, l2, targetPos, poleHint)

	local worldRotUpper = IK.rotationBetween(restUpperDir, solve.upperDir)
	local t1 = IK.transformForRotation(restFrames[1], worldRotUpper)

	local afterT1: { CFrame } = table.clone(identityT)
	afterT1[1] = t1
	local frames2, effector2 = IK.forwardFrames(anchorCF, links, afterT1)
	local elbowPos2 = frames2[2].Position
	local currentLowerDir = (effector2.Position - elbowPos2).Unit
	local worldRotLower = IK.rotationBetween(currentLowerDir, solve.lowerDir)
	local t2 = IK.transformForRotation(frames2[2], worldRotLower)

	return { t1, t2 }, solve.clamped
end
```

- [ ] **Step 2: Add spec cases (insert in `buildCases` before `return cases`)**

```lua
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
		-- straightened: upper and lower nearly colinear toward the target
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
		-- straight-down 2-link arm (+ identity wrist link) from an anchor at the origin
		local links = {
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) }, -- shoulder -> upper (len 2)
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, -2, 0) }, -- elbow -> lower (len 2)
			{ c0 = CFrame.new(0, 0, 0), c1 = CFrame.new(0, 0, 0) }, -- wrist (terminal, identity)
		}
		local target = Vector3.new(3, -2, 0)
		local transforms = IK.solve2BoneTransforms(CFrame.identity, links, target, Vector3.new(3, -2, 5))
		local full = { transforms[1], transforms[2], CFrame.identity }
		local _, eff = IK.forwardFrames(CFrame.identity, links, full)
		return vClose(eff.Position, target, 1e-2)
	end)
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/InverseKinematics.luau src/InverseKinematicsSpec.luau
git commit -m "feat: analytic 2-bone IK solver + spec cases" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: CCD solver (spine / single-joint / custom chains)

**Files:**
- Modify: `src/InverseKinematics.luau` (add `solveCCDTransforms` before `return IK`)
- Modify: `src/InverseKinematicsSpec.luau` (add a case)

- [ ] **Step 1: Add `solveCCDTransforms`**

Insert into `src/InverseKinematics.luau` immediately before `return IK`:

```lua
-- Cyclic Coordinate Descent. Poses ALL links (effector = last link's Part1). Iterates tip->root,
-- rotating each joint so the effector swings toward the target, composing onto the running transforms.
-- Returns the per-joint Transforms. Computes FK analytically each sub-step (no posed-CFrame read-back).
function IK.solveCCDTransforms(
	anchorCF: CFrame,
	links: { Link },
	startTransforms: { CFrame },
	targetPos: Vector3,
	iterations: number
): { CFrame }
	local n = #links
	local transforms: { CFrame } = table.clone(startTransforms)
	for _ = 1, iterations do
		for i = n, 1, -1 do
			local preFrames, effectorWorld = IK.forwardFrames(anchorCF, links, transforms)
			local pivot = preFrames[i].Position
			local toEff = effectorWorld.Position - pivot
			local toTgt = targetPos - pivot
			if toEff.Magnitude > EPS and toTgt.Magnitude > EPS then
				local r = IK.rotationBetween(toEff, toTgt)
				transforms[i] = IK.transformForRotation(preFrames[i], r) * transforms[i]
			end
		end
		local _, eff = IK.forwardFrames(anchorCF, links, transforms)
		if (eff.Position - targetPos).Magnitude < 1e-2 then
			break
		end
	end
	return transforms
end
```

- [ ] **Step 2: Add a spec case (insert in `buildCases` before `return cases`)**

```lua
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
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/InverseKinematics.luau src/InverseKinematicsSpec.luau
git commit -m "feat: CCD IK solver for spine/custom chains + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Chain resolution (`IkChains.luau`)

**Files:**
- Create: `src/IkChains.luau`
- Modify: `src/InverseKinematicsSpec.luau` (add a DataModel case)

- [ ] **Step 1: Write `src/IkChains.luau`**

```lua
--!strict
-- IkChains: resolve a chain SPEC (a preset name, or an explicit effector+chainRoot pair) on a real rig
-- into the joint data the InverseKinematics solver consumes. Rig-type aware (R6 single-joint limbs vs
-- R15 2-bone limbs). poleDir is a per-limb hint (anchor-local) for the default elbow/knee direction.

local RigWorkbench = require(script.Parent.RigWorkbench)

local IkChains = {}

export type Resolved = {
	posedJoints: { Motor6D }, -- joints to WRITE (.Transform)
	fkJoints: { Motor6D }, -- full FK path root->effector (posed + any terminal locator joint)
	anchorPart: BasePart, -- posedJoints[1].Part0
	effectorPart: BasePart, -- the chain tip
	twoBone: boolean, -- exactly a 2-bone limb preset -> analytic solve
	poleDir: Vector3?, -- anchor-local default pole direction (nil = let the solver pick a perpendicular)
}

-- Preset = ordered posed joint names + the FK path (posed + terminal) + effector part + 2-bone flag +
-- pole hint. R15 limbs are 2-bone (shoulder/elbow to hand); R6 limbs are single-joint (CCD/aim).
type Preset = {
	posed: { string },
	fk: { string },
	effector: string,
	twoBone: boolean,
	poleDir: Vector3?,
}

-- pole hints (anchor-local): arms bend back+down, legs (knees) forward+down. Signs verified in live test.
local ARM_POLE = Vector3.new(0, -0.5, 1)
local LEG_POLE = Vector3.new(0, -0.5, -1)

local R15: { [string]: Preset } = {
	rightarm = { posed = { "RightShoulder", "RightElbow" }, fk = { "RightShoulder", "RightElbow", "RightWrist" }, effector = "RightHand", twoBone = true, poleDir = ARM_POLE },
	leftarm = { posed = { "LeftShoulder", "LeftElbow" }, fk = { "LeftShoulder", "LeftElbow", "LeftWrist" }, effector = "LeftHand", twoBone = true, poleDir = ARM_POLE },
	rightleg = { posed = { "RightHip", "RightKnee" }, fk = { "RightHip", "RightKnee", "RightAnkle" }, effector = "RightFoot", twoBone = true, poleDir = LEG_POLE },
	leftleg = { posed = { "LeftHip", "LeftKnee" }, fk = { "LeftHip", "LeftKnee", "LeftAnkle" }, effector = "LeftFoot", twoBone = true, poleDir = LEG_POLE },
	spine = { posed = { "Root", "Waist", "Neck" }, fk = { "Root", "Waist", "Neck" }, effector = "Head", twoBone = false, poleDir = nil },
}

local R6: { [string]: Preset } = {
	rightarm = { posed = { "Right Shoulder" }, fk = { "Right Shoulder" }, effector = "Right Arm", twoBone = false, poleDir = nil },
	leftarm = { posed = { "Left Shoulder" }, fk = { "Left Shoulder" }, effector = "Left Arm", twoBone = false, poleDir = nil },
	rightleg = { posed = { "Right Hip" }, fk = { "Right Hip" }, effector = "Right Leg", twoBone = false, poleDir = nil },
	leftleg = { posed = { "Left Hip" }, fk = { "Left Hip" }, effector = "Left Leg", twoBone = false, poleDir = nil },
	spine = { posed = { "Neck" }, fk = { "Neck" }, effector = "Head", twoBone = false, poleDir = nil },
}

-- R15 if it has the R15-only joints (RightShoulder etc.), else R6.
function IkChains.detectRigType(rig: Instance): string
	if RigWorkbench.findJoint(rig, "RightShoulder") ~= nil or RigWorkbench.findJoint(rig, "Waist") ~= nil then
		return "r15"
	end
	return "r6"
end

function IkChains.presetNames(): { string }
	return { "RightArm", "LeftArm", "RightLeg", "LeftLeg", "Spine" }
end

-- Walk Motor6D Part0 links from a joint named `effectorJointName`'s Part1 up to `rootJointName`, building
-- the ordered root->tip joint list. Returns nil if they don't connect. (Used by the explicit fallback.)
local function explicitPath(rig: Instance, effectorJointName: string, rootJointName: string): ({ Motor6D }?, string?)
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
		-- the joint whose Part1 is THIS joint's Part0 (one step toward the root)
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
	return nil, "'" .. rootJointName .. "' is not an ancestor joint of '" .. effectorJointName .. "'"
end

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

-- spec.chain = preset name; OR spec.effector + spec.chainRoot = explicit joint names.
function IkChains.resolveChain(rig: Instance, spec: { chain: string?, effector: string?, chainRoot: string? }): (Resolved?, string?)
	if type(spec.chain) == "string" and spec.chain ~= "" then
		local table_ = if IkChains.detectRigType(rig) == "r15" then R15 else R6
		local preset = table_[string.lower(spec.chain)]
		if preset == nil then
			return nil, "unknown chain '" .. spec.chain .. "'. Presets: " .. table.concat(IkChains.presetNames(), ", ")
		end
		local posed = (joints(rig, preset.posed))
		local fk = (joints(rig, preset.fk))
		if posed == nil or fk == nil then
			return nil, "rig is missing a joint for chain '" .. spec.chain .. "'"
		end
		local effectorPart = (fk[#fk].Part1 :: BasePart?)
		if string.lower(spec.chain) ~= "" then
			local ep = rig:FindFirstChild(preset.effector, true)
			if ep ~= nil and ep:IsA("BasePart") then
				effectorPart = ep
			end
		end
		if effectorPart == nil then
			return nil, "chain '" .. spec.chain .. "' has no effector part"
		end
		return {
			posedJoints = posed,
			fkJoints = fk,
			anchorPart = posed[1].Part0 :: BasePart,
			effectorPart = effectorPart,
			twoBone = preset.twoBone,
			poleDir = preset.poleDir,
		}, nil
	end

	if type(spec.effector) == "string" and type(spec.chainRoot) == "string" then
		local path, err = explicitPath(rig, spec.effector, spec.chainRoot)
		if path == nil then
			return nil, err
		end
		local effectorPart = (path[#path].Part1 :: BasePart?)
		if effectorPart == nil or path[1].Part0 == nil then
			return nil, "explicit chain has a missing Part0/Part1"
		end
		return {
			posedJoints = path,
			fkJoints = path,
			anchorPart = path[1].Part0 :: BasePart,
			effectorPart = effectorPart,
			twoBone = false, -- explicit chains use CCD (general); pass a pole only matters for 2-bone presets
			poleDir = nil,
		}, nil
	end

	return nil, "ik_reach needs either chain=<preset> or effector=<joint> + chainRoot=<joint>"
end

return IkChains
```

- [ ] **Step 2: Add a DataModel spec case (insert in `buildCases`, requires `RigWorkbench` + `IkChains`)**

At the top of `src/InverseKinematicsSpec.luau`, add after the existing `IK` require:

```lua
local RigWorkbench = require(script.Parent.RigWorkbench)
local IkChains = require(script.Parent.IkChains)
local Workspace = game:GetService("Workspace")
```

Then add this case in `buildCases`:

```lua
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
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/IkChains.luau src/InverseKinematicsSpec.luau
git commit -m "feat: IK chain resolution (presets + explicit fallback) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: The `reach` DataModel method

**Files:**
- Modify: `src/InverseKinematics.luau` (add `reach` + recording helpers before `return IK`)
- Modify: `src/InverseKinematicsSpec.luau` (add an end-to-end DataModel case)

- [ ] **Step 1: Add the recording helpers + `reach` to `src/InverseKinematics.luau`**

Insert immediately before `return IK` (mirrors `RigWorkbench`'s `beginRecording`/`finishRecording`/`redrawIfShown`):

```lua
local SKELETON_FOLDER = "__StudioAgentRigSkeleton"

local function beginRecording(name: string): string?
	if RunService:IsEdit() then
		return ChangeHistoryService:TryBeginRecording(name)
	end
	return nil
end

local function finishRecording(rid: string?, commit: boolean)
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if commit then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
end

-- Resolve the target point: a world Vector3, or a part's position. (caller passes one.)
function IK.targetPoint(targetVec: Vector3?, targetPart: BasePart?): Vector3?
	if targetPart ~= nil then
		return targetPart.Position
	end
	return targetVec
end

-- The default pole world point for a 2-bone limb: the rest elbow position pushed out along the
-- anchor-local poleDir hint. nil poleDir -> a far point so solve2Bone falls back to a perpendicular.
local function defaultPole(anchorCF: CFrame, elbowRestPos: Vector3, poleDir: Vector3?): Vector3
	if poleDir == nil then
		return elbowRestPos + Vector3.new(0, 0, 1000)
	end
	return elbowRestPos + anchorCF:VectorToWorldSpace(poleDir) * 2
end

-- Pose `resolved` so its effector reaches targetPos. Writes Motor6D.Transform in one recording, redraws
-- the skeleton if shown. Returns (clamped, residualStuds).
function IK.reach(rig: Instance, resolved: any, targetPos: Vector3, poleOverride: Vector3?): (boolean, number)
	local fk = resolved.fkJoints :: { Motor6D }
	local anchorCF = (resolved.anchorPart :: BasePart).CFrame
	local links: { Link } = {}
	for _, m in fk do
		table.insert(links, { c0 = m.C0, c1 = m.C1 })
	end

	local transforms: { CFrame }
	local clamped = false
	if resolved.twoBone then
		local identityT: { CFrame } = table.create(#links, CFrame.identity)
		local restFrames = IK.forwardFrames(anchorCF, links, identityT)
		local pole = poleOverride or defaultPole(anchorCF, restFrames[2].Position, resolved.poleDir)
		transforms, clamped = IK.solve2BoneTransforms(anchorCF, links, targetPos, pole)
	else
		local startT: { CFrame } = table.create(#links, CFrame.identity)
		transforms = IK.solveCCDTransforms(anchorCF, links, startT, targetPos, 12)
	end

	local rid = beginRecording("IK reach")
	for i, m in fk do
		m.Transform = transforms[i] or CFrame.identity
	end
	finishRecording(rid, true)

	if Workspace:FindFirstChild(SKELETON_FOLDER) ~= nil then
		RigWorkbench.drawSkeleton(rig)
	end

	local _, effWorld = IK.forwardFrames(anchorCF, links, transforms)
	return clamped, (effWorld.Position - targetPos).Magnitude
end
```

At the top of `src/InverseKinematics.luau`, add the `RigWorkbench` require (needed for `drawSkeleton`):

```lua
local RigWorkbench = require(script.Parent.RigWorkbench)
```

- [ ] **Step 2: Add an end-to-end DataModel spec case (in `buildCases`)**

```lua
	add("reach RightArm lands the right hand near a reachable target (r15)", function()
		local rig = RigWorkbench.spawn("r15")
		if rig == nil then
			return false, "spawn failed"
		end
		local resolved = IkChains.resolveChain(rig, { chain = "RightArm" })
		if resolved == nil then
			rig:Destroy()
			return false, "resolve failed"
		end
		-- a point ~1.5 studs in front of the right shoulder, within arm reach
		local shoulder = resolved.posedJoints[1]
		local shoulderPos = (shoulder.Part0.CFrame * shoulder.C0).Position
		local target = shoulderPos + Vector3.new(0.5, -0.5, 1)
		local _, residual = IK.reach(rig, resolved, target, nil)
		local hand = (resolved.effectorPart :: BasePart).Position
		rig:Destroy()
		return residual < 0.5, ("residual=%.3f hand=%s"):format(residual, tostring(hand))
	end)
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/InverseKinematics.luau src/InverseKinematicsSpec.luau
git commit -m "feat: IK reach method (write Transforms + ChangeHistory) + end-to-end spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: The `ik_reach` tool + registry wiring

**Files:**
- Create: `src/Tools/Ik.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Ik.luau`**

```lua
--!strict
-- IK tool: ik_reach. Thin wrapper over the stateless InverseKinematics + IkChains modules. A DataModel
-- edit (writes Motor6D.Transform) -> destructive + undoable + relayed in client-view (NOT in
-- Relay.LOCAL_TOOLS). resolveRig: a dot path, or the current Studio selection (like Tools/Rig.luau).

local Selection = game:GetService("Selection")

local InverseKinematics = require(script.Parent.Parent.InverseKinematics)
local IkChains = require(script.Parent.Parent.IkChains)
local Path = require(script.Parent.Path)

local Ik = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function resolveRig(target: any): (Instance?, string?)
	if type(target) == "string" and target ~= "" then
		return Path.resolve(target)
	end
	local sel = Selection:Get()
	if #sel > 0 then
		return sel[1], nil
	end
	return nil, "no rig given and nothing selected — pass a rig path or select the rig."
end

local function vec(t: any): Vector3?
	if type(t) ~= "table" then
		return nil
	end
	local x = if type(t.x) == "number" then t.x else 0
	local y = if type(t.y) == "number" then t.y else 0
	local z = if type(t.z) == "number" then t.z else 0
	return Vector3.new(x, y, z)
end

local function runReach(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "ik_reach: " .. tostring(err), true
	end

	local resolved, rerr = IkChains.resolveChain(rig, {
		chain = if type(args.chain) == "string" then args.chain else nil,
		effector = if type(args.effector) == "string" then args.effector else nil,
		chainRoot = if type(args.chainRoot) == "string" then args.chainRoot else nil,
	})
	if resolved == nil then
		return "ik_reach: " .. tostring(rerr), true
	end

	-- target: world point OR a part path
	local targetPos: Vector3?
	if type(args.targetPart) == "string" and args.targetPart ~= "" then
		local part, perr = Path.resolve(args.targetPart)
		if part == nil then
			return "ik_reach targetPart: " .. tostring(perr), true
		end
		if not part:IsA("BasePart") then
			return "ik_reach targetPart must be a BasePart, got " .. part.ClassName, true
		end
		targetPos = part.Position
	else
		targetPos = vec(args.target)
	end
	if targetPos == nil then
		return "ik_reach needs target = {x,y,z} OR targetPart = <path to a BasePart>", true
	end

	local pole = vec(args.pole)
	local clamped, residual = InverseKinematics.reach(rig, resolved, targetPos, pole)

	local names: { string } = {}
	for _, m in resolved.posedJoints do
		table.insert(names, m.Name)
	end
	local note = string.format(
		"ik_reach: posed %s [%s] -> (%.1f, %.1f, %.1f); residual %.2f studs%s",
		resolved.effectorPart.Name,
		table.concat(names, ", "),
		targetPos.X,
		targetPos.Y,
		targetPos.Z,
		residual,
		if clamped then " (target out of reach — limb straightened)" else ""
	)
	return note, false
end

Ik.descriptors = {
	{
		name = "ik_reach",
		description = "INVERSE KINEMATICS: pose a rig so a limb's end reaches a point. Give a chain + a "
			.. "target and the solver rotates the whole chain (sets Motor6D.Transform, live in edit) — you "
			.. "don't compute joint angles. chain = a preset: RightArm / LeftArm / RightLeg / LeftLeg / "
			.. "Spine (R6+R15 aware); OR effector + chainRoot joint names for a custom rig. target = "
			.. "{x,y,z} world point, OR targetPart = a path to a part to reach toward. pole = optional "
			.. "{x,y,z} the elbow/knee points toward. Out-of-reach targets straighten the limb. Use "
			.. "get_rig to see joints and camera_focus/camera_orbit to inspect the result.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				chain = {
					type = "string",
					description = "Preset: RightArm, LeftArm, RightLeg, LeftLeg, or Spine.",
				},
				effector = {
					type = "string",
					description = "Custom chains: the tip joint name (use with chainRoot instead of chain).",
				},
				chainRoot = {
					type = "string",
					description = "Custom chains: the root joint name (an ancestor of effector).",
				},
				target = {
					type = "object",
					description = "World point to reach: { x, y, z }.",
					properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } },
				},
				targetPart = {
					type = "string",
					description = "Path to a BasePart to reach toward (alternative to target).",
				},
				pole = {
					type = "object",
					description = "Optional world point the elbow/knee points toward: { x, y, z }.",
					properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } },
				},
			},
		},
		destructive = true,
		run = runReach,
	},
} :: { Descriptor }

return Ik
```

- [ ] **Step 2: Register the tool in `src/Tools/init.luau`**

Add the require alongside the other tool requires (after line `local RigTool = require(script.Rig)`):

```lua
local IkTool = require(script.Ik)
```

Add the append loop after the `RigTool` loop (after the `for _, descriptor in RigTool.descriptors ... end` block):

```lua
for _, descriptor in IkTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Verify the relay default (no edit needed)**

Confirm `ik_reach` is NOT present in `src/Relay.luau`'s `LOCAL_TOOLS` table (it isn't — only `update_tasks`/`remember`/`forget`/skills are). `Relay.shouldRelayTool("ik_reach")` therefore returns `true`, so the tool relays to the server copy in client-view like `pose_joint`. No `Relay.luau` change.

Run: `grep -n "ik_reach" src/Relay.luau` → expected: no matches.

- [ ] **Step 4: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/Tools/Ik.luau src/Tools/init.luau
git commit -m "feat: ik_reach tool + registry wiring" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: SystemPrompt documentation

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add `ik_reach` to the tool-list line**

Find the line (≈line 31):

```
- spawn_rig / get_rig / pose_joint / reset_pose / show_skeleton: spawn, see, and pose a rig's joints — see "Rigs & posing".
```

Replace it with:

```
- spawn_rig / get_rig / pose_joint / reset_pose / show_skeleton / ik_reach: spawn, see, pose, and IK a rig's joints — see "Rigs & posing".
```

- [ ] **Step 2: Extend the "# Rigs & posing" section with an IK sentence**

Find the "# Rigs & posing" section body (the paragraph starting "To work with a character/creature rig:"). Append, at the END of that paragraph (before the blank line that precedes "# Inspecting visually"):

```
 For GRAB-AND-PLACE posing, ik_reach(rig, chain, target|targetPart, pole?) rotates a whole chain so its end reaches a point — chain is a preset (RightArm/LeftArm/RightLeg/LeftLeg/Spine) or an explicit effector+chainRoot for a custom rig; target is {x,y,z} or a part path. Out-of-reach targets straighten the limb; pass pole to control which way the elbow/knee bends. Prefer ik_reach over hand-rotating each joint when you want a hand or foot AT a position.
```

- [ ] **Step 3: Static-verify**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua clean; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "docs: document ik_reach in SystemPrompt (Rigs & posing)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Full verification + live-test protocol

**Files:** none (verification only)

- [ ] **Step 1: Full static suite**

Run: `selene src ; stylua --check src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: selene `0 errors, 0 warnings`; stylua reports no diff; rojo build writes `StudioAgent.rbxm`.

- [ ] **Step 2: Adversarial review of the solver logic (cannot run Luau here)**

Because the IK math can't be executed locally, run a `code-review` / Workflow adversarial pass over `src/InverseKinematics.luau` + `src/IkChains.luau` focused on: the `transformForRotation` left-multiply order in CCD, the root-first `solve2BoneTransforms` FK recompute, reach-clamp edge cases, degenerate vectors (`.Unit` on near-zero), and the `explicitPath` walk termination. Fix any confirmed findings; re-run the static suite.

- [ ] **Step 3: Temporarily wire the spec runner**

In `src/init.server.luau`, add near the other one-off spec runs (search for `RigWorkbenchSpec` if present, else after deps are built):

```lua
require(script.InverseKinematicsSpec).run()
```

Build (`rojo build ...`), then the USER reopens Studio (a running Studio does NOT hot-reload a local plugin — see HANDOFF.md) and reads Output. Expected: `[InverseKinematicsSpec] N/N passed` (all green). Remove the temporary line afterward and rebuild.

- [ ] **Step 4: Live grab-and-place test (user-driven, fresh Baseplate, hecate tunnel)**

Protocol (assistant drives via computer-use once the user has Studio open on a fresh Baseplate with the tunnel + sidecar up):
1. Agent: `spawn_rig {type="r15"}` → an r15 placeholder appears.
2. Agent: `get_rig` → joints + skeleton gizmos draw.
3. Agent: `ik_reach {chain="RightArm", target={x=<~1.5 studs in front of the shoulder>}}` → the right arm bends to reach; `residual` is small; the elbow bends in a natural direction.
4. Agent: `camera_focus` + `camera_orbit` → inspect the elbow from a few angles. **Confirm the pole sign** (arm elbow back/down, knee forward); if the elbow bends the wrong way, flip `ARM_POLE`/`LEG_POLE` signs in `IkChains.luau` and rebuild.
5. Agent: build a small part, then `ik_reach {chain="RightArm", targetPart="Workspace.<part>"}` → the hand reaches the part.
6. Agent: `ik_reach {chain="Spine", target={...}}` → the spine (CCD) leans toward the point.
7. Agent: `reset_pose` → the rig returns to neutral.

- [ ] **Step 5: Update HANDOFF.md + status memory (session wrap)**

Add a dated block to `HANDOFF.md` recording slice B shipped (after live-verification), and update the `studio-agent-status` memory's CURRENT THREAD line to "slice B (IK) done; next = slice C (drag) / D (animation)". Commit the HANDOFF update.

```bash
git add HANDOFF.md
git commit -m "docs: slice B (IK grab-and-place) shipped + live-verified" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** §"Components" → Tasks 1-7 (all 5 files + wiring). §"The solver (hybrid)" → Tasks 2 (2-bone) + 3 (CCD). §"Tool surface — ik_reach" → Task 6 (chain/effector+chainRoot, target/targetPart, pole, errors). §"Scope" position-reach + pole → Tasks 2/5/6; look-at + joint-limits explicitly DEFERRED (not implemented — correct). §"Error handling" → `runReach` + `resolveChain` branches (Task 6/4). §"Testing" → Tasks 1-5 spec cases + Task 8 static/live. §"Edit-mode/Animator" → `reach` uses ChangeHistory; no Animator in slice B (carry-forward noted). All covered.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code; the only deferred items are the spec's explicit non-goals (look-at, joint limits).
- **Type consistency:** `Resolved` fields (`posedJoints`/`fkJoints`/`anchorPart`/`effectorPart`/`twoBone`/`poleDir`) are produced by `IkChains.resolveChain` (Task 4) and consumed by `IK.reach` (Task 5) and `runReach` (Task 6) under the same names. `Link = {c0, c1}` is produced in `reach`/spec and consumed by `forwardFrames`/`solve2BoneTransforms`/`solveCCDTransforms`. `transformForRotation(restFrame, worldRot)` and `forwardFrames(anchorCF, links, transforms) -> (preFrames, effectorWorld)` signatures match across Tasks 1-5.
- **Known live-test-gated risk:** the pole sign (`ARM_POLE`/`LEG_POLE`) and the exact elbow-bend direction are heuristics verified/flipped in Task 8 step 4 — flagged, not silent.
