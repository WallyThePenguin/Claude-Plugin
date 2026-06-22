# Animation importing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `import_animation` tool that brings an EXISTING animation (asset id, in-place KeyframeSequence/Animation, or an FBX brought in via Studio's 3D Importer) into an editable clip at `rig/AnimSaves/<clip>`, retargeted onto the target rig's joints by name.

**Architecture:** A new `AnimationImport` retarget engine fetches/receives a source `KeyframeSequence`, extracts `{jointName → CFrame}` per keyframe, and rebuilds each onto the TARGET rig via the existing `AnimationClip.buildPoseTree`, saving a fresh clip under `AnimSaves`. A thin `Tools/Import` tool resolves the source (asset id → `GetKeyframeSequenceAsync`, proven feasible; in-place path → clone/resolve) and wraps the write in a ChangeHistory recording. v1 retarget is joint-NAME-based (R15→R15 clean) and reports joint coverage; cross-skeleton retarget is a flagged v2.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — verify with `selene`/`stylua`/`rojo build` (static) + an in-Studio pure spec + a bridge dogfood after a Studio restart.

**Source of truth:** [`docs/superpowers/specs/2026-06-22-animation-import-design.md`](../specs/2026-06-22-animation-import-design.md).

---

## Reference facts (from the codebase — do not re-derive)

- **Feasibility proven (bridge, 2026-06-22):** `KeyframeSequenceProvider:GetKeyframeSequenceAsync("rbxassetid://507767714")` returned a `KeyframeSequence` (14 keyframes / 224 poses) at PluginSecurity in edit. It YIELDS (web-backed).
- `src/AnimationClip.luau` exposes: `buildPoseTree(rig, transformsMap: { [string]: CFrame }) -> Instance?` (builds a Pose tree mirroring the rig's Motor6D graph; each part's Pose.CFrame = `transformsMap[partName]` or identity; root pose included), `getOrCreateClip(rig, clipName) -> KeyframeSequence`, `rigRoot(rig) -> Instance?`, `summary(rig, clipName) -> string`, `normalizeTime(t) -> number`. A source `Keyframe`'s `Pose.Name` = posed part name, `Pose.CFrame` = that joint's Motor6D.Transform (same semantics buildPoseTree consumes). **`ks:AddKeyframe(kf)` is REQUIRED** (bare `.Parent` leaves length 0).
- `src/Tools/Animate.luau` is the pattern to mirror for the tool: a local `resolveRig(target)` (path via `Path.resolve` or `Selection:Get()[1]`), a `recorded(label, fn)` ChangeHistory wrapper (edit-only; `TryBeginRecording`/`FinishRecording`; returns `(text, ok)`), and descriptors `{name, description, inputSchema, destructive, run}` whose run returns `(text, isError)` (note: these tools return `text, not ok`). `require(script.Parent.Path)` resolves instance paths.
- `src/Tools/init.luau` registers each tool module's `.descriptors` via `local XTool = require(script.X)` + a `for _, descriptor in XTool.descriptors do table.insert(registry, descriptor) end` loop; the header comment lists the final registry.
- `src/RelaySpec.luau` `EXPECTED_RELAY` lists every DataModel/dispatch tool (relays in client-view play). The "no-drift" case asserts every registered tool is in EXPECTED_LOCAL or EXPECTED_RELAY. `import_animation` writes the DataModel → it RELAYS (NOT in `Relay.LOCAL_TOOLS`), so add it to EXPECTED_RELAY only.
- `src/SystemPrompt.luau` has an "# Animating (keyframe clips)" section (the `add_keyframe`/`list_clip`/... block) — the import paragraph goes there.
- **Module-name note:** the tool module is `Import` (`script.Import`) — `Import` is NOT an Instance method, so unlike `Destroy` it requires cleanly.

---

## File structure

