# Rig Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the agent spawn a real rig, see its Motor6D skeleton, and pose its joints (set `Motor6D.Transform`) — the rig-editor foundation, inspected via the camera rig.

**Architecture:** A **stateless** `RigWorkbench` module (operates on rigs in the DataModel by reference; gizmos live under a tagged Workspace folder found by name) + a `RigTemplates` data module (blocky humanoid placeholder, correct-by-construction joints) + a `Tools/Rig` wrapper. Posing sets `Motor6D.Transform` (animation channel, live in edit), wrapped in ChangeHistory like `create_instance`. Read/visualize/pose are rig-agnostic (real R6/R15 work too). No deps/threading — the tool requires the module directly.

**Tech Stack:** Luau (`--!strict`, Studio plugin); rokit (`rojo`/`selene`/`stylua`). Reuses `Tools/Path`, `ChangeHistoryService`, the camera rig for inspection.

**Source spec:** `docs/superpowers/specs/2026-06-20-studio-agent-rig-workbench-design.md`.

---

## Domain-adaptation note

Luau-in-Studio isn't unit-runnable here. **Static verification here:** `selene src` (0/0), `stylua --check src`, `rojo build`. (Note: selene/stylua/rojo do NOT run the Luau type checker, so `--!strict` type *warnings* won't fail them and don't affect runtime — code still runs; the user would see any in Studio's Script Analysis.) **The "tests" are an in-Studio Spec** (`RigWorkbenchSpec`, pure helpers) + the **live test** (drive Studio via computer-use). TDD applies to the pure helpers via the Spec.

## File structure

- Create: `src/RigTemplates.luau` — blocky humanoid placeholder data + `get(name)`.
- Create: `src/RigWorkbench.luau` — read skeleton / draw gizmos / pose / reset / spawn (stateless).
- Create: `src/RigWorkbenchSpec.luau` — pure-helper self-test.
- Create: `src/Tools/Rig.luau` — the 5 tool descriptors.
- Modify: `src/Tools/init.luau` (register), `src/SystemPrompt.luau` (docs). **No** init.server/AgentLoop/Widget/Relay changes (stateless module; rig edits relay by default like `create_instance`).

---

## Task 1: RigTemplates + RigWorkbench + Spec

**Files:** Create `src/RigTemplates.luau`, `src/RigWorkbench.luau`, `src/RigWorkbenchSpec.luau`

- [ ] **Step 1: Write `src/RigTemplates.luau`**

