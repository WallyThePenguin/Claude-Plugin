# Item Use-Animations (`bind_animation` + joint-scoped authoring) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a handheld `Tool` ANIMATE correctly when used — equip plays a looping idle-hold, activate plays a swing/use clip that moves ONLY the arm (the legs/torso keep their own locomotion), and the welded item swings with it. Roadmap sub-project #2, building on #1 (`make_tool`/`grip_tool`).

**Architecture:** Two pieces. (1) **Joint-scoped authoring** — `AnimationClip.luau` gains a pure `scopedJointSet(preset)` + `scopeIncludeSet(rig, names)` and a scoped `buildPoseTree`/`snapshotKeyframe`, so `add_keyframe {scope='rightArm'}` keys ONLY the arm joints (+ ancestor carriers), OMITTING legs/torso. The Animator blends per joint by priority, so an Action-priority arm-only swing overrides just the arm while lower-priority locomotion drives the unkeyed legs. (2) **`bind_animation(tool, event, clip, rig?)`** (new `Tools/ItemAnim.luau`) — copies the authored `KeyframeSequence` into `tool/Anims/<event>` (idle=Loop+Idle, use=Action) and writes a CLIENT runtime LocalScript (`tool/ItemAnimRuntime`) that on Equipped plays the looped idle, on Activated plays the use swing once, on Unequipped stops — playing via `Animator:LoadAnimation` over a locally-registered KeyframeSequence (Studio-solo dev loop; publishing is a flagged follow-up).

**Tech Stack:** Luau (`--!strict`), Roblox `KeyframeSequence`/`Pose`/`Animator`/`Tool`/`KeyframeSequenceProvider:RegisterKeyframeSequence` (the runtime mechanism already PROVEN to fire in solo Studio by last session's spike), `AnimationClip` engine (existing), Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Modify `src/AnimationClip.luau`** — add pure `scopedJointSet(preset)` + `scopeIncludeSet(rig, names)`; `buildPoseTree` gains an `includeSet?` that prunes to scoped joints + ancestor carriers; `snapshotKeyframe` gains `scopeNames?` and computes the include set.
- **Modify `src/AnimationClipSpec.luau`** — a branched test rig + 3 cases (`scopedJointSet`, `scopeIncludeSet`, scoped `buildPoseTree` pruning).
- **Modify `src/Tools/Animate.luau`** — `add_keyframe` gains a `scope` input (preset string or part-name array; default unset = all joints).
- **Create `src/Tools/ItemAnim.luau`** — the `bind_animation` descriptor + the runtime LocalScript template (copy clip into `tool/Anims/<event>`, write `tool/ItemAnimRuntime`).
- **Modify `src/Tools/init.luau`** — require + append `ItemAnimTool.descriptors`; update the registry comment.
- **Modify `src/RelaySpec.luau`** — add `bind_animation` to `EXPECTED_RELAY` (no-drift).
- **Modify `src/SystemPrompt.luau`** — a `bind_animation` tool-index line, extend "# Building handheld items" with the use-animation flow, and note `scope` on `add_keyframe`.

**Luau testing note:** no local Luau runtime. The pure specs (`AnimationClipSpec`, `RelaySpec`) run *in-Studio* (or via the bridge: `& scripts/studio-agent.ps1 luau 'return tostring(require(script.Parent.AnimationClipSpec).run())'`) after a build + USER restart. The per-task static gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). `rojo build` does NOT type-check. Python n/a.

**R15 joint reference (Motor6D name → its Part1 child part, the `Pose.Name` key):** Root→LowerTorso, Waist→UpperTorso, Neck→Head, RightShoulder→RightUpperArm, RightElbow→RightLowerArm, RightWrist→RightHand, LeftShoulder→LeftUpperArm, LeftElbow→LeftLowerArm, LeftWrist→LeftHand, RightHip→RightUpperLeg, LeftHip→LeftUpperLeg (+ Knee/Ankle). Scope presets key by the **child-part name** (what `buildPoseTree`/`currentTransforms` use). `rightArm` = `{RightUpperArm, RightLowerArm, RightHand}`.

---

### Task 1: Joint-scoped authoring engine + spec

**Files:** Modify `src/AnimationClip.luau`; Modify `src/AnimationClipSpec.luau`.

- [ ] **Step 1: Write the failing spec cases**

In `src/AnimationClipSpec.luau`, add a branched test rig helper just AFTER the `miniRig` function (before `findPose`):

```lua
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
```

Then add these 3 cases inside `buildCases`, after the existing `"buildPoseTree nests poses..."` case (before `return cases`):

```lua
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
```

- [ ] **Step 2: Add the pure helpers to `src/AnimationClip.luau`**

Insert AFTER `buildPoseTree` ends (after its `return makePose(root)` / `end` at the current line ~92, before the `-- ---- clip storage ...` comment):