| File | New/Mod | Responsibility |
|---|---|---|
| `src/AnimationImport.luau` | **new** | Retarget engine: pure `coverage` + impure `extractPoseMap`/`sourceNames`/`targetJointNames`/`importInto`. |
| `src/AnimationImportSpec.luau` | **new** | Pure spec for `coverage`. |
| `src/Tools/Import.luau` | **new** | `import_animation` tool: `resolveSource` (asset id / in-place) + ChangeHistory + descriptor. |
| `src/Tools/init.luau` | mod | Register `import_animation`. |
| `src/RelaySpec.luau` | mod | Add `import_animation` to EXPECTED_RELAY. |
| `src/SystemPrompt.luau` | mod | Import paragraph in the Animating section. |
| `src/init.server.luau` | mod (temp) | Temporary spec require for the dogfood (reverted in Task 4). |
| `HANDOFF.md` | mod | Dated shipped block. |

---

## Task 1: `AnimationImport.luau` (retarget engine) + pure spec

**Files:**
- Create: `src/AnimationImport.luau`
- Create: `src/AnimationImportSpec.luau`

- [ ] **Step 1: Write `src/AnimationImport.luau`**

```lua
--!strict
-- AnimationImport: retarget a SOURCE KeyframeSequence's poses onto a TARGET rig's Motor6D joints (by joint
-- NAME) and save the result as an editable clip under targetRig/AnimSaves/<clip>. The bridge between an
-- existing animation (fetched by asset id / resolved in-place by Tools/Import) and the agent's authoring
-- loop (list_clip / capture_animation / evaluate / export). v1 retarget = name match (R15->R15 clean);
-- unmatched source joints are dropped and reported via coverage. Reuses AnimationClip.buildPoseTree +
-- the AnimSaves storage convention.

local AnimationClip = require(script.Parent.AnimationClip)

local AnimationImport = {}

export type Coverage = { matched: number, total: number, droppedSource: { string } }

-- ---- pure (no DataModel -- unit-testable) ----

-- Retarget coverage: how many TARGET joints got a source pose (name match), and which SOURCE joint names
-- had no matching target (dropped -> a different skeleton). targetNames = the target rig's joint names;
-- sourceNames = the distinct joint names the source animates. droppedSource preserves source order, de-duped.
function AnimationImport.coverage(sourceNames: { string }, targetNames: { string }): Coverage
	local sourceSet: { [string]: boolean } = {}
	for _, n in ipairs(sourceNames) do
		sourceSet[n] = true
	end
	local targetSet: { [string]: boolean } = {}
	local total = 0
	for _, n in ipairs(targetNames) do
		if not targetSet[n] then
			targetSet[n] = true
			total += 1
		end
	end
	local matched = 0
	for n in targetSet do
		if sourceSet[n] then
			matched += 1
		end
	end
	local dropped: { string } = {}
	local seenDrop: { [string]: boolean } = {}
	for _, n in ipairs(sourceNames) do
		if not targetSet[n] and not seenDrop[n] then
			seenDrop[n] = true
			table.insert(dropped, n)
		end
	end
	return { matched = matched, total = total, droppedSource = dropped }
end

-- ---- impure (DataModel reads/writes) ----

-- { poseName -> CFrame } for every Pose in a keyframe (the joints it animates).
function AnimationImport.extractPoseMap(keyframe: Instance): { [string]: CFrame }
	local map: { [string]: CFrame } = {}
	for _, d in keyframe:GetDescendants() do
		if d:IsA("Pose") then
			map[(d :: Pose).Name] = (d :: Pose).CFrame
		end
	end
	return map
end

-- Distinct joint names the source animates (union of Pose.Name across all keyframes), source order.
function AnimationImport.sourceNames(sourceKS: KeyframeSequence): { string }
	local seen: { [string]: boolean } = {}
	local names: { string } = {}
	for _, kf in sourceKS:GetKeyframes() do
		for _, d in kf:GetDescendants() do
			if d:IsA("Pose") then
				local nm = (d :: Pose).Name
				if not seen[nm] then
					seen[nm] = true
					table.insert(names, nm)
				end
			end
		end
	end
	return names
end

-- The target rig's joint names (Motor6D Part1 child names -- what buildPoseTree poses).
function AnimationImport.targetJointNames(rig: Instance): { string }
	local names: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in rig:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 ~= nil and d.Part1 ~= nil then
			local nm = (d.Part1 :: Instance).Name
			if not seen[nm] then
				seen[nm] = true
				table.insert(names, nm)
			end
		end
	end
	return names
end

-- Retarget all of sourceKS's keyframes onto targetRig by joint name, saving a FRESH clip under
-- targetRig/AnimSaves/<clipName> (a re-import overwrites). Returns (summary + coverage line, ok).
function AnimationImport.importInto(
	sourceKS: KeyframeSequence,
	targetRig: Instance,
	clipName: string
): (string, boolean)
	if AnimationClip.rigRoot(targetRig) == nil then
		return "no Motor6D rig under " .. targetRig.Name .. " (spawn_rig or select a rig).", false
	end
	local kfs = sourceKS:GetKeyframes()
	if #kfs == 0 then
		return "the source animation has no keyframes.", false
	end
	local ks = AnimationClip.getOrCreateClip(targetRig, clipName)
	for _, kf in ks:GetKeyframes() do
		kf:Destroy()
	end
	ks.Loop = sourceKS.Loop
	ks.Priority = sourceKS.Priority
	local entries: { { t: number, kf: Instance } } = {}
	for _, kf in kfs do
		table.insert(entries, { t = (kf :: Keyframe).Time, kf = kf })
	end
	table.sort(entries, function(a, b)
		return a.t < b.t
	end)
	for _, e in entries do
		local map = AnimationImport.extractPoseMap(e.kf)
		local pose = AnimationClip.buildPoseTree(targetRig, map)
		if pose ~= nil then
			local nkf = Instance.new("Keyframe")
			nkf.Time = AnimationClip.normalizeTime(e.t)
			pose.Parent = nkf
			ks:AddKeyframe(nkf)
		end
	end
	local cov =
		AnimationImport.coverage(AnimationImport.sourceNames(sourceKS), AnimationImport.targetJointNames(targetRig))
	local covLine = string.format("retarget: matched %d/%d target joints", cov.matched, cov.total)
	if #cov.droppedSource > 0 then
		local shown: { string } = {}
		for i = 1, math.min(8, #cov.droppedSource) do
			table.insert(shown, cov.droppedSource[i])
		end
		local extra = if #cov.droppedSource > 8 then ", ..." else ""
		covLine = covLine
			.. string.format(
				"; %d source joint(s) had no target (dropped: %s%s)",
				#cov.droppedSource,
				table.concat(shown, ", "),
				extra
			)
	end
	return AnimationClip.summary(targetRig, clipName) .. "\n" .. covLine, true
end

return AnimationImport
```