```lua
--!strict
-- RigTemplates: blocky humanoid placeholder rig data for RigWorkbench.spawn. Parts are placed at
-- chosen positions; joint C0/C1 are computed from those positions (correct-by-construction), so we
-- never hand-author Roblox's exact matrices. Names follow the R6 convention so the spawned Model +
-- Humanoid is a valid R6 rig.

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
		{ name = "RootJoint", part0 = "HumanoidRootPart", part1 = "Torso", pivot = V(0, 3, 0), host = "HumanoidRootPart" },
		{ name = "Neck", part0 = "Torso", part1 = "Head", pivot = V(0, 4, 0), host = "Torso" },
		{ name = "Right Shoulder", part0 = "Torso", part1 = "Right Arm", pivot = V(1, 4, 0), host = "Torso" },
		{ name = "Left Shoulder", part0 = "Torso", part1 = "Left Arm", pivot = V(-1, 4, 0), host = "Torso" },
		{ name = "Right Hip", part0 = "Torso", part1 = "Right Leg", pivot = V(0.5, 2, 0), host = "Torso" },
		{ name = "Left Hip", part0 = "Torso", part1 = "Left Leg", pivot = V(-0.5, 2, 0), host = "Torso" },
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
		{ name = "Root", part0 = "HumanoidRootPart", part1 = "LowerTorso", pivot = V(0, 3.4, 0), host = "HumanoidRootPart" },
		{ name = "Waist", part0 = "LowerTorso", part1 = "UpperTorso", pivot = V(0, 4.2, 0), host = "LowerTorso" },
		{ name = "Neck", part0 = "UpperTorso", part1 = "Head", pivot = V(0, 5.8, 0), host = "UpperTorso" },
		{ name = "RightShoulder", part0 = "UpperTorso", part1 = "RightUpperArm", pivot = V(1.0, 5.6, 0), host = "UpperTorso" },
		{ name = "RightElbow", part0 = "RightUpperArm", part1 = "RightLowerArm", pivot = V(1.5, 4.2, 0), host = "RightUpperArm" },
		{ name = "RightWrist", part0 = "RightLowerArm", part1 = "RightHand", pivot = V(1.5, 3.0, 0), host = "RightLowerArm" },
		{ name = "LeftShoulder", part0 = "UpperTorso", part1 = "LeftUpperArm", pivot = V(-1.0, 5.6, 0), host = "UpperTorso" },
		{ name = "LeftElbow", part0 = "LeftUpperArm", part1 = "LeftLowerArm", pivot = V(-1.5, 4.2, 0), host = "LeftUpperArm" },
		{ name = "LeftWrist", part0 = "LeftLowerArm", part1 = "LeftHand", pivot = V(-1.5, 3.0, 0), host = "LeftLowerArm" },
		{ name = "RightHip", part0 = "LowerTorso", part1 = "RightUpperLeg", pivot = V(0.5, 3.4, 0), host = "LowerTorso" },
		{ name = "RightKnee", part0 = "RightUpperLeg", part1 = "RightLowerLeg", pivot = V(0.5, 2.0, 0), host = "RightUpperLeg" },
		{ name = "RightAnkle", part0 = "RightLowerLeg", part1 = "RightFoot", pivot = V(0.5, 0.6, 0), host = "RightLowerLeg" },
		{ name = "LeftHip", part0 = "LowerTorso", part1 = "LeftUpperLeg", pivot = V(-0.5, 3.4, 0), host = "LowerTorso" },
		{ name = "LeftKnee", part0 = "LeftUpperLeg", part1 = "LeftLowerLeg", pivot = V(-0.5, 2.0, 0), host = "LeftUpperLeg" },
		{ name = "LeftAnkle", part0 = "LeftLowerLeg", part1 = "LeftFoot", pivot = V(-0.5, 0.6, 0), host = "LeftLowerLeg" },
	},
}

local byName: { [string]: Template } = { r6 = r6, r15 = r15 }

function RigTemplates.get(name: string): Template?
	return byName[string.lower(name)]
end

return RigTemplates
```

- [ ] **Step 2: Write `src/RigWorkbench.luau`**

