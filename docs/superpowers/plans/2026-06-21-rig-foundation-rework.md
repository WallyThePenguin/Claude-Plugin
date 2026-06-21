# Rig Foundation Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the blocky placeholder with real native R15 rigs (`spawn_rig` block/avatar) and fix edit-mode posing to `Transform` + `Animator:StepAnimations` (reverting the direct-CFrame hack that dragged the whole assembly).

**Architecture:** A new `src/NativeRig.luau` spawns a real R15 rig via `CreateHumanoidModelFrom{Description,UserId}Async`, builds its 15 Motor6Ds from the `*RigAttachment` pairs, places it on the baseplate, anchors the root, and flat-colors the block rig. `RigWorkbench` gains `applyPose(rig)` (ensure-Animator + `StepAnimations(0)`) which every pose path calls after writing `Transform`. The placeholder/`RigTemplates`/R6 spawn are deleted.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — every mechanism here was already proven live via the dev bridge this session; verification is `selene`/`stylua`/`rojo build` + a **bridge dogfood** (`scripts/studio-agent.ps1`) after a Studio restart.

**Source of truth:** [`docs/superpowers/specs/2026-06-21-studio-agent-rig-foundation-rework-design.md`](../specs/2026-06-21-studio-agent-rig-foundation-rework-design.md).

---

## File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/NativeRig.luau` | **new** | Native R15 spawn: `JOINT_MAP`, `PALETTE`, `buildJoints`, `placeOnBaseplate`, `anchorRoot`, `colorParts`, `spawnBlock`, `spawnAvatar`. |
| `src/NativeRigSpec.luau` | **new** | In-Studio self-test for the PURE map/palette (no spawn). |
| `src/RigWorkbench.luau` | mod | Add `applyPose`; call it from `poseJoint`/`resetPose`; delete `buildPlaceholder`/`loadNativeRig` + the `RigTemplates`/`InsertService` requires; `spawn` delegates to `NativeRig`. |
| `src/InverseKinematics.luau` | mod | `reach`: revert the direct part-CFrame loop; call `RigWorkbench.applyPose(rig)`. |
| `src/RigTemplates.luau` | **del** | Blocky placeholder data — gone. |
| `src/Tools/Rig.luau` | mod | `spawn_rig` descriptor: `type` (`block`/`avatar`) + `userId`. |
| `src/InverseKinematicsSpec.luau` | mod | Remove the DataModel cases (they call web-backed `spawn`) + their now-unused requires; keep pure-math. |