- [ ] **Step 2: Write `src/AnimationImportSpec.luau`**

```lua
--!strict
-- AnimationImportSpec: in-Studio self-test for the PURE retarget-coverage logic (no DataModel). Run via
-- temporarily adding `require(script.AnimationImportSpec).run()` to init.server.luau.

local AnimationImport = require(script.Parent.AnimationImport)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("coverage full match: all target joints matched, nothing dropped", function()
		local cov = AnimationImport.coverage({ "A", "B", "C" }, { "A", "B", "C" })
		return cov.matched == 3 and cov.total == 3 and #cov.droppedSource == 0
	end)

	add("coverage partial: extra source name dropped, missing target unmatched", function()
		-- source animates A,B,X; target has A,B,C -> matched A,B (2/3); X dropped
		local cov = AnimationImport.coverage({ "A", "B", "X" }, { "A", "B", "C" })
		if cov.matched ~= 2 or cov.total ~= 3 then
			return false, "counts " .. tostring(cov.matched) .. "/" .. tostring(cov.total)
		end
		if #cov.droppedSource ~= 1 or cov.droppedSource[1] ~= "X" then
			return false, "dropped wrong"
		end
		return true
	end)

	add("coverage empty source -> 0 matched, none dropped", function()
		local cov = AnimationImport.coverage({}, { "A", "B" })
		return cov.matched == 0 and cov.total == 2 and #cov.droppedSource == 0
	end)

	add("coverage de-dups dropped + target", function()
		local cov = AnimationImport.coverage({ "X", "X", "Y" }, { "Z", "Z" })
		if cov.matched ~= 0 or cov.total ~= 1 then
			return false, "total should de-dup to 1"
		end
		if #cov.droppedSource ~= 2 or cov.droppedSource[1] ~= "X" or cov.droppedSource[2] ~= "Y" then
			return false, "dropped should be X,Y once each"
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
			print("[AnimationImportSpec] PASS " .. c.name)
		else
			warn("[AnimationImportSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[AnimationImportSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (stylua clean; selene 0/0/0; build OK). Fix any slip and re-run.

- [ ] **Step 4: Commit**
```
git add src/AnimationImport.luau src/AnimationImportSpec.luau
git commit -m "feat: AnimationImport retarget engine (name-based) + pure coverage spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Tools/Import.luau` (the `import_animation` tool) + register