```lua
--!strict
-- RigWorkbench: the rig-editor foundation. Read a rig's Motor6D skeleton, visualize it (Neon gizmo
-- markers + bones, like the camera rig's proven parts), and POSE it by setting Motor6D.Transform (the
-- animation channel — applies live in edit). Also spawns a blocky humanoid placeholder (RigTemplates);
-- read/visualize/pose are rig-agnostic (any Motor6D rig, incl. real R6/R15). STATELESS module: operates
-- on rigs in the DataModel; gizmos live under a tagged Workspace folder (found by name, not held).

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local RigTemplates = require(script.Parent.RigTemplates)

local RigWorkbench = {}

local SKELETON_FOLDER = "__StudioAgentRigSkeleton"
local SKELETON_TAG = "StudioAgentRigSkeleton"

-- ---- pure helpers (no DataModel — unit-testable) ----

-- Degrees (x,y,z) -> a rotation CFrame.
function RigWorkbench.rotationCFrame(rx: number, ry: number, rz: number): CFrame
	return CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
end

-- Compose a pose: relative multiplies onto the current Transform; absolute replaces it.
function RigWorkbench.applyRotation(current: CFrame, rot: CFrame, relative: boolean): CFrame
	if relative then
		return current * rot
	end
	return rot
end

-- ---- rig reading ----

function RigWorkbench.jointsOf(rig: Instance): { Motor6D }
	local out: { Motor6D } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(out, d)
		end
	end
	return out
end

-- Find a joint by exact Name, else case-insensitive. nil if absent.
function RigWorkbench.findJoint(rig: Instance, name: string): Motor6D?
	local lower = string.lower(name)
	local fallback: Motor6D? = nil
	for _, m in RigWorkbench.jointsOf(rig) do
		if m.Name == name then
			return m
		end
		if string.lower(m.Name) == lower then
			fallback = m
		end
	end
	return fallback
end

-- Readable joint list + a name list (for errors). (text, names).
function RigWorkbench.readSkeleton(rig: Instance): (string, { string })
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return "no Motor6D joints found under " .. rig.Name .. " (is this a rig?)", {}
	end
	local lines: { string } = { string.format("%s — %d joints:", rig.Name, #joints) }
	local names: { string } = {}
	for _, m in joints do
		table.insert(names, m.Name)
		local p0 = if m.Part0 ~= nil then m.Part0.Name else "?"
		local p1 = if m.Part1 ~= nil then m.Part1.Name else "?"
		local posed = if m.Transform ~= CFrame.identity then " [posed]" else ""
		table.insert(lines, string.format("- %s: %s -> %s%s", m.Name, p0, p1, posed))
	end
	return table.concat(lines, "\n"), names
end

-- ---- skeleton visualization (Neon gizmo parts; proven to render, like the camera rig) ----

local function clearFolder()
	local f = Workspace:FindFirstChild(SKELETON_FOLDER)
	if f ~= nil then
		f:Destroy()
	end
end

function RigWorkbench.clearSkeleton()
	clearFolder()
end

local function marker(folder: Instance, color: Color3, size: Vector3, cf: CFrame, name: string)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Locked = true
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = folder
end

-- A ball at each joint's world pivot + a bone from the pivot to Part1's center.
function RigWorkbench.drawSkeleton(rig: Instance)
	clearFolder()
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = SKELETON_FOLDER
	CollectionService:AddTag(folder, SKELETON_TAG)
	for _, m in joints do
		local p0, p1 = m.Part0, m.Part1
		if p0 ~= nil and p1 ~= nil then
			local jointPos = (p0.CFrame * m.C0).Position
			marker(
				folder,
				Color3.fromRGB(0, 255, 120),
				Vector3.new(0.5, 0.5, 0.5),
				CFrame.new(jointPos),
				m.Name .. "_joint"
			)
			local target = p1.Position
			local dist = (target - jointPos).Magnitude
			if dist > 0.05 then
				marker(
					folder,
					Color3.fromRGB(80, 160, 255),
					Vector3.new(0.12, 0.12, dist),
					CFrame.lookAt((jointPos + target) / 2, target),
					m.Name .. "_bone"
				)
			end
		end
	end
	folder.Parent = Workspace
end

-- ---- posing (ChangeHistory like create_instance) ----

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
			if commit
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end
end

local function redrawIfShown(rig: Instance)
	if Workspace:FindFirstChild(SKELETON_FOLDER) ~= nil then
		RigWorkbench.drawSkeleton(rig)
	end
end

-- Pose one joint by Name (degrees x/y/z). relative accumulates onto the current Transform. (note, ok).
function RigWorkbench.poseJoint(
	rig: Instance,
	jointName: string,
	rx: number,
	ry: number,
	rz: number,
	relative: boolean
): (string, boolean)
	local m = RigWorkbench.findJoint(rig, jointName)
	if m == nil then
		local _, names = RigWorkbench.readSkeleton(rig)
		return "no joint named '" .. jointName .. "'. Joints: " .. table.concat(names, ", "), false
	end
	local rot = RigWorkbench.rotationCFrame(rx, ry, rz)
	local rid = beginRecording("Pose " .. m.Name)
	m.Transform = RigWorkbench.applyRotation(m.Transform, rot, relative)
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format(
		"posed %s by (%g, %g, %g)%s",
		m.Name,
		rx,
		ry,
		rz,
		if relative then " [relative]" else " [absolute]"
	),
		true
end

-- Reset every joint's Transform to identity. (note, ok).
function RigWorkbench.resetPose(rig: Instance): (string, boolean)
	local joints = RigWorkbench.jointsOf(rig)
	if #joints == 0 then
		return "no joints to reset under " .. rig.Name, false
	end
	local rid = beginRecording("Reset pose")
	for _, m in joints do
		m.Transform = CFrame.identity
	end
	finishRecording(rid, true)
	redrawIfShown(rig)
	return string.format("reset %d joints on %s", #joints, rig.Name), true
end

-- ---- spawn (blocky humanoid placeholder; correct-by-construction joints) ----

function RigWorkbench.spawn(templateName: string): (Instance?, string)
	local template = RigTemplates.get(templateName)
	if template == nil then
		return nil, "unknown rig type '" .. templateName .. "' (try 'r6')"
	end
	local rid = beginRecording("Spawn rig")
	local model = Instance.new("Model")
	model.Name = "AgentRig_" .. string.upper(templateName)
	local parts: { [string]: BasePart } = {}
	for _, pt in template.parts do
		local p = Instance.new("Part")
		p.Name = pt.name
		p.Size = pt.size
		p.CFrame = CFrame.new(pt.pos)
		p.Anchored = pt.name == "HumanoidRootPart"
		p.Color = if pt.name == "Head"
			then Color3.fromRGB(255, 200, 120)
			else Color3.fromRGB(160, 160, 170)
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		parts[pt.name] = p
	end
	for _, j in template.joints do
		local p0, p1, host = parts[j.part0], parts[j.part1], parts[j.host]
		if p0 ~= nil and p1 ~= nil and host ~= nil then
			local pivot = CFrame.new(j.pivot)
			local motor = Instance.new("Motor6D")
			motor.Name = j.name
			motor.Part0 = p0
			motor.Part1 = p1
			motor.C0 = p0.CFrame:Inverse() * pivot
			motor.C1 = p1.CFrame:Inverse() * pivot
			motor.Parent = host
		end
	end
	local hum = Instance.new("Humanoid")
	if string.lower(templateName) == "r15" then
		hum.RigType = Enum.HumanoidRigType.R15
	end
	hum.Parent = model
	model.PrimaryPart = parts["HumanoidRootPart"]
	model.Parent = Workspace
	finishRecording(rid, true)
	return model, "spawned " .. model.Name
end

return RigWorkbench
```