```lua
-- ---- joint scoping (arm-only / partial-body authoring) ----

-- A joint-scope preset -> the CHILD-part names a clip should drive (Pose.Name keys). For item use-anims,
-- "rightArm" keys ONLY the right-arm chain, so an Action-priority swing overrides just the arm while
-- lower-priority locomotion drives the unkeyed legs/torso. "upperBody" adds the left arm, torso twist,
-- and head. Returns (names, nil) or (nil, err) for an unknown preset. PURE -> unit-tested.
local SCOPE_PRESETS: { [string]: { string } } = {
	rightArm = { "RightUpperArm", "RightLowerArm", "RightHand" },
	upperBody = {
		"RightUpperArm",
		"RightLowerArm",
		"RightHand",
		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",
		"UpperTorso",
		"Head",
	},
}

function AnimationClip.scopedJointSet(preset: string): ({ string }?, string?)
	local names = SCOPE_PRESETS[preset]
	if names == nil then
		return nil, "unknown scope preset '" .. tostring(preset) .. "' (presets: rightArm, upperBody)"
	end
	-- return a copy so a caller can't mutate the shared preset table
	local out: { string } = {}
	for _, n in names do
		table.insert(out, n)
	end
	return out, nil
end

-- Expand a set of scoped CHILD-part names to also include every ANCESTOR part up to the root, so the
-- Pose tree can nest the scoped joints under their parents. The ancestors are "carriers" (posed at rest
-- since they are unposed at snapshot time) that only hold the hierarchy; sibling branches (e.g. the
-- legs, the other arm) are NOT added, so a higher-priority scoped clip overrides only the scoped joints.
-- Returns a part-name -> true set.
function AnimationClip.scopeIncludeSet(rig: Instance, names: { string }): { [string]: boolean }
	local parentOf: { [string]: string } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			parentOf[(d.Part1 :: Instance).Name] = (d.Part0 :: Instance).Name
		end
	end
	local set: { [string]: boolean } = {}
	for _, n in names do
		local cur: string? = n
		while cur ~= nil and not set[cur] do
			set[cur] = true
			cur = parentOf[cur]
		end
	end
	return set
end
```

- [ ] **Step 3: Make `buildPoseTree` accept an `includeSet` and prune**

In `src/AnimationClip.luau`, replace the `buildPoseTree` function header comment + signature and the `makePose` recursion. The CURRENT code is:

```lua
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
```

Replace it with (only the comment, signature, and the recursion guard change):

```lua
-- Build the nested Pose tree for one keyframe. Pose.Name = the CHILD part name; Pose.CFrame =
-- transformsMap[childName] (the joint's Motor6D.Transform) or identity. The root part's pose is identity
-- (it drives no joint). Returns the root Pose (parent it to a Keyframe), or nil if there is no rig root.
-- `includeSet` (optional): when given, recurse ONLY into children whose name is in the set, pruning the
-- rest of the tree — so a scoped clip (scoped joints + their ancestor carriers) drives only those joints
-- and a sibling branch (e.g. the legs) is omitted entirely. nil = the full tree (all joints).
function AnimationClip.buildPoseTree(
	rig: Instance,
	transformsMap: { [string]: CFrame },
	includeSet: { [string]: boolean }?
): Instance?
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
			if not visited[child] and (includeSet == nil or includeSet[child.Name]) then
				makePose(child).Parent = pose
			end
		end
		return pose
	end
	return makePose(root)
end
```

- [ ] **Step 4: Make `snapshotKeyframe` accept `scopeNames` and pass an include set**

In `src/AnimationClip.luau`, the CURRENT `snapshotKeyframe` is:

```lua
-- Snapshot the rig's CURRENT pose into the clip at `time` (replacing any keyframe at that time slot).
function AnimationClip.snapshotKeyframe(
	rig: Instance,
	clipName: string,
	time: number
): (string, boolean)
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
```

Replace it with (signature gains `scopeNames`, and the `buildPoseTree` call passes a computed include set):

```lua
-- Snapshot the rig's CURRENT pose into the clip at `time` (replacing any keyframe at that time slot).
-- `scopeNames` (optional): a list of CHILD-part names to key — when given (non-empty), the keyframe
-- includes Poses ONLY for those joints + their ancestor carriers (see scopeIncludeSet), so the clip
-- drives only the scoped joints (arm-only / partial-body). nil/empty = key all joints (full body).
function AnimationClip.snapshotKeyframe(
	rig: Instance,
	clipName: string,
	time: number,
	scopeNames: { string }?
): (string, boolean)
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
	local includeSet: { [string]: boolean }? = nil
	if scopeNames ~= nil and #scopeNames > 0 then
		includeSet = AnimationClip.scopeIncludeSet(rig, scopeNames)
	end
	local pose = AnimationClip.buildPoseTree(rig, AnimationClip.currentTransforms(rig), includeSet)
	if pose == nil then
		return "could not build a pose for " .. rig.Name, false
	end
	local kf = Instance.new("Keyframe")
	kf.Time = t
	pose.Parent = kf
	ks:AddKeyframe(kf) -- AddKeyframe, NOT bare .Parent (the spike: bare .Parent leaves length=0)
	return AnimationClip.summary(rig, clipName), true
end
```

- [ ] **Step 5: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` writes the rbxm. (The new spec cases run in-Studio at Task 6 — `import_animation` and `capture_animation` still call `buildPoseTree`/`snapshotKeyframe` with the old arity, which is valid since the new params are optional.)

- [ ] **Step 6: Commit**

```bash
git add src/AnimationClip.luau src/AnimationClipSpec.luau
git commit -m "feat(anim): joint-scoped keyframe authoring (scopedJointSet + scopeIncludeSet + scoped buildPoseTree) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `add_keyframe` gains a `scope` input

**Files:** Modify `src/Tools/Animate.luau`.

- [ ] **Step 1: Add a `resolveScope` helper**

In `src/Tools/Animate.luau`, add this helper just AFTER the `clipName` function (before the `recorded` helper):