**Files:**
- Create: `src/Tools/Import.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Import.luau`**

```lua
--!strict
-- Import tool: import_animation. Bring an EXISTING animation (a published asset id, or an in-place
-- KeyframeSequence/Animation) into an editable clip on a rig via AnimationImport (name-based retarget),
-- so list_clip / capture_animation / evaluate / export work on it. For an FBX/GLB file a plugin can't read
-- the file -- use Studio's 3D Importer first, then import the in-place result. DataModel write -> undoable
-- + relays in client view (absent from Relay.LOCAL_TOOLS, like the other animation tools).

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local AnimationImport = require(script.Parent.Parent.AnimationImport)
local Path = require(script.Parent.Path)

local Import = {}

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

-- Wrap the DataModel write in an undoable ChangeHistory recording (edit only).
local function recorded(label: string, fn: () -> (string, boolean)): (string, boolean)
	if not RunService:IsEdit() then
		return fn()
	end
	local rid = ChangeHistoryService:TryBeginRecording(label)
	if rid == nil then
		return label .. ": a change recording is already in progress — try again.", true
	end
	local text, ok = fn()
	ChangeHistoryService:FinishRecording(
		rid,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	return text, ok
end

-- Fetch the source KeyframeSequence from { animation = <asset id> } OR { source = <KeyframeSequence/Animation path> }.
local function resolveSource(args: any): (KeyframeSequence?, string?)
	local function fetchById(id: string): (KeyframeSequence?, string?)
		local url = if string.match(id, "^%d+$") ~= nil then "rbxassetid://" .. id else id
		local ok, ks = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(url)
		end)
		if not ok or typeof(ks) ~= "Instance" or not (ks :: Instance):IsA("KeyframeSequence") then
			return nil,
				"couldn't fetch animation '" .. url .. "' (must be a public or owned animation): " .. tostring(ks)
		end
		return ks :: KeyframeSequence, nil
	end

	local anim = if type(args.animation) == "string" and args.animation ~= "" then args.animation else nil
	if anim ~= nil then
		return fetchById(anim)
	end
	local src = if type(args.source) == "string" and args.source ~= "" then args.source else nil
	if src == nil then
		return nil,
			"requires { animation = <asset id> } OR { source = <KeyframeSequence/Animation path> }"
	end
	local inst, perr = Path.resolve(src)
	if inst == nil then
		return nil, "source path didn't resolve: " .. tostring(perr)
	end
	if inst:IsA("KeyframeSequence") then
		return inst :: KeyframeSequence, nil
	end
	if inst:IsA("Animation") then
		local id = (inst :: Animation).AnimationId
		if id == nil or id == "" then
			return nil, "the Animation at '" .. src .. "' has no AnimationId."
		end
		return fetchById(id)
	end
	return nil, "source must be a KeyframeSequence or an Animation (got " .. inst.ClassName .. ")."
end

-- Clip name: explicit arg, else the source's own name (unless the generic "KeyframeSequence"), else default.
local function clipName(args: any, sourceKS: KeyframeSequence): string
	if type(args.clip) == "string" and args.clip ~= "" then
		return args.clip
	end
	if sourceKS.Name ~= "" and sourceKS.Name ~= "KeyframeSequence" then
		return sourceKS.Name
	end
	return "ImportedClip"
end

local function runImport(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, rerr = resolveRig(args.rig)
	if rig == nil then
		return "import_animation: " .. tostring(rerr), true
	end
	local sourceKS, serr = resolveSource(args)
	if sourceKS == nil then
		return "import_animation: " .. tostring(serr), true
	end
	local clip = clipName(args, sourceKS :: KeyframeSequence)
	local text, ok = recorded("Import animation", function()
		return AnimationImport.importInto(sourceKS :: KeyframeSequence, rig :: Instance, clip)
	end)
	return text, not ok
end

Import.descriptors = {
	{
		name = "import_animation",
		description = "Import an EXISTING animation into an editable clip on a rig (then list_clip / "
			.. "capture_animation / evaluate / export it). Sources: animation = a published asset id "
			.. "(rbxassetid://N or a bare number), OR source = an instance path to a KeyframeSequence or an "
			.. "Animation already in the place. It retargets the source's poses onto the target rig's joints "
			.. "BY NAME (clean for R15->R15) and reports joint coverage. For an FBX/GLB file (e.g. a "
			.. "Quaternius clip) a plugin CAN'T read the file: first use Studio's 3D Importer (File > Import "
			.. "3D) to bring it in as an in-place rig+animation, then import_animation that in-place "
			.. "KeyframeSequence. Inputs: animation OR source, rig (path or selection), clip (default = the "
			.. "source name or 'ImportedClip').",
		inputSchema = {
			type = "object",
			properties = {
				animation = {
					type = "string",
					description = "Published animation asset id (rbxassetid://N or a bare number).",
				},
				source = {
					type = "string",
					description = "Instance path to an in-place KeyframeSequence or Animation.",
				},
				rig = { type = "string", description = "Target rig path; omit to use the selection." },
				clip = {
					type = "string",
					description = "Clip name to save under rig/AnimSaves (default: the source name or 'ImportedClip').",
				},
			},
		},
		destructive = true,
		run = runImport,
	},
} :: { Descriptor }

return Import
```