### Reference (proven live this session)
- `Players:CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)` → real R15 block rig (15 MeshParts + RigAttachment pairs, **0 Motor6Ds**). YIELDS.
- Build joints: for each `*RigAttachment` pair, `Motor6D{Part0=parent, Part1=child, C0=parentAtt.CFrame, C1=childAtt.CFrame, Parent=parent}`.
- Pose visibly: write `Motor6D.Transform`, then `Animator:StepAnimations(0)` (get-or-create the Humanoid's Animator). Moves joints relative to the body. **Never** set part CFrames directly (drags the whole assembly).

---

## Task 1: `NativeRig.luau` + pure spec

**Files:**
- Create: `src/NativeRig.luau`
- Create: `src/NativeRigSpec.luau`

- [ ] **Step 1: Write `src/NativeRig.luau`**

```lua
--!strict
-- NativeRig: spawn REAL native R15 rigs from code (no trusted asset). CreateHumanoidModelFromDescription
-- gives a real R15 rig (15 MeshParts + RigAttachment pairs) but ZERO Motor6Ds; we build the 15 joints from
-- the attachment pairs (Humanoid:BuildRigFromAttachments does NOT — verified live). Then place on the
-- baseplate, anchor the root, and (block only) flat-color each part so poses read clearly in captures. The
-- Async spawns YIELD (web-backed) — call from a tool, not a tight loop. All mechanisms proven via the dev bridge.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local NativeRig = {}

-- {jointName, parentPartName, childPartName} — canonical R15 hierarchy. The RigAttachment on each part is
-- named jointName.."RigAttachment"; the Motor6D goes in Part0 (the parent).
local JOINT_MAP: { { string } } = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "RightWrist", "RightLowerArm", "RightHand" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot" },
}

local PALETTE: { Color3 } = {
	Color3.fromRGB(230, 25, 75), Color3.fromRGB(60, 180, 75), Color3.fromRGB(255, 225, 25),
	Color3.fromRGB(0, 130, 200), Color3.fromRGB(245, 130, 48), Color3.fromRGB(145, 30, 180),
	Color3.fromRGB(70, 240, 240), Color3.fromRGB(240, 50, 230), Color3.fromRGB(210, 245, 60),
	Color3.fromRGB(250, 190, 212), Color3.fromRGB(0, 128, 128), Color3.fromRGB(220, 190, 255),
	Color3.fromRGB(170, 110, 40), Color3.fromRGB(128, 0, 0), Color3.fromRGB(170, 255, 195),
	Color3.fromRGB(255, 255, 255),
}

NativeRig.JOINT_MAP = JOINT_MAP
NativeRig.PALETTE = PALETTE

-- Build the Motor6Ds from the RigAttachment pairs. Skips a joint that already exists (idempotent) or whose
-- parts/attachments are missing. Returns the count built.
function NativeRig.buildJoints(model: Instance): number
	local built = 0
	for _, j in JOINT_MAP do
		local jointName, p0Name, p1Name = j[1], j[2], j[3]
		local p0 = model:FindFirstChild(p0Name)
		local p1 = model:FindFirstChild(p1Name)
		if p0 ~= nil and p1 ~= nil and p0:FindFirstChild(jointName) == nil then
			local a0 = p0:FindFirstChild(jointName .. "RigAttachment")
			local a1 = p1:FindFirstChild(jointName .. "RigAttachment")
			if a0 ~= nil and a1 ~= nil and a0:IsA("Attachment") and a1:IsA("Attachment") then
				local m = Instance.new("Motor6D")
				m.Name = jointName
				m.Part0 = p0 :: BasePart
				m.Part1 = p1 :: BasePart
				m.C0 = a0.CFrame
				m.C1 = a1.CFrame
				m.Parent = p0
				built += 1
			end
		end
	end
	return built
end

-- Lift the model so its lowest extent sits ~0.5 above the baseplate (y=0).
function NativeRig.placeOnBaseplate(model: Model)
	local cf, size = model:GetBoundingBox()
	local bottom = cf.Position.Y - size.Y / 2
	model:PivotTo(model:GetPivot() + Vector3.new(0, 0.5 - bottom, 0))
end

function NativeRig.anchorRoot(model: Instance)
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil and hrp:IsA("BasePart") then
		hrp.Anchored = true
	end
end

-- Flat distinct color per part + cleared avatar textures, so poses read clearly in captures.
function NativeRig.colorParts(model: Instance)
	local i = 0
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			i += 1
			if d:IsA("MeshPart") then
				d.TextureID = ""
				local sa = d:FindFirstChildOfClass("SurfaceAppearance")
				if sa ~= nil then
					sa:Destroy()
				end
			end
			d.Color = PALETTE[(i - 1) % #PALETTE + 1]
			d.Material = Enum.Material.SmoothPlastic
		end
	end
end

local function finish(model: Model, colored: boolean): Model
	model.Name = "AgentRig"
	model.Parent = Workspace
	NativeRig.buildJoints(model)
	NativeRig.placeOnBaseplate(model)
	NativeRig.anchorRoot(model)
	if colored then
		NativeRig.colorParts(model)
	end
	return model
end

-- Spawn the R15 BLOCK rig (default description). YIELDS. Returns (model, nil) or (nil, errString).
function NativeRig.spawnBlock(): (Model?, string?)
	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(
			Instance.new("HumanoidDescription"),
			Enum.HumanoidRigType.R15
		)
	end)
	if not ok or typeof(result) ~= "Instance" then
		return nil, "CreateHumanoidModelFromDescriptionAsync failed: " .. tostring(result)
	end
	return finish(result :: Model, true), nil
end

-- Spawn a real avatar (mesh) from a userId. YIELDS. Returns (model, nil) or (nil, errString).
function NativeRig.spawnAvatar(userId: number): (Model?, string?)
	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromUserIdAsync(userId)
	end)
	if not ok or typeof(result) ~= "Instance" then
		return nil,
			"CreateHumanoidModelFromUserIdAsync(" .. tostring(userId) .. ") failed: " .. tostring(result)
	end
	return finish(result :: Model, false), nil
end

return NativeRig
```

- [ ] **Step 2: Write `src/NativeRigSpec.luau` (pure map/palette validation)**

```lua
--!strict
-- NativeRigSpec: in-Studio self-test for the PURE NativeRig data (JOINT_MAP + PALETTE). No spawn (that
-- yields/web). Run via temporarily adding `require(script.NativeRigSpec).run()` to init.server.luau.

local NativeRig = require(script.Parent.NativeRig)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local R15_PARTS = {
	HumanoidRootPart = true, LowerTorso = true, UpperTorso = true, Head = true,
	RightUpperArm = true, RightLowerArm = true, RightHand = true,
	LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
	RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
	LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
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
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/NativeRig.luau src/NativeRigSpec.luau
git commit -m "feat: NativeRig — native R15 spawn (build joints from RigAttachments) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `RigWorkbench` — applyPose + delegate spawn + drop placeholder

**Files:**
- Modify: `src/RigWorkbench.luau`

- [ ] **Step 1: Swap the requires** — replace the top `InsertService` + `RigTemplates` requires.

Replace:
```lua
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InsertService = game:GetService("InsertService")

local RigTemplates = require(script.Parent.RigTemplates)
```
with:
```lua
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local NativeRig = require(script.Parent.NativeRig)
```

- [ ] **Step 2: Add `applyPose`** — insert immediately after the `redrawIfShown` local function (before `RigWorkbench.poseJoint`):

```lua
-- Make Motor6D.Transform poses VISIBLE in edit. Writing Transform alone does NOT move parts in static edit
-- (verified live); the animation system applies it. Get-or-create the rig's Animator and StepAnimations(0),
-- which re-solves the rig from its Transforms — moving joints RELATIVE to the body (root + unposed limbs
-- stay; children follow their parent). NEVER set part CFrames directly (that rigidly drags the whole
-- assembly). No-op (Transform still set) if the rig has no Humanoid/AnimationController.
function RigWorkbench.applyPose(rig: Instance)
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller == nil then
		return
	end
	local animator = controller:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end
	pcall(function()
		(animator :: Animator):StepAnimations(0)
	end)
end
```

- [ ] **Step 3: Call `applyPose` from `poseJoint`** — in `RigWorkbench.poseJoint`, after the `m.Transform = ...` line and before `finishRecording(rid, true)`:

Replace:
```lua
	m.Transform = RigWorkbench.applyRotation(m.Transform, rot, relative)
	finishRecording(rid, true)
```
with:
```lua
	m.Transform = RigWorkbench.applyRotation(m.Transform, rot, relative)
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
```

- [ ] **Step 4: Call `applyPose` from `resetPose`** — after the reset loop, before `finishRecording`:

Replace:
```lua
	for _, m in joints do
		m.Transform = CFrame.identity
	end
	finishRecording(rid, true)
```
with:
```lua
	for _, m in joints do
		m.Transform = CFrame.identity
	end
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
```

- [ ] **Step 5: Replace `spawn` + delete `loadNativeRig`/`buildPlaceholder`** — replace everything from `-- ---- spawn ----` to the end of `RigWorkbench.spawn` (i.e. `loadNativeRig`, `buildPlaceholder`, and the old `spawn`) with:

```lua
-- ---- spawn (delegates to NativeRig) ----

-- Spawn a native R15 rig. type "block" (default) = CreateHumanoidModelFromDescription; "avatar" = a mesh
-- character from a userId (default 1). Both build the Motor6Ds, sit on the baseplate, anchor the root;
-- block also flat-colors each part. (Async/web — YIELDS.) Returns (model, note) or (nil, errorNote).
function RigWorkbench.spawn(rigType: string, userId: number?): (Instance?, string)
	if string.lower(rigType) == "avatar" then
		local model, err = NativeRig.spawnAvatar(userId or 1)
		if model == nil then
			return nil, "spawn_rig avatar: " .. tostring(err)
		end
		return model, "spawned avatar rig at " .. model:GetFullName()
	end
	local model, err = NativeRig.spawnBlock()
	if model == nil then
		return nil, "spawn_rig block: " .. tostring(err)
	end
	return model, "spawned native R15 block rig at " .. model:GetFullName()
end
```

- [ ] **Step 6: Static-verify** (NOTE: `Tools/Rig.luau` still passes the old args until Task 5, but it builds — `spawn` accepts `(string, number?)`; the old call `spawn(t, assetId)` passes a string + nil/number, which type-checks. selene won't error.)

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/RigWorkbench.luau
git commit -m "feat: RigWorkbench.applyPose (StepAnimations); spawn delegates to NativeRig; drop placeholder" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Delete `RigTemplates.luau`

**Files:**
- Delete: `src/RigTemplates.luau`

- [ ] **Step 1: Confirm nothing else requires it**

Run: `grep -rn "RigTemplates" src`
Expected: **no matches** (RigWorkbench's require was removed in Task 2).

- [ ] **Step 2: Delete the file**

```bash
git rm src/RigTemplates.luau
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds (the file is gone from the build).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: delete RigTemplates (blocky placeholder data)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `InverseKinematics.reach` — revert direct-CFrame, call applyPose

**Files:**
- Modify: `src/InverseKinematics.luau`

- [ ] **Step 1: Replace the part-CFrame loop with `applyPose`**

Replace:
```lua
	local rid = beginRecording("IK reach")
	for i, m in fk do
		m.Transform = transforms[i] or CFrame.identity
	end
	-- Motor6D.Transform alone does NOT reposition parts in static edit (no animation/assembly step
	-- applies it — verified live). Apply the joint relation to the CHAIN's parts root->tip so the pose
	-- is visible in edit: Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse(). Confined to the
	-- chain (leaf-ward of the torso) — setting torso/root parts would rigidly drag the whole assembly.
	for _, m in fk do
		if m.Part0 ~= nil and m.Part1 ~= nil then
			m.Part1.CFrame = m.Part0.CFrame * m.C0 * m.Transform * m.C1:Inverse()
		end
	end
	finishRecording(rid, true)
```
with:
```lua
	local rid = beginRecording("IK reach")
	for i, m in fk do
		m.Transform = transforms[i] or CFrame.identity
	end
	-- Make the pose visible in edit via the animation system (NOT by setting part CFrames directly —
	-- that rigidly drags the whole Motor6D assembly; verified live). applyPose calls StepAnimations,
	-- which moves the posed joints relative to the body.
	RigWorkbench.applyPose(rig)
	finishRecording(rid, true)
```

(`InverseKinematics` already `require`s `RigWorkbench` — used by `reach` for `drawSkeleton`. No new require.)

- [ ] **Step 2: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/InverseKinematics.luau
git commit -m "fix: ik_reach poses via applyPose/StepAnimations (revert the assembly-dragging direct-CFrame hack)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `spawn_rig` tool — block/avatar/userId

**Files:**
- Modify: `src/Tools/Rig.luau`

- [ ] **Step 1: Update `runSpawn`**

Replace:
```lua
local function runSpawn(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local t = if type(args.type) == "string" then args.type else "r6"
	local assetId = if type(args.assetId) == "number" then args.assetId else nil
	local model, note = RigWorkbench.spawn(t, assetId)
	if model == nil then
		return note, true
	end
	return note .. " at " .. Path.fullPath(model), false
end
```
with:
```lua
local function runSpawn(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local t = if type(args.type) == "string" then args.type else "block"
	local userId = if type(args.userId) == "number" then args.userId else nil
	local model, note = RigWorkbench.spawn(t, userId)
	if model == nil then
		return note, true
	end
	return note, false -- note already includes the full path
end
```

- [ ] **Step 2: Update the `spawn_rig` descriptor** — replace its `description` + `inputSchema`:

Replace the `spawn_rig` entry's `description = ...` block and `inputSchema = { ... }` with:
```lua
		description = "Spawn a real NATIVE R15 rig to pose/animate. type 'block' (default) = the standard "
			.. "R15 block rig (built in-engine, joints + attachments, parts flat-colored so poses read "
			.. "clearly); type 'avatar' = a real mesh character from a userId (pass userId; defaults to 1). "
			.. "The rig lands on the baseplate with its root anchored. get_rig/pose_joint/ik_reach then "
			.. "operate on it (they work on ANY Motor6D rig, incl. one you insert via Avatar > Rig Builder).",
		inputSchema = {
			type = "object",
			properties = {
				type = { type = "string", description = "'block' (default) or 'avatar'." },
				userId = {
					type = "number",
					description = "For type 'avatar': the Roblox userId to spawn (default 1).",
				},
			},
		},
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Rig.luau
git commit -m "feat: spawn_rig type block/avatar + userId (native R15)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Trim `InverseKinematicsSpec` (web-backed spawn can't run at load)

**Files:**
- Modify: `src/InverseKinematicsSpec.luau`

- [ ] **Step 1: Remove the two DataModel cases** — delete the `add("resolveChain RightArm on a spawned r15 returns shoulder+elbow", ...)` case and the `add("reach RightArm lands the right hand near a reachable target (r15)", ...)` case in full. (They call `RigWorkbench.spawn`, now web-backed/yielding — unfit for an at-load self-test; they become the bridge dogfood in Task 7.)

- [ ] **Step 2: Remove the now-unused requires** — at the top, delete:
```lua
local RigWorkbench = require(script.Parent.RigWorkbench)
local IkChains = require(script.Parent.IkChains)
local Workspace = game:GetService("Workspace")
```
Leave only `local IK = require(script.Parent.InverseKinematics)`. (The remaining cases are pure math — they use only `IK`.)

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings` (no unused-require warnings); rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/InverseKinematicsSpec.luau
git commit -m "test: drop IK spec DataModel cases (spawn is now web-backed); bridge dogfood covers them" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full verify + bridge dogfood

**Files:** none (verification only)

- [ ] **Step 1: Full static suite + install**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds; `Installed -> …\Plugins\StudioAgent.rbxm`.

- [ ] **Step 2: Reload the plugin** — the dev bridge can't hot-reload itself, so the USER restarts Studio ("Restart to update") on a fresh Baseplate. The sidecar + bridge are already running; confirm `[StudioAgent] dev bridge active` via `powershell -File scripts/studio-agent.ps1 logs`.

- [ ] **Step 3: Dogfood the spawn + pose + LOOK** (the verification that matters — a clear capture, not coordinates):
```bash
powershell -File scripts/studio-agent.ps1 tool spawn_rig '{"type":"block"}'        # -> "spawned native R15 block rig at Workspace.AgentRig"
powershell -File scripts/studio-agent.ps1 tool get_rig '{"rig":"Workspace.AgentRig"}'  # -> 15 joints listed
powershell -File scripts/studio-agent.ps1 tool ik_reach '{"rig":"Workspace.AgentRig","chain":"RightArm","target":{"x":1,"y":0,"z":2}}'
powershell -File scripts/studio-agent.ps1 luau 'local c=workspace.AgentRig:GetPivot().Position local cam=workspace.CurrentCamera cam.CameraType=Enum.CameraType.Scriptable cam.FieldOfView=40 cam.CFrame=CFrame.lookAt(c+Vector3.new(5,1,7),c) return "cam set"'
powershell -File scripts/studio-agent.ps1 tool capture '{}'
powershell -File scripts/studio-agent.ps1 capture C:/Users/manso/AppData/Local/Temp/rework-verify.png
```
Then **Read `rework-verify.png`** and confirm: a colored R15 rig standing on the baseplate, right arm posed toward the target, body/other limbs unmoved. (Pick a target near the rig's right shoulder; read the shoulder via `luau` first if the reach clamps.) Restore the camera: `luau 'workspace.CurrentCamera.CameraType=Enum.CameraType.Custom'`.

- [ ] **Step 4: Update HANDOFF.md** — add a dated block: rework shipped (native R15 spawn + applyPose/StepAnimations), placeholder/RigTemplates/R6-spawn dropped, slice B's posing now correct. Commit.

```bash
git add HANDOFF.md
git commit -m "docs: rig foundation rework shipped + bridge-verified (native R15 + StepAnimations posing)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** `NativeRig` (spawnBlock/spawnAvatar/buildJoints/place/anchor/color) → Task 1; `applyPose` + spawn delegation + placeholder deletion → Task 2; `RigTemplates` delete → Task 3; reach revert → Task 4; `spawn_rig` block/avatar/userId → Task 5; spec trim → Task 6; live dogfood → Task 7. Error handling (Async pcall → errString; buildJoints skips/idempotent; applyPose no-op without a controller) is in Tasks 1–2. All spec sections covered.
- **Placeholder scan:** no TBD/TODO; every code step is complete; the only deletions are the spec's explicit drops (placeholder/RigTemplates/R6/direct-CFrame hack).
- **Type/name consistency:** `NativeRig.spawnBlock()/spawnAvatar(userId)` (Task 1) are called by `RigWorkbench.spawn` (Task 2). `RigWorkbench.applyPose(rig)` (Task 2) is called by `poseJoint`/`resetPose` (Task 2) and `InverseKinematics.reach` (Task 4). `RigWorkbench.spawn(rigType, userId?)` (Task 2) matches `runSpawn`'s call (Task 5). `JOINT_MAP`/`PALETTE` are exported (Task 1) and read by `NativeRigSpec` (Task 1).
- **Ordering note:** Task 2 changes `spawn`'s signature while `Tools/Rig.luau` still calls the old form — it still type-checks/builds (string + number?); Task 5 updates the caller. Tasks 1→7 build green at each step.