- [ ] **Step 3: Write `src/RigWorkbenchSpec.luau`**

```lua
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
```

- [ ] **Step 4: Verify** — Run: `stylua src/RigTemplates.luau src/RigWorkbench.luau src/RigWorkbenchSpec.luau && selene src 2>&1 | tail -3 && stylua --check src/RigTemplates.luau src/RigWorkbench.luau src/RigWorkbenchSpec.luau && echo clean`
Expected: `0 errors / 0 warnings` and `clean`. (If selene flags a single-arg `assert` or unused var, fix inline.)

- [ ] **Step 5: Commit**

```bash
git add src/RigTemplates.luau src/RigWorkbench.luau src/RigWorkbenchSpec.luau
git commit -m "feat: RigWorkbench (read/visualize/pose Motor6D skeleton + spawn) + spec"
```

---

## Task 2: Rig tools + registration

**Files:** Create `src/Tools/Rig.luau`; Modify `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Rig.luau`**

```lua
--!strict
-- Rig tools: spawn_rig / get_rig / pose_joint / reset_pose / show_skeleton. Thin wrappers over the
-- stateless RigWorkbench module. DataModel edits (spawn/pose/reset) are destructive + undoable (relayed
-- in client-view like create_instance); reads + gizmo toggles are non-destructive. resolveRig: a dot
-- path, or the current Studio selection.

local Selection = game:GetService("Selection")

local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
local Path = require(script.Parent.Path)

local Rig = {}

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

local function runSpawn(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local t = if type(args.type) == "string" then args.type else "r6"
	local model, note = RigWorkbench.spawn(t)
	if model == nil then
		return note, true
	end
	return note .. " at " .. Path.fullPath(model), false
end

local function runGet(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "get_rig: " .. tostring(err), true
	end
	local text, names = RigWorkbench.readSkeleton(rig)
	if #names == 0 then
		return text, true
	end
	RigWorkbench.drawSkeleton(rig)
	return text .. "\n(skeleton gizmos drawn; show_skeleton {on:false} to hide)", false
end

local function runPose(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "pose_joint: " .. tostring(err), true
	end
	if type(args.joint) ~= "string" then
		return "pose_joint requires { rig?, joint = <string>, rotation = {x?,y?,z?}, relative? }", true
	end
	local rot = if type(args.rotation) == "table" then args.rotation else {}
	local rx = if type(rot.x) == "number" then rot.x else 0
	local ry = if type(rot.y) == "number" then rot.y else 0
	local rz = if type(rot.z) == "number" then rot.z else 0
	local relative = args.relative ~= false
	local note, ok = RigWorkbench.poseJoint(rig, args.joint, rx, ry, rz, relative)
	return note, not ok
end

local function runReset(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "reset_pose: " .. tostring(err), true
	end
	local note, ok = RigWorkbench.resetPose(rig)
	return note, not ok
end

local function runShow(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local on = args.on ~= false
	if not on then
		RigWorkbench.clearSkeleton()
		return "skeleton gizmos hidden.", false
	end
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "show_skeleton: " .. tostring(err), true
	end
	RigWorkbench.drawSkeleton(rig)
	return "skeleton gizmos drawn.", false
end

Rig.descriptors = {
	{
		name = "spawn_rig",
		description = "Spawn a blocky humanoid PLACEHOLDER rig to pose and animate. type = 'r6' (default, "
			.. "6-limb R6) or 'r15' (15-part R15 topology + standard R15 joint names + a Humanoid set to "
			.. "R15). Returns the rig's path. get_rig/pose_joint also work on ANY real rig you insert "
			.. "(Studio's Rig Builder), so you can spawn one here or operate on an existing one.",
		inputSchema = {
			type = "object",
			properties = {
				type = { type = "string", description = "'r6' (default) or 'r15'." },
			},
		},
		destructive = true,
		run = runSpawn,
	},
	{
		name = "get_rig",
		description = "Read a rig's Motor6D SKELETON (joint names + which parts they connect + whether "
			.. "they're posed) and DRAW skeleton gizmos (a marker at each joint + bones). Input: rig "
			.. "(instance path; omit to use the selection). Use this to SEE the joints before posing.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
			},
		},
		destructive = false,
		run = runGet,
	},
	{
		name = "pose_joint",
		description = "Pose a rig by ROTATING one joint (sets Motor6D.Transform — the animation channel, "
			.. "live in edit). Input: rig (path or selection), joint (name from get_rig, e.g. "
			.. "'Right Shoulder'), rotation {x,y,z} in DEGREES, relative (default true = add onto the "
			.. "current pose; false = absolute). Capture (camera_focus/orbit) to see the result.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				joint = { type = "string", description = "Joint name (from get_rig)." },
				rotation = {
					type = "object",
					description = "Degrees: { x?, y?, z? } (missing axes = 0).",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
				relative = {
					type = "boolean",
					description = "Default true (accumulate). false = set absolute rotation.",
				},
			},
			required = { "joint" },
		},
		destructive = true,
		run = runPose,
	},
	{
		name = "reset_pose",
		description = "Reset a rig to its neutral pose (every joint's Transform back to identity). Input: "
			.. "rig (path or selection).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
			},
		},
		destructive = true,
		run = runReset,
	},
	{
		name = "show_skeleton",
		description = "Toggle the skeleton gizmo overlay. Input: rig (path/selection) + on (default true; "
			.. "on:false hides the gizmos).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				on = { type = "boolean", description = "true to draw (default), false to hide." },
			},
		},
		destructive = false,
		run = runShow,
	},
} :: { Descriptor }

return Rig
```