- [ ] **Step 2: Register in `src/Tools/init.luau`** — after the existing `local AnimateTool = require(script.Animate)` line add:
```lua
local ImportTool = require(script.Import)
```
and after the `AnimateTool.descriptors` registration loop add:
```lua
for _, descriptor in ImportTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```
Append `import_animation` to the header comment's final-registry tool list.

- [ ] **Step 3: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build … ; echo done` (selene 0/0; build OK).

- [ ] **Step 4: Commit**
```
git add src/Tools/Import.luau src/Tools/init.luau
git commit -m "feat: import_animation tool (asset id / in-place source -> retargeted AnimSaves clip)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Relay classification + SystemPrompt

**Files:**
- Modify: `src/RelaySpec.luau`
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: `RelaySpec.luau`** — add `"import_animation",` to the `EXPECTED_RELAY` list (alongside `"export_animation",` and the other animation tools). Do NOT add it to EXPECTED_LOCAL or `Relay.LOCAL_TOOLS` — it writes the DataModel, so it relays by default (the absence is correct).

- [ ] **Step 2: `SystemPrompt.luau`** — in the "# Animating (keyframe clips)" section, after the `export_animation` line (the last tool bullet in that section), add this paragraph:
```
- import_animation(animation|source, rig?, clip?): bring an EXISTING animation into an editable clip (then capture_animation / evaluate / refine / export it). animation = a published asset id; source = a path to an in-place KeyframeSequence or Animation. It retargets onto the rig's joints by NAME and reports joint coverage. To use an FBX/GLB (e.g. a Quaternius clip), first bring it in with Studio's 3D Importer (File > Import 3D), then import_animation the in-place result.
```

- [ ] **Step 3: Static-verify** — `stylua src ; stylua --check src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 4: Commit**
```
git add src/RelaySpec.luau src/SystemPrompt.luau
git commit -m "feat: classify import_animation RELAY + document it in the Animating prompt" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Full verify + bridge dogfood + HANDOFF

**Files:** `src/init.server.luau` (temporary spec require, reverted in Step 6); `HANDOFF.md`.

- [ ] **Step 1: Temporarily wire the specs** — in `src/init.server.luau`, after the final `print(...)`, add:
```lua
require(script.AnimationImportSpec).run()
require(script.RelaySpec).run()
```

- [ ] **Step 2: Build + install + restart** — `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`; then the **USER restarts Studio** ("Restart to update") on a fresh Baseplate (sidecar + bridge + tunnel already running).

