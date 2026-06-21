# Animation Engine (Slice D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a native, edit-mode animation engine — author a clip as a flip-book of keyposes (snapshot `Motor6D.Transform` into a `KeyframeSequence` under `rig/AnimSaves`), preview it as a scrub-and-sample filmstrip, and lightly attempt export.

**Architecture:** A stateless engine module `src/AnimationClip.luau` builds keyframes (the proven nested-`Pose`-tree construction) and manages a `KeyframeSequence` in the rig's `AnimSaves` folder (the Animation Editor's convention). `src/Tools/Animate.luau` exposes 5 thin tools (`add_keyframe`/`list_clip`/`remove_keyframe`/`clear_clip`/`export_animation`). The dormant `capture_animation` in `src/Tools/Capture.luau` becomes the real filmstrip: register → play → `TimePosition` scrub + `StepAnimations(0)` → restore. Every mechanism was proven live via the dev bridge this session (LIVE-TEST #2 passed).

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — verification is `selene`/`stylua`/`rojo build` (static) + a **bridge dogfood** (`scripts/studio-agent.ps1`) after a Studio restart, plus an in-Studio `AnimationClipSpec`.

**Source of truth:** [`docs/superpowers/specs/2026-06-21-studio-agent-animation-engine-design.md`](../specs/2026-06-21-studio-agent-animation-engine-design.md).

---

## Proven facts (the spike, this session — do not re-derive)

- Build a clip from the Motor6D graph as a nested `Pose` tree rooted at `HumanoidRootPart` (`Pose.Name` = child part name, `Pose.CFrame` = that joint's `Motor6D.Transform`). **`ks:AddKeyframe(kf)` is REQUIRED** — bare `kf.Parent = ks` left `track.Length = 0`.
- `KeyframeSequenceProvider:RegisterKeyframeSequence(ks)` → a local content-hash id usable as `Animation.AnimationId` (no upload). Do NOT use `RegisterActiveKeyframeSequence` (returned a null `active://0`).
- Preview: `LoadAnimation` → `track:Play(0)` → set `track.TimePosition = t` → `Animator:StepAnimations(0)` evaluates the clip at `t` with Roblox's own interpolation. Only animated joints move.
- After `track:Stop()` + restoring `Motor6D.Transform` + `applyPose` (StepAnimations(0), no playing track), manual posing works again — so preview must tear its track down and restore the working pose.

---

## File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/AnimationClip.luau` | **new** | Engine core: `buildPoseTree`, `getOrCreateClip`/`findClip`, `currentTransforms`, `snapshotKeyframe`, `removeKeyframe`, `clearClip`, `summary`, `register`, `appendTime` + pure helpers (`normalizeTime`, `adjacency`, `rigRoot`). |
| `src/AnimationClipSpec.luau` | **new** | In-Studio self-test for the pure parts (no spawn/web). |
| `src/Tools/Animate.luau` | **new** | Descriptors `add_keyframe`, `list_clip`, `remove_keyframe`, `clear_clip`, `export_animation`. |
| `src/Tools/Capture.luau` | mod | `runAnimation` stub → real scrub-and-sample filmstrip; `capture_animation` gains a `clip` input + an edit-mode description. |
| `src/Tools/init.luau` | mod | Register the Animate descriptors. |
| `src/SystemPrompt.luau` | mod | "Animating" section; fix the stale `spawn_rig` wording in "Rigs & posing". |
| `src/RelaySpec.luau` | mod | Bring the relay/local classification current (clears pre-existing drift) + add the 5 new tools (all relay). |

---

## Task 1: `AnimationClip.luau` + pure spec

**Files:**
- Create: `src/AnimationClip.luau`
- Create: `src/AnimationClipSpec.luau`

- [ ] **Step 1: Write `src/AnimationClip.luau`**

```lua
--!strict
-- AnimationClip: the animation engine core. Author a clip as a flip-book of keyposes -- snapshot the
-- rig's current Motor6D.Transform per joint into a Keyframe (a nested Pose tree mirroring the Motor6D
-- graph), accumulate keyframes in a KeyframeSequence stored under rig/AnimSaves/<clipName> (the official
-- Animation Editor's folder convention, so the human can refine the agent's clip there). PREVIEW lives in
-- Tools/Capture (register -> play -> scrub StepAnimations). STATELESS: operates on rigs/clips in the
-- DataModel. Proven live (the spike): ks:AddKeyframe (NOT bare .Parent) is required for the clip length to
-- register; RegisterKeyframeSequence -> a local content-hash id (no upload).

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local AnimationClip = {}

local ANIMSAVES = "AnimSaves"
local TIME_EPSILON = 1e-3 -- keyframes within this many seconds share a time slot
local DEFAULT_GAP = 0.5 -- append-time gap when add_keyframe is given no time

-- ---- pure helpers (unit-tested) ----

-- Round a time to the millisecond and clamp to >= 0 (the keyframe time-slot key). NaN -> 0.
function AnimationClip.normalizeTime(t: number): number
	if t ~= t or t < 0 then
		return 0
	end
	return math.floor(t * 1000 + 0.5) / 1000
end

-- Part0 -> { Motor6D } adjacency (walk the joint graph root->leaf).
function AnimationClip.adjacency(rig: Instance): { [Instance]: { Motor6D } }
	local childrenOf: { [Instance]: { Motor6D } } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			local p0 = d.Part0 :: Instance
			local list = childrenOf[p0]
			if list == nil then
				list = {}
				childrenOf[p0] = list
			end
			table.insert(list, d)
		end
	end
	return childrenOf
end

-- The rig's root part: HumanoidRootPart if present, else the Part0 that is never any Motor6D's Part1.
function AnimationClip.rigRoot(rig: Instance): Instance?
	local hrp = rig:FindFirstChild("HumanoidRootPart")
	if hrp ~= nil then
		return hrp
	end
	local isChild: { [Instance]: boolean } = {}
	local part0s: { Instance } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			isChild[d.Part1 :: Instance] = true
			table.insert(part0s, d.Part0 :: Instance)
		end
	end
	for _, p in part0s do
		if not isChild[p] then
			return p
		end
	end
	return nil
end

-- Build the nested Pose tree for one keyframe. Pose.Name = the CHILD part name; Pose.CFrame =
-- transformsMap[childName] (the joint's Motor6D.Transform) or identity. The root part's pose is identity
-- (it drives no joint). Returns the root Pose (parent it to a Keyframe), or nil if there is no rig root.
function AnimationClip.buildPoseTree(rig: Instance, transformsMap: { [string]: CFrame }): Instance?
	local childrenOf = AnimationClip.adjacency(rig)
	local root = AnimationClip.rigRoot(rig)
	if root == nil then
		return nil
	end
	local visited: { [Instance]: boolean } = {}
	local function makePose(part: Instance): Instance
		visited[part] = true
		local pose = Instance.new("Pose")
		pose.Name = part.Name
		pose.CFrame = transformsMap[part.Name] or CFrame.identity
		pose.EasingStyle = Enum.PoseEasingStyle.Linear
		for _, m in (childrenOf[part] or {}) do
			local child = (m :: Motor6D).Part1 :: Instance
			if not visited[child] then
				makePose(child).Parent = pose
			end
		end
		return pose
	end
	return makePose(root)
end

-- ---- clip storage (rig/AnimSaves/<clipName> -- the Animation Editor convention) ----

local function animSaves(rig: Instance): Folder
	local f = rig:FindFirstChild(ANIMSAVES)
	if f ~= nil and f:IsA("Folder") then
		return f :: Folder
	end
	local nf = Instance.new("Folder")
	nf.Name = ANIMSAVES
	nf.Parent = rig
	return nf
end

function AnimationClip.getOrCreateClip(rig: Instance, clipName: string): KeyframeSequence
	local folder = animSaves(rig)
	local existing = folder:FindFirstChild(clipName)
	if existing ~= nil and existing:IsA("KeyframeSequence") then
		return existing :: KeyframeSequence
	end
	local ks = Instance.new("KeyframeSequence")
	ks.Name = clipName
	ks.Loop = false
	ks.Priority = Enum.AnimationPriority.Action
	ks.Parent = folder
	return ks
end

function AnimationClip.findClip(rig: Instance, clipName: string): KeyframeSequence?
	local folder = rig:FindFirstChild(ANIMSAVES)
	if folder == nil then
		return nil
	end
	local existing = folder:FindFirstChild(clipName)
	if existing ~= nil and existing:IsA("KeyframeSequence") then
		return existing :: KeyframeSequence
	end
	return nil
end

-- The rig's current Motor6D.Transform per joint, keyed by the CHILD part name (matches Pose.Name).
function AnimationClip.currentTransforms(rig: Instance): { [string]: CFrame }
	local map: { [string]: CFrame } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 ~= nil then
			map[(d.Part1 :: Instance).Name] = d.Transform
		end
	end
	return map
end

-- ---- timeline read helpers ----

local function sortedTimes(ks: KeyframeSequence): { number }
	local times: { number } = {}
	for _, kf in ks:GetKeyframes() do
		table.insert(times, kf.Time)
	end
	table.sort(times)
	return times
end

local function posedCount(kf: Keyframe): number
	local n = 0
	for _, d in kf:GetDescendants() do
		if d:IsA("Pose") and d.CFrame ~= CFrame.identity then
			n += 1
		end
	end
	return n
end

-- One-line-per-keyframe summary of a clip.
function AnimationClip.summary(rig: Instance, clipName: string): string
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '" .. clipName .. "' under " .. rig.Name .. "/" .. ANIMSAVES .. " (add_keyframe first)."
	end
	local kfs = ks:GetKeyframes()
	if #kfs == 0 then
		return clipName .. ": empty (0 keyframes). Pose the rig, then add_keyframe."
	end
	local times = sortedTimes(ks)
	local length = times[#times]
	local lines: { string } = {
		string.format(
			"%s: %d keyframes, length %.3fs, loop=%s, priority=%s",
			clipName,
			#kfs,
			length,
			tostring(ks.Loop),
			ks.Priority.Name
		),
	}
	local byTime: { [number]: Keyframe } = {}
	for _, kf in kfs do
		byTime[kf.Time] = kf
	end
	for _, t in times do
		local kf = byTime[t]
		if kf ~= nil then
			table.insert(lines, string.format("  t=%.3fs: %d posed joints", t, posedCount(kf)))
		end
	end
	return table.concat(lines, "\n")
end

-- ---- mutations (the tool wraps these in a ChangeHistory recording) ----

-- Snapshot the rig's CURRENT pose into the clip at `time` (replacing any keyframe at that time slot).
function AnimationClip.snapshotKeyframe(rig: Instance, clipName: string, time: number): (string, boolean)
	if AnimationClip.rigRoot(rig) == nil then
		return "no Motor6D rig found under " .. rig.Name .. " (spawn_rig or select a rig).", false
	end
	local t = AnimationClip.normalizeTime(time)
	local ks = AnimationClip.getOrCreateClip(rig, clipName)
	for _, kf in ks:GetKeyframes() do
		if math.abs(kf.Time - t) <= TIME_EPSILON then
			kf:Destroy()
		end
	end
	local pose = AnimationClip.buildPoseTree(rig, AnimationClip.currentTransforms(rig))
	if pose == nil then
		return "could not build a pose for " .. rig.Name, false
	end
	local kf = Instance.new("Keyframe")
	kf.Time = t
	pose.Parent = kf
	ks:AddKeyframe(kf) -- AddKeyframe, NOT bare .Parent (the spike: bare .Parent leaves length=0)
	return AnimationClip.summary(rig, clipName), true
end

-- Remove the keyframe nearest `time`. Returns (text, ok).
function AnimationClip.removeKeyframe(rig: Instance, clipName: string, time: number): (string, boolean)
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '" .. clipName .. "' to edit under " .. rig.Name, false
	end
	local t = AnimationClip.normalizeTime(time)
	local target: Keyframe? = nil
	local best = math.huge
	for _, kf in ks:GetKeyframes() do
		local d = math.abs(kf.Time - t)
		if d < best then
			best = d
			target = kf
		end
	end
	if target == nil then
		return clipName .. " has no keyframes to remove.", false
	end
	local removedAt = target.Time
	target:Destroy()
	return string.format("removed keyframe at t=%.3fs from %s.\n%s", removedAt, clipName, AnimationClip.summary(rig, clipName)),
		true
end

-- Remove all keyframes (keeps the empty KeyframeSequence). Returns (text, ok).
function AnimationClip.clearClip(rig: Instance, clipName: string): (string, boolean)
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return "no clip '" .. clipName .. "' to clear under " .. rig.Name, false
	end
	local n = 0
	for _, kf in ks:GetKeyframes() do
		kf:Destroy()
		n += 1
	end
	return string.format("cleared %d keyframes from %s.", n, clipName), true
end

-- Register the clip locally -> a content-hash AnimationId (no upload). (id, nil) or (nil, err).
function AnimationClip.register(ks: KeyframeSequence): (string?, string?)
	local ok, id = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(ks)
	end)
	if not ok or type(id) ~= "string" then
		return nil, "RegisterKeyframeSequence failed: " .. tostring(id)
	end
	return id, nil
end

-- The append time for a new keyframe: last keyframe time + DEFAULT_GAP (0 for the first).
function AnimationClip.appendTime(rig: Instance, clipName: string): number
	local ks = AnimationClip.findClip(rig, clipName)
	if ks == nil then
		return 0
	end
	local times = sortedTimes(ks)
	if #times == 0 then
		return 0
	end
	return AnimationClip.normalizeTime(times[#times] + DEFAULT_GAP)
end

return AnimationClip
```

- [ ] **Step 2: Write `src/AnimationClipSpec.luau`**

```lua
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
		if AnimationClip.normalizeTime(0.12345) ~= 0.123 then
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
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: `stylua` clean, selene `0 errors, 0 warnings`, `rojo build` succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/AnimationClip.luau src/AnimationClipSpec.luau
git commit -m "feat: AnimationClip engine core (keyframe build from Motor6D graph) + pure spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Tools/Animate.luau` + register

**Files:**
- Create: `src/Tools/Animate.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Animate.luau`**

```lua
--!strict
-- Animate tools: author + export an animation clip as a flip-book of keyposes. add_keyframe snapshots the
-- rig's CURRENT pose into rig/AnimSaves/<clip> (a KeyframeSequence, the Animation Editor's convention);
-- list_clip/remove_keyframe/clear_clip manage the timeline; export_animation tries a programmatic publish
-- and otherwise hands off to the Animation Editor. PREVIEW is capture_animation (Tools/Capture). Thin
-- wrappers over AnimationClip + resolveRig (path or selection). DataModel edits are undoable + relay in
-- client view (absent from Relay.LOCAL_TOOLS, like pose_joint).

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local AssetService = game:GetService("AssetService")

local AnimationClip = require(script.Parent.Parent.AnimationClip)
local Path = require(script.Parent.Path)

local Animate = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local DEFAULT_CLIP = "AgentClip"

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

local function clipName(args: any): string
	return if type(args.clip) == "string" and args.clip ~= "" then args.clip else DEFAULT_CLIP
end

-- Wrap a DataModel mutation in an undoable ChangeHistory recording (edit only), like the rig tools.
local function recorded(label: string, fn: () -> (string, boolean)): (string, boolean)
	if not RunService:IsEdit() then
		return fn()
	end
	local rid = ChangeHistoryService:TryBeginRecording(label)
	local text, ok = fn()
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	return text, ok
end

local function runAdd(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "add_keyframe: " .. tostring(err), true
	end
	local clip = clipName(args)
	local time = if type(args.time) == "number" then args.time else AnimationClip.appendTime(rig, clip)
	local text, ok = recorded("Add keyframe", function()
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time)
	end)
	return text, not ok
end

local function runList(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "list_clip: " .. tostring(err), true
	end
	return AnimationClip.summary(rig, clipName(args)), false
end

local function runRemove(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "remove_keyframe: " .. tostring(err), true
	end
	if type(args.time) ~= "number" then
		return "remove_keyframe requires { rig?, clip?, time = <seconds> }", true
	end
	local text, ok = recorded("Remove keyframe", function()
		return AnimationClip.removeKeyframe(rig :: Instance, clipName(args), args.time)
	end)
	return text, not ok
end

local function runClear(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "clear_clip: " .. tostring(err), true
	end
	local text, ok = recorded("Clear clip", function()
		return AnimationClip.clearClip(rig :: Instance, clipName(args))
	end)
	return text, not ok
end

local function runExport(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "export_animation: " .. tostring(err), true
	end
	local clip = clipName(args)
	local ks = AnimationClip.findClip(rig, clip)
	if ks == nil or #ks:GetKeyframes() == 0 then
		return "export_animation: clip '" .. clip .. "' is empty or missing — add_keyframe first.", true
	end
	-- Try the in-Studio programmatic publish. As of 2026, CreateAssetAsync does NOT support Animation in
	-- Studio (Model/Plugin/Mesh/Image only), so this is EXPECTED to fail; we fall back to the manual
	-- Animation-Editor handoff. (Full Open Cloud export is a later slice.)
	local ok, result = pcall(function()
		return AssetService:CreateAssetAsync(ks, Enum.AssetType.Animation, {
			Name = clip,
			Description = "Authored by Studio Agent",
		})
	end)
	if ok and result ~= nil then
		return "export_animation: published '" .. clip .. "' -> " .. tostring(result) .. ".", false
	end
	-- Manual handoff (a SUCCESS, not an error): the clip is in AnimSaves, openable in the Animation Editor.
	return "export_animation: programmatic animation publish isn't available in Studio yet, so the clip is "
		.. "saved at "
		.. rig:GetFullName()
		.. "/AnimSaves/"
		.. clip
		.. ". To publish: open Avatar > Animation Editor, select the rig, load '"
		.. clip
		.. "', then Publish. (Automated Open Cloud export is a planned follow-up.)",
		false
end

Animate.descriptors = {
	{
		name = "add_keyframe",
		description = "Author an animation by SNAPSHOTTING the rig's current pose as a keyframe. Pose the "
			.. "rig first (pose_joint / ik_reach), then call this to capture that pose at `time` seconds "
			.. "into a clip (a KeyframeSequence saved under rig/AnimSaves/<clip>, the Animation Editor's "
			.. "folder). Repeat per keypose to build the motion. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe). Re-snapshots "
			.. "replace any keyframe already at that time. Then use capture_animation to SEE it.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = { type = "number", description = "Keyframe time in seconds (omit = append)." },
			},
		},
		destructive = true,
		run = runAdd,
	},
	{
		name = "list_clip",
		description = "Show an animation clip's timeline: each keyframe's time + how many joints are posed "
			.. "there, plus the clip length, loop, and priority. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = false,
		run = runList,
	},
	{
		name = "remove_keyframe",
		description = "Remove the keyframe nearest `time` from a clip. Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip'), time (seconds, required).",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
				time = { type = "number", description = "Time (seconds) of the keyframe to remove." },
			},
			required = { "time" },
		},
		destructive = true,
		run = runRemove,
	},
	{
		name = "clear_clip",
		description = "Remove ALL keyframes from a clip (keeps the empty clip). Inputs: rig (path or "
			.. "selection), clip (default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = true,
		run = runClear,
	},
	{
		name = "export_animation",
		description = "Publish an authored clip. Programmatic animation upload isn't available in Studio "
			.. "yet, so today this saves the clip in rig/AnimSaves and hands off to the Animation Editor "
			.. "(open it, select the rig, load the clip, Publish). Inputs: rig (path or selection), clip "
			.. "(default 'AgentClip').",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Rig path; omit to use the selection." },
				clip = { type = "string", description = "Clip name (default 'AgentClip')." },
			},
		},
		destructive = false,
		run = runExport,
	},
} :: { Descriptor }

return Animate
```

- [ ] **Step 2: Register in `src/Tools/init.luau`**

After the line `local IkTool = require(script.Ik)` (around line 36), add:
```lua
local AnimateTool = require(script.Animate)
```

After the `for _, descriptor in IkTool.descriptors :: { Descriptor } do ... end` block (around line 128), add:
```lua
for _, descriptor in AnimateTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

In the header comment's tool list (the `-- create_instance, ... use_skill, save_skill, delete_skill.` block near line 12-14), append after the existing tools: `add_keyframe, list_clip, remove_keyframe, clear_clip, export_animation.`

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Animate.luau src/Tools/init.luau
git commit -m "feat: animation tools (add_keyframe/list_clip/remove_keyframe/clear_clip/export_animation)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Revive `capture_animation` as the real filmstrip

**Files:**
- Modify: `src/Tools/Capture.luau`

- [ ] **Step 1: Add requires** — after `local CaptureCore = require(script.Parent.CaptureCore)` (line 11), add:
```lua
local Selection = game:GetService("Selection")
local AnimationClip = require(script.Parent.Parent.AnimationClip)
local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
local Path = require(script.Parent.Path)
```

- [ ] **Step 2: Replace the `runAnimation` stub** — replace the whole `-- ---- capture_animation (filmstrip) ----` block and the `runAnimation` function (lines ~138-152) with:

```lua
-- ---- capture_animation (filmstrip) -----------------------------------------
-- Edit-mode scrub-and-sample: register the clip/animation, Play it on a temp track, set TimePosition +
-- StepAnimations(0) per sample time (Roblox's own interpolation), capture, then restore the working pose
-- and tear the playback down. Proven live (LIVE-TEST #2).

-- get-or-create the rig's Animator (block rigs have a Humanoid). nil if the rig has no controller.
local function rigAnimator(rig: Instance): Animator?
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	if controller == nil then
		return nil
	end
	local existing = controller:FindFirstChildOfClass("Animator")
	if existing ~= nil then
		return existing
	end
	local a = Instance.new("Animator")
	a.Parent = controller
	return a
end

local function saveTransforms(rig: Instance): { [Motor6D]: CFrame }
	local map: { [Motor6D]: CFrame } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") then
			map[d :: Motor6D] = (d :: Motor6D).Transform
		end
	end
	return map
end

local function restoreTransforms(map: { [Motor6D]: CFrame })
	for m, cf in map do
		m.Transform = cf
	end
end

-- Resolve (rig, animationId, err). Source = a working `clip` (AnimSaves under the rig) or `animation`
-- (an asset id, or a path to a KeyframeSequence instance). rig = path arg or the current selection.
local function resolveSource(args: any): (Instance?, string?, string?)
	local rig: Instance? = nil
	if type(args.rig) == "string" and args.rig ~= "" then
		rig = Path.resolve(args.rig)
	else
		local sel = Selection:Get()
		rig = if #sel > 0 then sel[1] else nil
	end
	if rig == nil then
		return nil, nil, "capture_animation: no rig given and nothing selected — pass a rig path or select it."
	end
	if not rig:IsA("Model") then
		return nil, nil, "capture_animation: the rig must be a Model (with a bounding box)."
	end
	if type(args.clip) == "string" and args.clip ~= "" then
		local ks = AnimationClip.findClip(rig, args.clip)
		if ks == nil then
			return nil, nil, "capture_animation: no clip '" .. args.clip .. "' under " .. rig.Name .. "/AnimSaves."
		end
		local id, ierr = AnimationClip.register(ks)
		if id == nil then
			return nil, nil, "capture_animation: " .. tostring(ierr)
		end
		return rig, id, nil
	end
	if type(args.animation) == "string" and args.animation ~= "" then
		local maybe = Path.resolve(args.animation)
		if maybe ~= nil and maybe:IsA("KeyframeSequence") then
			local id, ierr = AnimationClip.register(maybe :: KeyframeSequence)
			if id == nil then
				return nil, nil, "capture_animation: " .. tostring(ierr)
			end
			return rig, id, nil
		end
		local raw = args.animation :: string
		local id = if string.match(raw, "^%d+$") ~= nil then "rbxassetid://" .. raw else raw
		return rig, id, nil
	end
	return nil, nil, "capture_animation: pass a working `clip` name or an `animation` (asset id / KeyframeSequence path)."
end

local function runAnimation(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, animId, serr = resolveSource(args)
	if rig == nil or animId == nil then
		return serr :: string, true
	end
	local animator = rigAnimator(rig)
	if animator == nil then
		return "capture_animation: the rig has no Humanoid or AnimationController, so it can't play an "
			.. "animation. Use a native rig (spawn_rig) or add an AnimationController.",
			true
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local okLoad, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not okLoad or track == nil then
		return "capture_animation: couldn't load the animation (" .. tostring(track) .. ").", true
	end
	local animTrack = track :: AnimationTrack
	animTrack.Priority = Enum.AnimationPriority.Action
	animTrack:Play(0)

	-- poll for the clip data to resolve (Length stays 0 until loaded)
	local deadline = os.clock() + 4
	while animTrack.Length <= 0 and os.clock() < deadline do
		CaptureCore.settle(1)
	end
	local length = animTrack.Length
	if length <= 0 then
		animTrack:Stop()
		return "capture_animation: the clip has no length (empty? add keyframes first).", true
	end

	local frames = if type(args.frames) == "number" and args.frames >= 2 then math.floor(args.frames) else 8
	frames = math.min(frames, 20)
	local startT = if type(args.startTime) == "number" then math.max(0, args.startTime) else 0
	local endT = if type(args.endTime) == "number" then math.min(args.endTime, length) else length
	if endT <= startT then
		startT, endT = 0, length
	end

	local preset = CaptureCore.PRESETS[string.lower(tostring(args.angle))] or CaptureCore.PRESETS.front
	local boundCF, boundSize = (rig :: Model):GetBoundingBox()

	local savedTransforms = saveTransforms(rig)
	local savedCam = CaptureCore.saveCamera()
	CaptureCore.setCamera(CaptureCore.frameCFrame(boundCF.Position, boundSize, preset.yaw, preset.pitch, 1))

	local since = os.time() - 2
	local triggered = 0
	local labels: { string } = {}
	local okAll = pcall(function()
		for i = 0, frames - 1 do
			local t = startT + (endT - startT) * (i / (frames - 1))
			animTrack.TimePosition = t
			animator:StepAnimations(0)
			CaptureCore.settle(2)
			if CaptureCore.triggerCapture() then
				triggered += 1
				table.insert(labels, string.format("%.2fs", t))
			end
		end
	end)

	-- restore everything (always): stop playback, restore the working pose, re-show it, restore the camera.
	animTrack:Stop()
	restoreTransforms(savedTransforms)
	RigWorkbench.applyPose(rig)
	CaptureCore.restoreCamera(savedCam)

	if not okAll or triggered == 0 then
		return "capture_animation: failed to sample the animation (state restored).", true
	end
	local blocks, err = CaptureCore.fetchCaptures(triggered, since, getConfig(context))
	if blocks == nil then
		return err :: string, true
	end
	local content: { any } = {
		{
			type = "text",
			text = string.format("%d-frame filmstrip (%.2fs to %.2fs):", #blocks, startT, endT),
		},
	}
	for i, b in blocks do
		local label = if labels[i] ~= nil then labels[i] else tostring(i)
		table.insert(content, { type = "text", text = string.format("frame %d/%d — t=%s", i, #blocks, label) })
		table.insert(content, b)
	end
	return content, false
end
```

- [ ] **Step 3: Update the `capture_animation` descriptor** — replace its `description` and `inputSchema` (the entry near line 205-235) with:

```lua
		name = "capture_animation",
		description = "See an animation as a time-sampled FILMSTRIP from a fixed angle, so you can review a "
			.. "motion end-to-end in edit. Source: a working `clip` (a clip you authored with add_keyframe, "
			.. "under rig/AnimSaves) OR an existing `animation` (an asset id or a KeyframeSequence path). It "
			.. "registers + plays the clip and samples frames across time (no upload). Inputs: rig (path or "
			.. "selection), clip OR animation, frames (default 8), startTime/endTime (seconds; default full "
			.. "clip), angle (front/back/left/right/top/bottom/iso). LOOK at the frames and iterate. Restores "
			.. "your working pose when done.",
		inputSchema = {
			type = "object",
			properties = {
				rig = { type = "string", description = "Path to the rig (Model with an Animator/Humanoid); omit to use the selection." },
				clip = { type = "string", description = "A working clip name under rig/AnimSaves (e.g. 'AgentClip')." },
				animation = { type = "string", description = "An existing animation: asset id or a KeyframeSequence path." },
				frames = { type = "number", description = "Number of time samples (default 8, max 20)." },
				startTime = { type = "number", description = "Start time in seconds (default 0)." },
				endTime = { type = "number", description = "End time in seconds (default clip length)." },
				angle = { type = "string", description = "A preset angle (front/back/left/right/top/bottom/iso)." },
			},
		},
		destructive = false,
		run = runAnimation,
```

(Note: the `required = { "rig", "animation" }` is removed — rig defaults to selection, and the source can be `clip` OR `animation`.)

- [ ] **Step 4: Update the file's top comment** — in the header comment, change the `capture_animation` line from `filmstrip: time-sampled frames of an animation (review a motion).` to `filmstrip: time-sampled frames of a clip/animation via TimePosition scrub + StepAnimations (edit-mode).`

- [ ] **Step 5: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 6: Commit**

```bash
git add src/Tools/Capture.luau
git commit -m "feat: capture_animation filmstrip via TimePosition scrub + StepAnimations (edit-mode)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: SystemPrompt — Animating section + fix stale spawn_rig wording

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Fix the stale `spawn_rig` wording** — in the "# Rigs & posing" section, replace:
```
spawn_rig({type="r6"|"r15"}) makes a blocky placeholder rig to practice on, or operate on a real R6/R15 rig the user inserted (Studio's Rig Builder) — the tools work on ANY Motor6D rig.
```
with:
```
spawn_rig({type="block"|"avatar"}) spawns a real NATIVE R15 rig to pose/animate (block = the standard R15 rig; avatar = a userId's character) — or operate on any Motor6D rig the user inserted (Studio's Rig Builder); the tools work on ANY Motor6D rig.
```

- [ ] **Step 2: Add the "# Animating (keyframe clips)" section** — immediately AFTER the "# Rigs & posing" paragraph (before "# Inspecting visually (camera rig)"), insert:

```
# Animating (keyframe clips)
Build an animation as a FLIP-BOOK of keyposes on a Motor6D rig, all in edit mode: pose the rig (pose_joint / ik_reach) into a keypose, then add_keyframe to SNAPSHOT that pose as a keyframe; repeat per pose; then capture_animation to SEE the motion as a filmstrip and iterate. Tools:
- add_keyframe(rig?, clip?, time?): snapshot the rig's current pose into the clip at `time` seconds (omit time to append after the last keyframe). The clip is a KeyframeSequence saved under rig/AnimSaves/<clip> (default "AgentClip") — the Animation Editor's own folder, so the user can refine it there.
- list_clip(rig?, clip?): show the clip's keyframes (times + posed-joint counts) and length.
- remove_keyframe(rig?, clip?, time) / clear_clip(rig?, clip?): edit the timeline.
- capture_animation(rig?, clip?|animation?, frames?, startTime?, endTime?, angle?): preview a clip (or any existing animation by asset id / KeyframeSequence path) as a time-sampled filmstrip from a fixed angle — the real way to review motion in edit. Always LOOK at the frames, then adjust a keypose and preview again.
- export_animation(rig?, clip?): publish the clip; today it hands off to the Animation Editor (open it, load the clip from AnimSaves, Publish).
KEY RULE: previewing plays the clip on an Animator, which temporarily OVERRIDES manual poses; capture_animation restores your pose and tears the playback down when it finishes. Author keyposes with NO preview running.
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "docs(prompt): Animating section (flip-book keyposes); fix stale spawn_rig wording" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: RelaySpec — classify the new tools (and clear pre-existing drift)

**Files:**
- Modify: `src/RelaySpec.luau`

The `EXPECTED_LOCAL`/`EXPECTED_RELAY` lists predate the rig/IK/camera/rubric tools, so the "no drift"
case is already stale. Bring both lists fully current (so the test passes again) AND add the 5 new
animation tools (all relay — they mutate/read the DataModel; absent from `Relay.LOCAL_TOOLS`).

- [ ] **Step 1: Replace the `EXPECTED_LOCAL` and `EXPECTED_RELAY` blocks** (lines ~13-37) with:

```lua
-- The custom (locally-dispatchable) tools, partitioned by where they run in client-view play. Must match
-- Relay.LOCAL_TOOLS: plugin/panel-state-only tools run LOCAL; everything else relays to the server copy.
local EXPECTED_LOCAL = {
	"update_tasks",
	"remember",
	"forget",
	"use_skill",
	"save_skill",
	"delete_skill",
	"use_rubric",
	"camera_focus",
	"camera_orbit",
	"camera_release",
}
local EXPECTED_RELAY = {
	"run_luau",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"set_property",
	"create_instance",
	"destroy_instance",
	"place_relative",
	"capture",
	"capture_angles",
	"capture_animation",
	"dispatch_subagents",
	"dispatch_writers",
	"spawn_rig",
	"get_rig",
	"pose_joint",
	"reset_pose",
	"show_skeleton",
	"ik_reach",
	"add_keyframe",
	"list_clip",
	"remove_keyframe",
	"clear_clip",
	"export_animation",
}
```

- [ ] **Step 2: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/RelaySpec.luau
git commit -m "test(relay): classify animation tools as relay + bring local/relay lists current" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full verify + bridge dogfood + HANDOFF

**Files:** `src/init.server.luau` (temporary spec require, reverted in Step 6); `HANDOFF.md`.

- [ ] **Step 1: Temporarily wire the specs** — in `src/init.server.luau`, add near the other startup code a temporary block (so the one restart in Step 2 runs the specs):
```lua
require(script.AnimationClipSpec).run()
require(script.RelaySpec).run()
```

- [ ] **Step 2: Build + install + restart**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`
Expected: selene `0 errors, 0 warnings`; `Installed -> …\Plugins\StudioAgent.rbxm`.
Then the **USER restarts Studio** ("Restart to update") on a fresh Baseplate (the bridge can't hot-reload itself). The sidecar + bridge + tunnel are already running.

- [ ] **Step 3: Confirm the specs passed** — read the plugin Output via the bridge:
```bash
powershell -File scripts/studio-agent.ps1 logs
```
Expected lines: `[AnimationClipSpec] 4/4 passed` and `RelaySpec ... Summary: N/N passed, 0 failed`. (Invoke the CLI from the PowerShell tool as `& scripts/studio-agent.ps1 …` — a nested `powershell -File …` strips inner double-quotes.)

- [ ] **Step 4: Dogfood the author -> preview -> iterate loop, and LOOK** (the verification that matters — a clear filmstrip, not coordinates):
```bash
& scripts/studio-agent.ps1 tool spawn_rig '{"type":"block"}'
& scripts/studio-agent.ps1 tool ik_reach '{"rig":"Workspace.AgentRig","chain":"RightArm","target":{"x":0.3,"y":4.0,"z":-2.3}}'
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.AgentRig","time":0}'
& scripts/studio-agent.ps1 tool reset_pose '{"rig":"Workspace.AgentRig"}'
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.AgentRig","time":0.5}'
& scripts/studio-agent.ps1 tool list_clip '{"rig":"Workspace.AgentRig"}'
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.AgentRig","frames":5,"angle":"front"}'
```
- `list_clip` → 2 keyframes, length ~0.5s. `capture_animation` returns `ok=True` and a 5-frame filmstrip (its frames go to the in-Studio model as image blocks; the bridge marks the tool content non-text).
- **To LOOK at the sweep**, pull the 5 newest frames the tool wrote to disk and Read a couple (the `capture` helper only pulls one):
```powershell
$r = Invoke-RestMethod "http://127.0.0.1:8389/captures?count=5&b64=1"
for ($i=0; $i -lt $r.images.Count; $i++) { [IO.File]::WriteAllBytes("C:/Users/manso/AppData/Local/Temp/frame$i.png", [Convert]::FromBase64String($r.images[$i])) }
```
  Then Read `frame0.png` … `frame4.png` and confirm: across frames the right arm sweeps between raised and neutral while the body stays put; the filmstrip reads as motion (a clear image is the verification, not the coordinates).
- Confirm control returned after preview: `& scripts/studio-agent.ps1 tool pose_joint '{"rig":"Workspace.AgentRig","joint":"LeftShoulder","rotation":{"z":40},"relative":false}'` then `capture` — the left arm moves (posing still works after a preview).
- `& scripts/studio-agent.ps1 tool export_animation '{"rig":"Workspace.AgentRig"}'` → returns either an asset id or the Animation-Editor handoff note.
- Confirm the clip is Editor-openable: `& scripts/studio-agent.ps1 luau 'return tostring(workspace.AgentRig:FindFirstChild("AnimSaves") ~= nil)'` → `true`.
- Clean up: `& scripts/studio-agent.ps1 tool destroy_instance '{"path":"Workspace.AgentRig"}'`. **Don't touch the user's `Rig` model.**

- [ ] **Step 5: (Recommended) adversarial review** — dispatch a code-review Workflow / subagents over `AnimationClip.luau` + `Tools/Animate.luau` + the `capture_animation` rewrite (the logic that can't be run locally), refute-biased; fix any confirmed findings and re-verify static + dogfood.

- [ ] **Step 6: Revert the temporary spec require** — remove the two `require(...).run()` lines from `src/init.server.luau` (added in Step 1).

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: clean build (the shipped plugin no longer self-runs the specs at load).

- [ ] **Step 7: Update HANDOFF.md + commit** — add a dated block: the animation engine (slice D) shipped + bridge-verified (flip-book keyposes -> AnimSaves KeyframeSequence; capture_animation filmstrip via scrub + StepAnimations; light export handoff; Open Cloud export is the next slice). Commit.

```bash
git add HANDOFF.md src/init.server.luau
git commit -m "docs: animation engine (slice D) shipped + bridge-verified; revert spec auto-run" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** flip-book authoring → Task 1 (`buildPoseTree`/`snapshotKeyframe`) + Task 2 (`add_keyframe`); AnimSaves `KeyframeSequence` storage → Task 1 (`getOrCreateClip`); timeline read/edit → Tasks 1-2 (`summary`/`removeKeyframe`/`clearClip` + `list_clip`/`remove_keyframe`/`clear_clip`); native filmstrip preview → Task 3 (`capture_animation` scrub + StepAnimations + restore); §4.4 mode isolation → Task 3 (save/restore Transforms + `track:Stop()` + `applyPose`); light export → Task 2 (`export_animation` try + handoff); wiring → Tasks 2 (init) / 4 (SystemPrompt) / 5 (RelaySpec); testing → Task 1 (`AnimationClipSpec`) + Task 6 (dogfood + adversarial review). All spec sections covered.
- **Placeholder scan:** every code step is complete (no TBD/TODO); the only "future" item is the Open Cloud export, scoped out as a non-goal in the spec and referenced in `export_animation`'s handoff text.
- **Type/name consistency:** `AnimationClip.buildPoseTree/rigRoot/adjacency/currentTransforms/getOrCreateClip/findClip/snapshotKeyframe/removeKeyframe/clearClip/summary/register/appendTime/normalizeTime` (Task 1) are the exact names called by `Tools/Animate.luau` (Task 2) and `Tools/Capture.luau` (Task 3). `RigWorkbench.applyPose(rig)` (existing) is reused by Task 3. `CaptureCore.PRESETS/frameCFrame/saveCamera/setCamera/restoreCamera/settle/triggerCapture/fetchCaptures` (existing) are used by Task 3 with their real signatures. `Path.resolve` (existing) is used by Tasks 2-3. The 5 new tool names match between Task 2 (descriptors), Task 4 (SystemPrompt), and Task 5 (RelaySpec).
- **Known robustness notes baked in:** `ks:AddKeyframe` (not `.Parent`); preview always restores Transforms + camera in a pcall-protected path; `export` falls back on any `CreateAssetAsync` outcome (signature-agnostic, expected to handoff); rig-must-be-a-Model guard before `GetBoundingBox`; visited-set guard in `buildPoseTree` against a malformed cyclic graph.