- [ ] **Step 2: Register in `src/Tools/init.luau`** — after `local CameraRigTool = require(script.CameraRig)` add:

```lua
local RigTool = require(script.Rig)
```

After the `CameraRigTool` registration loop add:

```lua
for _, descriptor in RigTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Verify** — Run: `stylua src/Tools/Rig.luau src/Tools/init.luau && selene src 2>&1 | tail -3 && stylua --check src/Tools/Rig.luau src/Tools/init.luau && echo clean`
Expected: `0 errors / 0 warnings` and `clean`.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Rig.luau src/Tools/init.luau
git commit -m "feat: rig tools (spawn_rig/get_rig/pose_joint/reset_pose/show_skeleton) + register"
```

---

## Task 3: SystemPrompt docs + full build

**Files:** Modify `src/SystemPrompt.luau`

- [ ] **Step 1: Add the tool one-liner** — after the `- camera_focus(target) / camera_orbit(...) / camera_release(): ...` line add:

```lua
- spawn_rig / get_rig / pose_joint / reset_pose / show_skeleton: spawn, see, and pose a rig's joints — see "Rigs & posing".
```

- [ ] **Step 2: Add the section** — before the `# Inspecting visually (camera rig)` section header, add:

```
# Rigs & posing
To work with a character/creature rig: get_rig(rig) reads its Motor6D SKELETON (joint names + which parts they connect) and draws skeleton gizmos so you can SEE the joints; pose_joint(rig, joint, rotation, relative?) rotates ONE joint (degrees x/y/z — this sets Motor6D.Transform, the animation channel, and applies live in edit); reset_pose(rig) returns it to neutral. You can spawn_rig() a blocky placeholder rig to practice, or operate on a real R6/R15 rig the user inserted (Studio's Rig Builder) — the tools work on ANY Motor6D rig. After posing, use camera_focus/camera_orbit to inspect the pose from any angle. You're setting POSE (Transform), not editing joint centers; use the joint names from get_rig.

```