- [ ] **Step 3: Confirm specs + bridge** — `& scripts/studio-agent.ps1 logs` → expect `[AnimationImportSpec] 4/4 passed` and `RelaySpec ... Summary: N/N passed` (no-drift now covering import_animation) and `dev bridge active`.

- [ ] **Step 4: Dogfood — import a real animation and SEE it on the rig:**
```
& scripts/studio-agent.ps1 tool spawn_rig '{"type":"block"}'
& scripts/studio-agent.ps1 tool import_animation '{"rig":"Workspace.AgentRig","animation":"rbxassetid://507767714"}'
& scripts/studio-agent.ps1 tool list_clip '{"rig":"Workspace.AgentRig","clip":"ImportedClip"}'
& scripts/studio-agent.ps1 tool capture_animation '{"rig":"Workspace.AgentRig","clip":"ImportedClip","frames":6}'
```
Then fetch the filmstrip frames from the sidecar and **LOOK** (the bridge `tool` result for a capture says "non-text tool content"): `Invoke-RestMethod "http://127.0.0.1:8389/captures?count=6&b64=1"` → write each base64 image to a PNG → Read them. **PASS criteria:** `import_animation` returns a clip summary with ~14 keyframes and `retarget: matched M/N target joints` (M near N, the R15 joints); `list_clip` shows the keyframes; the filmstrip shows the DEFAULT RUN CYCLE on the agent's rig (legs/arms swinging through a stride), not a static pose. (507767714 is the default R15 run.) If coverage is low (matched ≪ total), the source joint names didn't match R15 — note it; the default-run id should match cleanly.

- [ ] **Step 5: (Recommended) quick review** — diff-verify: `importInto` overwrites a same-named clip cleanly, copies Loop/Priority, uses `ks:AddKeyframe`; `resolveSource` pcall-guards `GetKeyframeSequenceAsync`; `import_animation` is in EXPECTED_RELAY (no-drift green).

- [ ] **Step 6: Revert the temporary spec require** — remove the two `require(...).run()` lines from `src/init.server.luau`; rebuild + reinstall (`stylua src ; selene src ; rojo build … ; .\build.ps1`).

- [ ] **Step 7: Update HANDOFF.md + commit** — add a dated block: `import_animation` shipped + bridge-verified (asset-id / in-place sources → name-retargeted editable AnimSaves clip + coverage report; FBX via Studio's 3D Importer; cross-skeleton retarget = v2). Commit.
```
git add HANDOFF.md src/init.server.luau
git commit -m "docs: import_animation shipped + bridge-verified; revert spec auto-run" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** `import_animation` tool (asset id / in-place sources) → Task 2; name-based retarget + coverage report → Task 1 (`importInto`/`coverage`); reuse `AnimationClip.buildPoseTree` + AnimSaves → Task 1; RELAY classification → Task 3; SystemPrompt + FBX-via-importer note → Task 3; pure spec + bridge dogfood (look at the filmstrip) → Tasks 1 + 4; FBX-direct-read + cross-skeleton retarget explicitly OUT (v2) → spec "Out of scope". All spec sections covered.
- **Placeholder scan:** every new file is complete code; the wiring edits name exact anchors (`AnimateTool` require/loop, `EXPECTED_RELAY`, the Animating section). The dogfood gives an exact asset id (507767714) + a concrete visual PASS criterion (run cycle, coverage near-full). No TBDs.
- **Type/name consistency:** `AnimationImport.coverage/extractPoseMap/sourceNames/targetJointNames/importInto` (Task 1) are exactly what `Tools/Import` calls (Task 2 calls `importInto`); `AnimationClip.buildPoseTree/getOrCreateClip/rigRoot/summary/normalizeTime` match the real signatures (reference facts); `import_animation` name matches across Tasks 2/3/4; `Coverage` type fields (matched/total/droppedSource) consistent.
- **Encode safety:** `import_animation`'s `input_schema.properties` is non-empty (animation/source/rig/clip), so the empty-`{}`→`[]` encodeBody bug cannot trigger.
- **YAGNI:** no FBX file reading, no cross-skeleton name-map/orientation/proportion retarget, no publish — all deferred.