```lua
-- Resolve the optional `scope` input to a list of CHILD-part names (or nil = key ALL joints). Accepts a
-- preset name ("rightArm"/"upperBody") or an explicit array of part names. Returns (names?, note, err?):
-- an unknown preset -> err; an empty/whitespace scope -> (nil, note) so add_keyframe falls back to all
-- joints with a heads-up.
local function resolveScope(scope: any): ({ string }?, string, string?)
	if scope == nil then
		return nil, "", nil
	end
	if type(scope) == "string" then
		if scope == "" then
			return nil, "", nil
		end
		local names, serr = AnimationClip.scopedJointSet(scope)
		if names == nil then
			return nil, "", serr
		end
		return names,
			"scope=" .. scope .. " (keys only the scoped joints; the rest keep their own animation).",
			nil
	end
	if type(scope) == "table" then
		local list: { string } = {}
		for _, v in scope do
			if type(v) == "string" and v ~= "" then
				table.insert(list, v)
			end
		end
		if #list == 0 then
			return nil, "scope was empty — keyed ALL joints.", nil
		end
		return list, "scope=" .. tostring(#list) .. " explicit joint(s).", nil
	end
	return nil, "", nil
end
```

- [ ] **Step 2: Thread the scope through `runAdd`**

In `src/Tools/Animate.luau`, the CURRENT `runAdd` is:

```lua
local function runAdd(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "add_keyframe: " .. tostring(err), true
	end
	local clip = clipName(args)
	local time = if type(args.time) == "number"
		then args.time
		else AnimationClip.appendTime(rig, clip)
	local text, ok = recorded("Add keyframe", function()
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time)
	end)
	return text, not ok
end
```

Replace it with:

```lua
local function runAdd(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, err = resolveRig(args.rig)
	if rig == nil then
		return "add_keyframe: " .. tostring(err), true
	end
	local clip = clipName(args)
	local scopeNames, scopeNote, scopeErr = resolveScope(args.scope)
	if scopeErr ~= nil then
		return "add_keyframe: " .. scopeErr, true
	end
	local time = if type(args.time) == "number"
		then args.time
		else AnimationClip.appendTime(rig, clip)
	local text, ok = recorded("Add keyframe", function()
		return AnimationClip.snapshotKeyframe(rig :: Instance, clip, time, scopeNames)
	end)
	if scopeNote ~= "" then
		text = scopeNote .. "\n" .. text
	end
	return text, not ok
end
```

- [ ] **Step 3: Add `scope` to the `add_keyframe` input schema + description**

In `src/Tools/Animate.luau`, the CURRENT `add_keyframe` descriptor description ends with:

```lua
			description = "Author an animation by SNAPSHOTTING the rig's current pose as a keyframe. Pose the "
				.. "rig first (pose_joint / ik_reach), then call this to capture that pose at `time` seconds "
				.. "into a clip (a KeyframeSequence saved under rig/AnimSaves/<clip>, the Animation Editor's "
				.. "folder). Repeat per keypose to build the motion. Inputs: rig (path or selection), clip "
				.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe). Re-snapshots "
				.. "replace any keyframe already at that time. Then use capture_animation to SEE it.",
```

Replace that description string with (adds a `scope` sentence):

```lua
			description = "Author an animation by SNAPSHOTTING the rig's current pose as a keyframe. Pose the "
				.. "rig first (pose_joint / ik_reach), then call this to capture that pose at `time` seconds "
				.. "into a clip (a KeyframeSequence saved under rig/AnimSaves/<clip>, the Animation Editor's "
				.. "folder). Repeat per keypose to build the motion. Inputs: rig (path or selection), clip "
				.. "(default 'AgentClip'), time (seconds; omit to append after the last keyframe), scope "
				.. "(optional — keys only a subset of joints: 'rightArm' for an item swing/use clip so the "
				.. "legs/torso keep their own animation, 'upperBody', or an array of joint child-part names; "
				.. "omit for a full-body clip). Re-snapshots replace any keyframe already at that time. Then "
				.. "use capture_animation to SEE it.",
```

And in that same descriptor's `inputSchema.properties`, the CURRENT block is:

```lua
			inputSchema = {
				type = "object",
				properties = {
					rig = { type = "string", description = "Rig path; omit to use the selection." },
					clip = { type = "string", description = "Clip name (default 'AgentClip')." },
					time = {
						type = "number",
						description = "Keyframe time in seconds (omit = append).",
					},
				},
			},
```

Replace it with (adds `scope` — no `type` so it accepts a string preset OR an array):

```lua
			inputSchema = {
				type = "object",
				properties = {
					rig = { type = "string", description = "Rig path; omit to use the selection." },
					clip = { type = "string", description = "Clip name (default 'AgentClip')." },
					time = {
						type = "number",
						description = "Keyframe time in seconds (omit = append).",
					},
					scope = {
						description = "Joint scope: 'rightArm' (key only the right-arm chain — use for "
							.. "item swing/use clips so the legs/torso keep their own animation), 'upperBody', "
							.. "or an array of joint child-part names. Omit to key ALL joints (full-body).",
					},
				},
			},
```

- [ ] **Step 4: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (`resolveScope` references `AnimationClip.scopedJointSet` from Task 1 — already required at the top of Animate.luau as `AnimationClip`.)

- [ ] **Step 5: Commit**