- [ ] **Step 3: Verify the whole build** — Run: `stylua src && selene src 2>&1 | tail -3 && stylua --check src && echo "stylua clean"`
Expected: `0 errors / 0 warnings` and `stylua clean`.
Then Run (PowerShell): `.\build.ps1`
Expected: `Built project to StudioAgent.rbxm` + `Installed -> ...Plugins\StudioAgent.rbxm`.

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat: document the rig tools (Rigs & posing) in SystemPrompt"
```

---

## Task 4: In-Studio verification (user restart + assistant drives)

**Files:** none (verification only; assistant has done all static verification).

- [ ] **Step 1: Spec self-test (user, in Studio)** — temporarily add `require(script.RigWorkbenchSpec).run()` near the end of `src/init.server.luau`; `.\build.ps1`; reopen Studio; read Output. Expected: `[RigWorkbenchSpec] 3/3 passed`. Remove the temp line + rebuild.

- [ ] **Step 2: Live test (user restarts Studio so the build loads; assistant drives via computer-use)**
1. `spawn_rig` → a blocky R6 dummy appears in Workspace.
2. `get_rig` on it → the joint list returns AND green joint markers + blue bones appear (you SEE the skeleton). Verify the markers sit at the shoulders/hips/neck/root.
3. `pose_joint` "Right Shoulder" rotation {z:-70} → the right arm visibly rotates up/out; `pose_joint` "Right Hip" {x:60} → the leg lifts. Confirm the parts move and the skeleton gizmos follow.
4. `camera_focus` + `camera_orbit` → inspect the pose from several angles.
5. `reset_pose` → the rig returns to neutral.
6. **R15:** `spawn_rig {type:"r15"}` → a blocky R15 dummy; `get_rig` shows 15 joints (Root/Waist/Neck/RightShoulder/RightElbow/RightWrist/RightHip/RightKnee/RightAnkle + left); `pose_joint` "RightElbow" {x:-90} and "RightKnee" {x:80} → confirm R15 reads + poses. (Optional: insert a real R15 via Studio's Rig Builder and pose that too, to confirm operate-on-existing on a non-spawned rig.)
7. `show_skeleton {on:false}` → gizmos clear. Clean up the spawned rig.

- [ ] **Step 3: Report** — if the Spec passes + the live checks hold, slice A is delivered. Watch specifically for: (a) the unanchored limbs staying put before posing (Motor6D should hold them in edit — if they drift, note it for a fix), (b) skeleton gizmos rendering (Neon parts are proven; if not visible, check the folder in Explorer). Debug from the symptom; the static layer is green.

---

## Self-review (completed by author)

- **Spec coverage:** spawn (blocky placeholder, correct-by-construction) → `RigWorkbench.spawn` + `RigTemplates` (Task 1) + `spawn_rig` (Task 2). Read + visualize skeleton → `readSkeleton`/`drawSkeleton` (Task 1) + `get_rig`/`show_skeleton` (Task 2). Pose via `Motor6D.Transform` → `poseJoint`/`applyRotation` (Task 1) + `pose_joint` (Task 2). Reset → `resetPose`/`reset_pose`. Rig-agnostic (real R6/R15) → `jointsOf` walks any rig; Task 4 step 6 tests R15. ChangeHistory/undo → `beginRecording`/`finishRecording` (Task 1). Composes with camera rig → Task 4 step 4 + SystemPrompt. Stateless (no deps/threading) → confirmed (Task 2 requires the module directly; no init.server/AgentLoop/Widget/Relay changes). Testing → Task 1 Spec + Task 3 build + Task 4. **No gaps.**
- **Placeholder scan:** none — full code in every new file; every edit names the exact anchor + inserted code.
- **Type/name consistency:** `RigWorkbench.{rotationCFrame,applyRotation,jointsOf,findJoint,readSkeleton,drawSkeleton,clearSkeleton,poseJoint,resetPose,spawn}`, `RigTemplates.get` + the `Template`/`PartDef`/`JointDef` shapes (`name/size/pos`, `name/part0/part1/pivot/host`), the 5 tool names, and `require(script.Parent.Parent.RigWorkbench)` / `require(script.Parent.RigTemplates)` paths are consistent across Tasks 1-3. Posing uses `Motor6D.Transform` throughout (not C0).