```bash
git add src/Tools/Animate.luau
git commit -m "feat(anim): add_keyframe gains a joint scope (rightArm/upperBody/list) for arm-only clips

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `bind_animation` tool + runtime LocalScript + registry wiring

**Files:** Create `src/Tools/ItemAnim.luau`; Modify `src/Tools/init.luau`.

- [ ] **Step 1: Create `src/Tools/ItemAnim.luau`**

```lua
--!strict
-- Item use-animation binding: bind_animation(tool, event, clip, rig?) copies an authored ARM-ONLY clip
-- into a Tool and writes a CLIENT runtime LocalScript that plays it on equip/activate. event='idle' loops
-- a held-ready pose on Equipped (Idle priority); event='use' plays a one-shot swing on Activated (Action
-- priority, which overrides the idle ON THE KEYED ARM JOINTS only — author the clip arm-scoped via
-- add_keyframe {scope='rightArm'} so the legs/torso keep their own locomotion). Dev-loop playback registers
-- the KeyframeSequence locally (RegisterKeyframeSequence, Studio-solo only); a SHIPPED/multiplayer item
-- needs a PUBLISHED AnimationId (Open Cloud) — a flagged follow-up. Destructive (DataModel writes); RELAY;
-- parent-only. See docs/superpowers/specs/2026-06-24-item-use-animations-design.md.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local AnimationClip = require(script.Parent.Parent.AnimationClip)
local Path = require(script.Parent.Path)

local ItemAnim = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

-- event -> the loop + priority the copied clip gets. idle holds (looped, low Idle priority); use swings
-- once (Action overrides the idle on the keyed arm joints).
local EVENTS: { [string]: { loop: boolean, priority: Enum.AnimationPriority } } = {
	idle = { loop = true, priority = Enum.AnimationPriority.Idle },
	use = { loop = false, priority = Enum.AnimationPriority.Action },
}

-- The CLIENT runtime LocalScript source (written into the Tool by writeRuntime). Self-contained: on
-- Equipped it loads + loops the idle clip on the character's Animator; on Activated it plays the use clip
-- once (Action priority overrides the idle on the keyed arm joints); on Unequipped it stops. Dev-loop
-- playback registers each clip locally (RegisterKeyframeSequence — Studio-solo only). ASCII-only.
local RUNTIME_SOURCE = [==[
-- ItemAnimRuntime (auto-generated by bind_animation) -- CLIENT-side Tool animation player.
-- Dev-loop ONLY: RegisterKeyframeSequence playback works in solo Studio, NOT in a shipped/multiplayer
-- game (that needs a PUBLISHED AnimationId). Do not hand-edit; bind_animation overwrites this.
local Tool = script.Parent
local KSP = game:GetService("KeyframeSequenceProvider")

local tracks = {}

local function getAnimator()
	local char = Tool.Parent
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

local function play(clipName, looped, priority)
	local anims = Tool:FindFirstChild("Anims")
	local ks = anims and anims:FindFirstChild(clipName)
	if not ks then
		return
	end
	local animator = getAnimator()
	if not animator then
		return
	end
	local ok, id = pcall(function()
		return KSP:RegisterKeyframeSequence(ks)
	end)
	if not ok or type(id) ~= "string" then
		return
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local track = animator:LoadAnimation(anim)
	track.Looped = looped
	track.Priority = priority
	track:Play()
	tracks[clipName] = track
end

Tool.Equipped:Connect(function()
	play("idle", true, Enum.AnimationPriority.Idle)
end)

Tool.Activated:Connect(function()
	play("use", false, Enum.AnimationPriority.Action)
end)

Tool.Unequipped:Connect(function()
	for _, t in tracks do
		pcall(function()
			t:Stop()
		end)
	end
	tracks = {}
end)
]==]

local function findTool(args: any): (Tool?, string?)
	if type(args.tool) ~= "string" or args.tool == "" then
		return nil,
			"bind_animation requires { tool = <path to a Tool>, event = 'idle'|'use', clip, rig? }"
	end
	local inst = Path.resolve(args.tool)
	if inst == nil or not inst:IsA("Tool") then
		return nil, "'" .. tostring(args.tool) .. "' is not a Tool (run make_tool first)"
	end
	return inst :: Tool, nil
end

-- Resolve the rig whose AnimSaves holds the source clip: an explicit path, else the selection, else the
-- first workspace Model with an AnimSaves folder, else the first Humanoid rig.
local function resolveRig(args: any): (Instance?, string?)
	if type(args.rig) == "string" and args.rig ~= "" then
		return Path.resolve(args.rig)
	end
	local sel = Selection:Get()
	if #sel > 0 then
		return sel[1], nil
	end
	for _, d in workspace:GetChildren() do
		if d:IsA("Model") and d:FindFirstChild("AnimSaves") ~= nil then
			return d, nil
		end
	end
	for _, d in workspace:GetChildren() do
		if d:IsA("Model") and d:FindFirstChildOfClass("Humanoid") ~= nil then
			return d, nil
		end
	end
	return nil, "no rig given and nothing selected — pass rig = <the rig whose AnimSaves holds the clip>."
end

-- Copy the source KeyframeSequence into tool/Anims/<event> with the event's loop+priority, replacing any
-- prior copy. Returns the stored KeyframeSequence.
local function storeClip(tool: Tool, event: string, source: KeyframeSequence): KeyframeSequence
	local anims = tool:FindFirstChild("Anims")
	if anims == nil then
		local f = Instance.new("Folder")
		f.Name = "Anims"
		f.Parent = tool
		anims = f
	end
	local existing = (anims :: Instance):FindFirstChild(event)
	if existing ~= nil then
		existing:Destroy()
	end
	local copy = source:Clone()
	copy.Name = event
	local cfg = EVENTS[event]
	copy.Loop = cfg.loop
	copy.Priority = cfg.priority
	copy.Parent = anims
	return copy
end

-- Create/refresh the runtime LocalScript under the Tool (idempotent — replaces any prior one).
local function writeRuntime(tool: Tool)
	local existing = tool:FindFirstChild("ItemAnimRuntime")
	if existing ~= nil then
		existing:Destroy()
	end
	local ls = Instance.new("LocalScript")
	ls.Name = "ItemAnimRuntime"
	ls.Source = RUNTIME_SOURCE
	ls.Parent = tool
end

-- True when the Tool's Handle is an unsaved session mesh (MeshId == "") — it will go blank in Play.
local function handleIsSessionMesh(tool: Tool): boolean
	local handle = tool:FindFirstChild("Handle")
	return handle ~= nil and handle:IsA("MeshPart") and (handle :: MeshPart).MeshId == ""
end

local function runBind(input: any, _context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	local tool, terr = findTool(args)
	if tool == nil then
		return terr, true
	end
	local event = args.event
	if type(event) ~= "string" or EVENTS[event] == nil then
		return "bind_animation: event must be 'idle' or 'use' (got " .. tostring(event) .. ")", true
	end
	if type(args.clip) ~= "string" or args.clip == "" then
		return "bind_animation requires { clip = <an authored clip under the rig's AnimSaves> }", true
	end
	local rig, rerr = resolveRig(args)
	if rig == nil then
		return "bind_animation: " .. tostring(rerr), true
	end
	local source = AnimationClip.findClip(rig :: Instance, args.clip)
	if source == nil or #source:GetKeyframes() == 0 then
		return "bind_animation: clip '"
			.. args.clip
			.. "' is empty or missing under "
			.. (rig :: Instance):GetFullName()
			.. "/AnimSaves — author it first (add_keyframe {scope='rightArm'}).",
			true
	end
	local theTool = tool :: Tool
	local theSource = source :: KeyframeSequence
	local function doBind()
		storeClip(theTool, event, theSource)
		writeRuntime(theTool)
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("bind_animation")
		doBind()
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doBind()
	end
	local cfg = EVENTS[event]
	local msg = string.format(
		"bind_animation OK: copied '%s' into %s/Anims/%s (%s, %s priority) + wrote ItemAnimRuntime (client). "
			.. "Playtest to verify: equip plays idle, click plays the %s swing.",
		args.clip,
		theTool.Name,
		event,
		(if cfg.loop then "looped" else "one-shot"),
		cfg.priority.Name,
		event
	)
	if handleIsSessionMesh(theTool) then
		msg = msg
			.. " WARNING: the Handle is a session mesh (MeshId=='') — it will go BLANK in Play. Run save_mesh on the Tool first."
	end
	msg = msg
		.. " NOTE: dev-loop playback is Studio-solo only (RegisterKeyframeSequence); shipping/multiplayer needs a published AnimationId (Open Cloud follow-up)."
	return msg, false
end

ItemAnim.descriptors = {
	{
		name = "bind_animation",
		description = "BIND an authored animation clip to a handheld Tool so it plays when the item is used. "
			.. "event='idle' loops a held-ready pose on equip (Idle priority); event='use' plays a one-shot "
			.. "swing on activate (Action priority, overrides the idle on the keyed joints). Author the clip "
			.. "ARM-ONLY first (add_keyframe {scope='rightArm'}) so the legs/torso keep their own locomotion. "
			.. "Copies the clip into tool/Anims/<event> and writes a CLIENT runtime LocalScript (ItemAnimRuntime). "
			.. "Inputs: tool (required path, from make_tool), event ('idle'|'use'), clip (the AnimSaves clip "
			.. "name), rig? (the rig whose AnimSaves holds the clip; omit to use the selection / first workspace "
			.. "rig). save_mesh the Handle first if it's a custom mesh. Dev-loop only (Studio-solo); a "
			.. "shipped/multiplayer item needs a published AnimationId.",
		inputSchema = {
			type = "object",
			properties = {
				tool = { type = "string", description = "Path to the Tool (from make_tool)." },
				event = {
					type = "string",
					description = "'idle' (equip, looped) or 'use' (activate, one-shot swing).",
				},
				clip = {
					type = "string",
					description = "The authored clip name under the rig's AnimSaves.",
				},
				rig = {
					type = "string",
					description = "Path to the rig whose AnimSaves holds the clip; omit to use the selection or first workspace rig.",
				},
			},
			required = { "tool", "event", "clip" },
		},
		destructive = true,
		run = runBind,
	},
} :: { Descriptor }

return ItemAnim
```

- [ ] **Step 2: Wire into the registry (`src/Tools/init.luau`)**

Add the require after `local ItemTool = require(script.Item)`:

```lua
local ItemAnimTool = require(script.ItemAnim)
```

Add the append loop after the `ItemTool.descriptors` loop (the last append loop before `local byName`):

```lua
for _, descriptor in ItemAnimTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

In the top registry comment (the line ending `... paint_texture, make_tool, grip_tool.`), append `, bind_animation` so it reads `... make_tool, grip_tool, bind_animation.`

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. Watch for: an unused-local warning (fix without suppressing), or a malformed long-string (`[==[ ... ]==]`) breaking the build — the runtime source contains no `]==]` so it parses cleanly.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/ItemAnim.luau src/Tools/init.luau
git commit -m "feat(tools): bind_animation — copy an arm-only clip into a Tool + write a client runtime LocalScript + register

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Relay classification (no-drift)

**Files:** Modify `src/RelaySpec.luau`.

- [ ] **Step 1: Add `bind_animation` to `EXPECTED_RELAY`**

In `src/RelaySpec.luau`, the `EXPECTED_RELAY` list contains `... "grip_tool",` and the animation tools (`"add_keyframe"`, …, `"import_animation"`). Add `bind_animation` after `"import_animation"` (the last entry):

```lua
		"export_animation",
		"import_animation",
		"bind_animation",
	}
```

`bind_animation` writes the DataModel → it relays by default (not in `Relay.LOCAL_TOOLS`); adding it to `EXPECTED_RELAY` makes the no-drift case + "every EXPECTED_RELAY name is registered" cover it. Do NOT add it to `EXPECTED_LOCAL`. `add_keyframe` stays where it is — gaining a `scope` input does not change its classification.

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (RelaySpec assertions run in-Studio at Task 6 — the no-drift case will now require `bind_animation` be classified, which it is.)

- [ ] **Step 3: Commit**

```bash
git add src/RelaySpec.luau
git commit -m "test(relay): classify bind_animation as RELAY (no-drift)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: SystemPrompt — bind_animation + use-animation flow

**Files:** Modify `src/SystemPrompt.luau`.

- [ ] **Step 1: Add a tool-index line**

In `src/SystemPrompt.luau`, immediately AFTER the `grip_tool(...)` tool-index bullet (the line starting `- grip_tool(tool, rig?, offset?, rot?):`), add:

```
- bind_animation(tool, event, clip, rig?): bind an authored ARM-ONLY clip to a Tool so it animates on equip ('idle', looped) / activate ('use', swing). See "Building handheld items".
```

- [ ] **Step 2: Extend the "# Building handheld items" section**

In `src/SystemPrompt.luau`, the "# Building handheld items" section currently ends with the sentence `... This is the held-object FOUNDATION; binding use-animations + behavior to the item comes later.` Replace that final sentence with:

```
To make the held item ANIMATE when used, author the motion as an ARM-ONLY clip so the legs/torso keep their own locomotion: pose the rig's right arm (pose_joint / ik_reach) and add_keyframe {scope='rightArm'} per keypose — build one looped 'idle' hold clip and one 'use' swing clip — then capture_animation to confirm ONLY the arm moves (the legs/torso stay at rest). Then bind_animation(tool, 'idle', <idleClip>) and bind_animation(tool, 'use', <useClip>): that copies the clips into the Tool and writes a client runtime so equipping plays the looped idle and clicking plays the swing once (the swing overrides only the arm via Action priority, so the legs keep walking). If the Handle is a custom mesh, save_mesh the Tool first or it goes blank in Play. Dev-loop playback is Studio-solo (RegisterKeyframeSequence); a shipped/multiplayer item needs a published AnimationId (a later follow-up). Behavior state machine + hit detection come after.
```

- [ ] **Step 3: Note `scope` on the `add_keyframe` bullet**

In `src/SystemPrompt.luau`, the "# Animating (keyframe clips)" section's `add_keyframe` bullet currently reads:

```
- add_keyframe(rig?, clip?, time?): snapshot the rig's current pose into the clip at `time` seconds (omit time to append after the last keyframe). The clip is a KeyframeSequence saved under rig/AnimSaves/<clip> (default "AgentClip") — the Animation Editor's own folder, so the user can refine it there.
```

Replace it with:

```
- add_keyframe(rig?, clip?, time?, scope?): snapshot the rig's current pose into the clip at `time` seconds (omit time to append after the last keyframe). `scope` keys only a SUBSET of joints — 'rightArm' (the right-arm chain, for item swing/use clips so the legs/torso keep their own animation), 'upperBody', or an array of joint child-part names; omit to key ALL joints. The clip is a KeyframeSequence saved under rig/AnimSaves/<clip> (default "AgentClip") — the Animation Editor's own folder, so the user can refine it there.
```

- [ ] **Step 4: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean (the only risk is a malformed long string in the prompt).

- [ ] **Step 5: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): use-animation flow (arm-only authoring + bind_animation) + add_keyframe scope note

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bridge dogfood + USER playtest — the acceptance gate

**Files:** none (live verification + HANDOFF + memory).

> Gate to enter: Tasks 1–5 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio** (Studio must also be FOCUSED for captures). The sidecar needs NO restart. Verify by LOOKING at captures, never coordinates. Drive via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; use a PowerShell here-string `$code = @'…'@` for Luau with quotes; use the `tool` command's 150s window for capture/upload calls, `luau` (30s) for quick reads). GOTCHA: a CameraRig pivot-sphere gizmo can obscure grip/camera captures — for a CLEAN shot set `workspace.CurrentCamera.CFrame` manually via run_luau. Do NOT delete the user's `Rig` / `UAL2_Standard`.

- [ ] **Step 1: Run the pure specs via the bridge**

Run:
```
& scripts/studio-agent.ps1 luau 'return "Anim=" .. tostring(require(script.Parent.AnimationClipSpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run().passed)'
```
Expected: `Anim=true Relay=true` (the Output shows `[AnimationClipSpec] 7/7 passed` — the 4 original + the 3 new scope cases; RelaySpec now covers `bind_animation` so no-drift stays green). If `Anim` is false, a scope case failed — fix and rebuild.

- [ ] **Step 2: Build a sword visual + make_tool**

Build a simple 3-part primitives sword (a `+Y`-length blade, so the grip-direction learning applies: blade-up = `rx:+90`) and toolify it:
```
$code = @'
local function part(name, size, cf, color, mat)
  local p = Instance.new("Part") p.Name = name p.Anchored = true p.Size = size p.CFrame = cf
  p.Color = color p.Material = mat return p
end
local m = Instance.new("Model") m.Name = "UseSword"
local grip = part("Grip", Vector3.new(0.3, 1.4, 0.3), CFrame.new(0, 0, 0), Color3.fromRGB(80, 50, 30), Enum.Material.Wood)
local guard = part("Guard", Vector3.new(1.4, 0.25, 0.3), CFrame.new(0, 0.8, 0), Color3.fromRGB(120, 90, 40), Enum.Material.Metal)
local blade = part("Blade", Vector3.new(0.3, 3.2, 0.12), CFrame.new(0, 2.5, 0), Color3.fromRGB(200, 200, 210), Enum.Material.Metal)
m.PrimaryPart = grip grip.Parent = m guard.Parent = m blade.Parent = m m.Parent = workspace
return m:GetFullName()
'@
& scripts/studio-agent.ps1 luau $code
& scripts/studio-agent.ps1 tool make_tool '{"target":"Workspace.UseSword","name":"UseSword","handle":"Workspace.UseSword.Grip"}'
```
Expected: `make_tool OK: 'UseSword' …`. (A primitives Handle is a Part, not a session MeshPart, so `bind_animation` will NOT warn about save_mesh — correct. The save_mesh-warning path is exercised separately if you build a Cube-mesh handle.)

- [ ] **Step 3: Spawn a rig + author an ARM-ONLY `use` swing + a looped `idle`**

Spawn an R15 rig, then pose the right arm and snapshot keyposes with `scope:"rightArm"`. Example (a 2-keypose overhead swing on clip `swing`, then a 1-pose held `idle`):
```
& scripts/studio-agent.ps1 tool spawn_rig '{"type":"block"}'
```
Author the swing (raise then chop — pose RightShoulder up, add_keyframe; pose down, add_keyframe). Use `pose_joint` per keypose, then:
```
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.Rig","clip":"swing","time":0,"scope":"rightArm"}'
```
(…re-pose the arm…)
```
& scripts/studio-agent.ps1 tool add_keyframe '{"rig":"Workspace.Rig","clip":"swing","time":0.4,"scope":"rightArm"}'
```
And a one-pose held idle on clip `hold` (arm slightly raised, `scope:"rightArm"`). The `spawn_rig` rig name may be `Rig`/`AgentRig` — confirm the actual path from the spawn output. Each `add_keyframe` result should prepend `scope=rightArm (...)` and the `list_clip` posed-joint count should be ~2–3 (the arm joints), NOT ~15.

- [ ] **Step 4: capture_animation — the arm-only proof**

```
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.Rig","clip":"swing","frames":5}'
```
READ the filmstrip: the RIGHT ARM swings across frames while the **legs and torso stay at rest** (they were never keyed). This is the arm-only proof — the fix for last session's "stiffens the whole body". If the legs move, the scope didn't prune (re-check Task 1).

- [ ] **Step 5: bind_animation both events + structural confirm**

```
& scripts/studio-agent.ps1 tool bind_animation '{"tool":"Workspace.UseSword","event":"idle","clip":"hold","rig":"Workspace.Rig"}'
& scripts/studio-agent.ps1 tool bind_animation '{"tool":"Workspace.UseSword","event":"use","clip":"swing","rig":"Workspace.Rig"}'
```
Then confirm the Tool carries both clips + the runtime:
```
$code = @'
local tool = workspace:FindFirstChild("UseSword")
if tool == nil then return "UseSword missing" end
local anims = tool:FindFirstChild("Anims")
local idle = anims and anims:FindFirstChild("idle")
local use = anims and anims:FindFirstChild("use")
local rt = tool:FindFirstChild("ItemAnimRuntime")
local function ks(x) if x == nil then return "nil" end return x.ClassName .. " loop=" .. tostring(x.Loop) .. " prio=" .. x.Priority.Name end
return "idle[" .. ks(idle) .. "] use[" .. ks(use) .. "] runtime=" .. tostring(rt ~= nil and rt.ClassName) .. " srcLen=" .. tostring(rt and #rt.Source)
'@
& scripts/studio-agent.ps1 luau $code
```
Expected: `idle[KeyframeSequence loop=true prio=Idle] use[KeyframeSequence loop=false prio=Action] runtime=LocalScript srcLen=<>0`. (idle=Loop+Idle, use=Action, the LocalScript exists with non-empty Source.)

- [ ] **Step 6: USER playtest (the runtime gate)**

Put the Tool in `StarterPack` so it equips on spawn (`& scripts/studio-agent.ps1 luau 'workspace.UseSword.Parent = game.StarterPack return "moved to StarterPack"'`), then **ask the USER to press Play** and report:
1. On spawn/equip → the character holds a **ready idle pose** (arm raised, looping).
2. **Walk around** → the legs animate (walk cycle) while the **arm keeps the idle hold** (arm-only confirmed at runtime — the real fix proof, which capture_animation can't show).
3. **Click** → the **arm-only swing** fires and the **sword swings with it**; the legs keep walking.
4. The **Handle is NOT blank** (it's a primitives Part — always visible; for a Cube-mesh handle this needs save_mesh).
This is the runtime acceptance gate (the bridge is edit-only). The no-publish runtime playback is already PROVEN to fire in solo Studio (last session's spike) — this confirms the arm-only + idle/use wiring.

- [ ] **Step 7: Clean up + HANDOFF + memory + final commit**

Destroy the dogfood artifacts (`UseSword`, the spawned `Rig`, the `swing`/`hold` clips under it) once the user confirms — ASK before clearing anything else; leave `Rig`/`UAL2_Standard` if they're the user's. Confirm `selene src` 0/0. Update `HANDOFF.md` with a new START-HERE block (roadmap #2 item use-animations SHIPPED + bridge-verified: joint-scoped `add_keyframe {scope}` + `bind_animation`; arm-only proof via capture_animation; the runtime gate confirmed by the USER playtest; the publish-for-shipping follow-up still flagged). Update memory `studio-agent-interactive-items-roadmap` (#2 SHIPPED; the arm-only-via-per-joint-priority fix; bind_animation copies clips into tool/Anims + writes ItemAnimRuntime; NEXT = #3 behavior state machine). Commit:

```bash
git add HANDOFF.md docs/superpowers/plans/2026-06-24-item-use-animations.md
git commit -m "docs: item use-animations shipped + bridge-verified (bind_animation + joint-scoped authoring), roadmap #2

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 per-joint priority / arm-only = OMIT leg-torso Poses → Task 1 (`scopeIncludeSet` includes only scoped joints + ancestor carriers, `buildPoseTree` prunes siblings); §1 priorities idle=Idle/use=Action → Task 3 (`EVENTS`); §1 `Animator:LoadAnimation` on a CLIENT LocalScript → Task 3 (`RUNTIME_SOURCE`); §1 `RegisterKeyframeSequence` no-publish Studio-solo → Task 3 (runtime + the NOTE in the result); §1 Tool events Equipped/Activated/Unequipped → Task 3 (runtime connects all three); §1 Handle persistence → Task 3 (`handleIsSessionMesh` warning) + Task 6 note; §2 joint-scoped authoring → Task 1 + Task 2; §2 priorities → Task 3; §2 runtime client LocalScript → Task 3; §2 dev-loop no-publish + flagged publish follow-up → Task 3 NOTE + §7; §2 self-contained Tool (clips under Anims/) → Task 3 (`storeClip`); §3a `add_keyframe` scope → Task 2; §3b `bind_animation` copy + LocalScript + summary/reminder → Task 3; §4 Changed `AnimationClip`/`Animate` → Tasks 1–2; §4 New `Tools/ItemAnim.luau` → Task 3; §4 wiring init/RelaySpec/SystemPrompt → Tasks 3/4/5; §5 errors (pcall via dispatch + `(content, isError)`; unknown scope → error listing presets in Task 1's `scopedJointSet`; empty scope → all-joints fallback in Task 2's `resolveScope`; idle/use priority set per event in Task 3; Handle-not-persisted warning in Task 3; runtime-only/playtest in Task 6) ; §6 static+spec+dogfood+playtest → Tasks 1/4 specs + Task 6; §7 out-of-scope (Open Cloud publish, combos, hit detection, state machine, additive layering) correctly absent.
- **Type/name consistency:** `scopedJointSet`/`scopeIncludeSet` (Task 1) are consumed by `resolveScope` (Task 2) and `snapshotKeyframe` (Task 1) with identical names/signatures; `buildPoseTree`'s new 3rd param `includeSet` (Task 1) is supplied only by `snapshotKeyframe` (other callers `import_animation`/preview pass 2 args — valid, it's optional). `bind_animation`'s `EVENTS` keys (`idle`/`use`) match the runtime LocalScript's `play("idle"…)`/`play("use"…)` and the `Anims/<event>` folder names exactly. The Tool name `bind_animation` matches across ItemAnim.luau, init.luau, RelaySpec, SystemPrompt. The runtime reads `Tool.Anims.idle`/`.use` (set by `storeClip`) and `track.Priority`/`track.Looped` mirror the copied KS's `Priority`/`Loop`.
- **Degrade:** `runBind` validates tool/event/clip/rig and returns `(msg, true)` on any miss; the runtime LocalScript pcall-wraps `RegisterKeyframeSequence` and no-ops if the Anims clip or Animator is missing (never throws at runtime). The Handle-session-mesh check and the publish-NOTE are appended to a SUCCESS result (isError=false) — informational, not failures.
- **Empirical check to watch in Task 6:** the arm-only clip includes ancestor *carrier* Poses (UpperTorso/LowerTorso/HRP) at identity, which hold the spine at rest during an Action swing. That is acceptable (a sword swing often engages the torso, and the bug was the LEGS + whole body) and the legs are never keyed. If the user's playtest shows the torso unacceptably stiff, the follow-up is to set carrier `Pose.Weight = 0` (structural-only) — out of v1 scope.
