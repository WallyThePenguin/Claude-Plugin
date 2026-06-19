# Build-Quality Tools (destroy_instance + place_relative) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two main-agent tools — `destroy_instance` (delete an instance, guarded) and `place_relative` (position an instance relative to an anchor by an anchor-local direction) — that fix the two failures from the live obby session.

**Architecture:** Two new `Tools/` submodules mirroring `Create.luau`/`Properties.luau` (path resolve → region guard → undoable in edit / direct in playtest → `{ok=...}` JSON result, `destructive=true`). `init.luau`'s existing concat loop registers them. `place_relative`'s offset math is a pure function unit-tested in `PlaceSpec`.

**Tech Stack:** Luau (Roblox plugin, `--!strict`), Rojo build, selene + stylua, in-Studio spec harness (mirrors `CaptureSpec`/`RelaySpec`).

**Spec:** `docs/superpowers/specs/2026-06-18-studio-agent-build-tools-design.md`

---

## File Structure

- **Create** `src/Tools/Place.luau` — `place_relative` tool + pure `offsetPoint`/`DIRS`.
- **Create** `src/PlaceSpec.luau` — in-Studio unit test for the pure offset math.
- **Create** `src/Tools/Destroy.luau` — `destroy_instance` tool.
- **Modify** `src/Tools/init.luau` — require both, append descriptors, update the registry comment.
- **Modify** `src/RelaySpec.luau` — `EXPECTED_RELAY` += `destroy_instance`, `place_relative`.
- **Modify** `src/SystemPrompt.luau` — tool list entries + a placement-guidance line.

Conventions: each file starts `--!strict`. Descriptor shape (from `init.luau`): `{name, description, inputSchema, destructive, run}` where `run(input, context) -> (string, boolean)` returns a JSON string + isError. Shared modules: `Path` (`script.Parent.Path` → `.resolve(str) -> (Instance?, string?)`, `.fullPath(inst) -> string`), `RegionGuard` (`script.Parent.RegionGuard` → `.check(inst, context) -> (boolean, string?)`), `Serialize` (`script.Parent.Parent.Serialize` → `.encode(value) -> any`).

---

## Task 1: `place_relative` pure offset math + `PlaceSpec`

**Files:**
- Create: `src/Tools/Place.luau` (pure surface only this task)
- Create: `src/PlaceSpec.luau`

- [ ] **Step 1: Write the spec (the failing test)**

Create `src/PlaceSpec.luau`:

```lua
--!strict
-- PlaceSpec: in-Studio unit test for the PURE offset math of place_relative (anchor-local direction ->
-- world point). Run via temporarily adding `require(script.PlaceSpec).run()` to init.server.luau,
-- build, reopen Studio, read Output. The impure apply (resolve/region/recording) is live-verified.

local Place = require(script.Parent.Tools.Place)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function approxV(a: Vector3, b: Vector3): boolean
	return (a - b).Magnitude < 1e-3
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("axis-aligned anchor: each direction maps to the expected world point", function()
		local cf = CFrame.new(0, 0, 0)
		local checks = {
			{ "front", Vector3.new(0, 0, -5) },
			{ "back", Vector3.new(0, 0, 5) },
			{ "right", Vector3.new(5, 0, 0) },
			{ "left", Vector3.new(-5, 0, 0) },
			{ "up", Vector3.new(0, 5, 0) },
			{ "down", Vector3.new(0, -5, 0) },
		}
		for _, c in checks do
			local got = Place.offsetPoint(cf, c[1] :: string, 5)
			if got == nil or not approxV(got, c[2] :: Vector3) then
				return false, (c[1] :: string) .. " got " .. tostring(got)
			end
		end
		return true
	end)

	add("yaw-rotated anchor: 'front' follows the anchor's facing (anchor-local)", function()
		-- Anchor turned +90deg about Y: local -Z (front) now points along world -X.
		local cf = CFrame.Angles(0, math.rad(90), 0)
		local got = Place.offsetPoint(cf, "front", 5)
		return got ~= nil and approxV(got, Vector3.new(-5, 0, 0)), tostring(got)
	end)

	add("translated anchor: offset is relative to the anchor's position", function()
		local cf = CFrame.new(10, 2, 3)
		local got = Place.offsetPoint(cf, "right", 4)
		return got ~= nil and approxV(got, Vector3.new(14, 2, 3)), tostring(got)
	end)

	add("unknown direction returns nil", function()
		return Place.offsetPoint(CFrame.new(), "sideways", 5) == nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total, failed = #cases, 0
	print("=== PlaceSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	print("=== Summary: " .. tostring(total - failed) .. "/" .. tostring(total) .. " passed ===")
	return { passed = failed == 0, total = total, failed = failed }
end

return M
```

- [ ] **Step 2: Create `Place.luau` with ONLY the pure surface**

Create `src/Tools/Place.luau`:

```lua
--!strict
-- Place: the place_relative tool — position an existing instance relative to an anchor instance by an
-- anchor-LOCAL direction + distance, so the agent never hand-computes facing/CFrame math. PURE math
-- (offsetPoint/DIRS) is unit-tested in PlaceSpec; the impure apply (resolve, region guard, undoable
-- recording) mirrors Create.luau/Properties.luau and is live-verified.
--
-- Tools/ submodule: reaches top-level Serialize via script.Parent.Parent and its Tools siblings
-- (Path, RegionGuard) via script.Parent.

local Place = {}

-- Anchor-local unit directions. front = the anchor's facing (local -Z), matching Roblox LookVector.
Place.DIRS = {
	front = Vector3.new(0, 0, -1),
	back = Vector3.new(0, 0, 1),
	right = Vector3.new(1, 0, 0),
	left = Vector3.new(-1, 0, 0),
	up = Vector3.new(0, 1, 0),
	down = Vector3.new(0, -1, 0),
} :: { [string]: Vector3 }

-- World point `distance` studs from anchorCF's center along the anchor-local `direction`. nil if the
-- direction name is unknown. Pure + deterministic.
function Place.offsetPoint(anchorCF: CFrame, direction: string, distance: number): Vector3?
	local unit = Place.DIRS[direction]
	if unit == nil then
		return nil
	end
	return (anchorCF * CFrame.new(unit * distance)).Position
end

return Place
```

- [ ] **Step 3: Lint + build, then run PlaceSpec in Studio**

Run: `selene src/` then `stylua --check src/` then `rojo build default.project.json -o StudioAgent.rbxm` (expect 0/0 + BUILD OK). Then temporarily add `require(script.PlaceSpec).run()` to `src/init.server.luau` (just before the final `print`), build + install (`build.ps1`), reopen Studio on a fresh Baseplate, read Output.
Expected: `=== Summary: 4/4 passed ===`. Then REMOVE the temporary require.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Place.luau src/PlaceSpec.luau
git commit -m "feat(tools): place_relative pure offset math (anchor-local direction) + spec"
```

---

## Task 2: `place_relative` tool (impure apply + descriptor)

**Files:**
- Modify: `src/Tools/Place.luau` (add the impure surface + descriptor)

- [ ] **Step 1: Add the requires under the module comment, above `local Place = {}`**

```lua
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Serialize = require(script.Parent.Parent.Serialize)
local Path = require(script.Parent.Path)
local RegionGuard = require(script.Parent.RegionGuard)
```

- [ ] **Step 2: Add the descriptor type + encodeResult helper (after `local Place = {}`)**

```lua
export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end
```

- [ ] **Step 3: Add the anchor/target spatial helpers + the run function + descriptor (before `return Place`)**

```lua
-- The anchor's reference CFrame: a BasePart's CFrame, or a Model's pivot. nil if non-spatial.
local function anchorCFrame(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	elseif inst:IsA("Model") then
		return inst:GetPivot()
	end
	return nil
end

-- Move `target` so its position is `point`, keeping its current orientation. Returns false if the
-- target cannot be positioned (not a BasePart or Model).
local function positionTarget(target: Instance, point: Vector3): boolean
	if target:IsA("BasePart") then
		target.Position = point
		return true
	elseif target:IsA("Model") then
		target:PivotTo(CFrame.new(point) * target:GetPivot().Rotation)
		return true
	end
	return false
end

local function runPlace(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if
		type(args.target) ~= "string"
		or type(args.anchor) ~= "string"
		or type(args.direction) ~= "string"
		or type(args.distance) ~= "number"
		or args.distance ~= args.distance -- NaN guard
	then
		return encodeResult({
			ok = false,
			error = "place_relative requires { target = <path>, anchor = <path>, direction = "
				.. "front|back|left|right|up|down, distance = <number> }",
		}),
			true
	end
	if Place.DIRS[args.direction] == nil then
		return encodeResult({
			ok = false,
			error = "direction must be one of front/back/left/right/up/down",
		}),
			true
	end

	local target, terr = Path.resolve(args.target)
	if target == nil then
		return encodeResult({ ok = false, error = "target: " .. tostring(terr) }), true
	end
	local anchor, aerr = Path.resolve(args.anchor)
	if anchor == nil then
		return encodeResult({ ok = false, error = "anchor: " .. tostring(aerr) }), true
	end

	-- Region guard (parallel writer): only the TARGET is mutated; the anchor is read-only. No-op for
	-- the serial parent (no context.writeRegion).
	local okRegion, regionErr = RegionGuard.check(target :: Instance, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end

	local aCF = anchorCFrame(anchor :: Instance)
	if aCF == nil then
		return encodeResult({ ok = false, error = "anchor has no position (need a BasePart or Model)" }),
			true
	end
	local point = Place.offsetPoint(aCF, args.direction, args.distance)
	if point == nil then
		return encodeResult({ ok = false, error = "direction must be one of front/back/left/right/up/down" }),
			true
	end

	-- In edit, wrap the move in an undoable recording; during a playtest apply directly.
	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("Place " .. (target :: Instance).Name)
		if rid == nil then
			return encodeResult({ ok = false, error = "could not begin a change recording" }), true
		end
	end

	local okMove = false
	local okPcall = pcall(function()
		okMove = positionTarget(target :: Instance, point :: Vector3)
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okPcall and okMove
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okPcall or not okMove then
		return encodeResult({
			ok = false,
			error = "target cannot be positioned (need a BasePart or Model)",
		}),
			true
	end

	return encodeResult({
		ok = true,
		target = Path.fullPath(target :: Instance),
		position = Serialize.encode(point),
	}),
		false
end

Place.descriptors = {
	{
		name = "place_relative",
		description = "Position an existing instance RELATIVE to an anchor instance — give a target, an "
			.. "anchor, a direction (front/back/left/right/up/down, relative to the ANCHOR's own "
			.. "orientation, so 'front' is the way the anchor faces), and a distance in studs. The tool "
			.. "computes the placement so you NEVER hand-write a CFrame or LookVector. Moves the target "
			.. "(keeps its current rotation). Works in edit and playtest; undoable in edit. e.g. place a "
			.. "ball 5 studs in front of the player: { target=<ball>, anchor=<player root>, "
			.. "direction='front', distance=5 }.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string", description = "Dot path to the instance to move (BasePart or Model)." },
				anchor = { type = "string", description = "Dot path to the reference instance (BasePart or Model)." },
				direction = {
					type = "string",
					description = "front | back | left | right | up | down (relative to the anchor's orientation).",
				},
				distance = { type = "number", description = "Studs from the anchor's center." },
			},
			required = { "target", "anchor", "direction", "distance" },
		},
		destructive = true,
		run = runPlace,
	},
} :: { Descriptor }
```

- [ ] **Step 4: Lint + build**

Run: `selene src/` then `stylua --check src/` (auto-format if needed: `stylua src/`) then `rojo build default.project.json -o StudioAgent.rbxm`
Expected: 0 errors / 0 warnings, BUILD OK.

- [ ] **Step 5: Commit**

```bash
git add src/Tools/Place.luau
git commit -m "feat(tools): place_relative tool — anchor-local relative positioning"
```

---

## Task 3: `destroy_instance` tool (`Destroy.luau`)

**Files:**
- Create: `src/Tools/Destroy.luau`

- [ ] **Step 1: Create `src/Tools/Destroy.luau`**

```lua
--!strict
-- Destroy: the destroy_instance tool — delete the instance at a path via Instance:Destroy(), with NO
-- loadstring (works during a playtest as well as in edit; undoable in edit). A safety guard refuses to
-- delete `game` itself or a top-level service, so the agent can clear its own builds but not nuke
-- Workspace/Players. Mirrors Create.luau/Properties.luau plumbing.
--
-- Tools/ submodule: reaches its Tools siblings (Path, RegionGuard) via script.Parent.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Path = require(script.Parent.Path)
local RegionGuard = require(script.Parent.RegionGuard)

local Destroy = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

-- Refuse to delete the DataModel itself, a top-level service (direct child of game), or an instance
-- already detached from the tree. Returns an error string when protected, else nil.
local function protectedReason(inst: Instance): string?
	if inst == game then
		return "refusing to destroy the DataModel (game)"
	end
	if inst.Parent == game then
		return "refusing to destroy a top-level service: " .. inst.Name
	end
	if inst.Parent == nil then
		return "instance is already detached (no parent)"
	end
	return nil
end

local function runDestroy(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.path) ~= "string" then
		return encodeResult({ ok = false, error = "destroy_instance requires { path = <string> }" }),
			true
	end

	local inst, err = Path.resolve(args.path)
	if inst == nil then
		return encodeResult({ ok = false, error = err }), true
	end
	local target = inst :: Instance

	local guard = protectedReason(target)
	if guard ~= nil then
		return encodeResult({ ok = false, error = guard }), true
	end

	-- Region guard (parallel writer): the target must be within the writer's region. No-op serially.
	local okRegion, regionErr = RegionGuard.check(target, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end

	-- Capture identity BEFORE destroying (the instance is locked/cleared afterward).
	local fullPath = Path.fullPath(target)
	local class = target.ClassName

	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("Destroy " .. class)
		if rid == nil then
			return encodeResult({ ok = false, error = "could not begin a change recording" }), true
		end
	end

	local okDestroy = pcall(function()
		target:Destroy()
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okDestroy
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okDestroy then
		return encodeResult({ ok = false, error = "Destroy() failed for " .. fullPath }), true
	end
	return encodeResult({ ok = true, destroyed = fullPath, class = class }), false
end

Destroy.descriptors = {
	{
		name = "destroy_instance",
		description = "Delete the instance at a case-sensitive dot path via Instance:Destroy(). Uses the "
			.. "engine API directly — NO loadstring — so it works DURING A PLAYTEST as well as in edit "
			.. "(undoable in edit). Use this to remove a build you no longer want instead of reparenting "
			.. "it elsewhere. Refuses to destroy game or a top-level service. Returns the destroyed path "
			.. "and class.",
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Dot-separated, case-sensitive path to the instance to delete.",
				},
			},
			required = { "path" },
		},
		destructive = true,
		run = runDestroy,
	},
} :: { Descriptor }

return Destroy
```

- [ ] **Step 2: Lint + build**

Run: `selene src/` then `stylua --check src/` (auto-format if needed) then `rojo build default.project.json -o StudioAgent.rbxm`
Expected: 0 errors / 0 warnings, BUILD OK.

- [ ] **Step 3: Commit**

```bash
git add src/Tools/Destroy.luau
git commit -m "feat(tools): destroy_instance — guarded Instance:Destroy() (edit + playtest)"
```

---

## Task 4: Wire-up (registry, RelaySpec, SystemPrompt) + in-Studio specs

**Files:**
- Modify: `src/Tools/init.luau`
- Modify: `src/RelaySpec.luau`
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Register both tools in `src/Tools/init.luau`**

Add the requires near the other tool requires (after `local SkillsTool = require(script.Skills)`):

```lua
local DestroyTool = require(script.Destroy)
local PlaceTool = require(script.Place)
```

Add the append loops after the existing `for _, descriptor in CreateTool.descriptors do ... end` block (placement next to Create is fine — anywhere after the registry table is created):

```lua
for _, descriptor in DestroyTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in PlaceTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Update the registry-order comment near the top of the file to include the two new names, e.g. append `destroy_instance, place_relative` to the listed registry.

- [ ] **Step 2: Add both to `EXPECTED_RELAY` in `src/RelaySpec.luau`**

In the `EXPECTED_RELAY` table, after `"create_instance",` add:

```lua
	"destroy_instance",
	"place_relative",
```

(They mutate the DataModel, so they relay in client-view play — same class as create_instance. This keeps the "classification covers the whole custom registry (no drift)" test green.)

- [ ] **Step 3: Add tool entries + guidance to `src/SystemPrompt.luau`**

(a) In the main tool list, after the `create_instance(...)` bullet, add:

```lua
- destroy_instance(path): DELETE the instance at a path (engine API, works in playtest). Use this to remove a build you no longer want — do NOT reparent unwanted builds elsewhere.
- place_relative(target, anchor, direction, distance): position `target` relative to `anchor` by an anchor-local direction (front/back/left/right/up/down) + distance. Use this for relative placement — never hand-compute CFrames or LookVector signs.
```

(b) In the subagent/read-only tool list section, do NOT add these (they are write tools; leave that list unchanged).

- [ ] **Step 4: Lint + build**

Run: `selene src/` then `stylua --check src/` (auto-format if needed) then `rojo build default.project.json -o StudioAgent.rbxm`
Expected: 0 errors / 0 warnings, BUILD OK.

- [ ] **Step 5: Run RelaySpec + PlaceSpec in Studio**

Temporarily add `require(script.RelaySpec).run()` and `require(script.PlaceSpec).run()` to `src/init.server.luau` (before the final print), `build.ps1`, reopen Studio on a fresh Baseplate, read Output.
Expected: RelaySpec `Summary: 15/15 passed` (no drift — the two new names classified), PlaceSpec `4/4 passed`. Then REMOVE the temporary requires and rebuild/reinstall clean.

- [ ] **Step 6: Commit**

```bash
git add src/Tools/init.luau src/RelaySpec.luau src/SystemPrompt.luau
git commit -m "feat(tools): register + classify destroy_instance/place_relative; system-prompt guidance"
```

---

## Task 5: Live verification (fresh Baseplate)

**Files:** none (manual; no code change unless a bug is found).

- [ ] **Step 1: Build + install, open a fresh Baseplate**

Run `build.ps1`, reopen Studio. (No sidecar needed — these tools don't capture.)

- [ ] **Step 2: Verify `place_relative` anchor-local correctness (command bar or via the agent)**

Create an anchor part, rotate it 90° about Y (`anchor.CFrame = anchor.CFrame * CFrame.Angles(0, math.rad(90), 0)`), create a small target part, then drive `place_relative { target, anchor, direction="front", distance=8 }`. Expected: the target lands 8 studs along the direction the anchor FACES (world −X for a +90° yaw), not world −Z. Verify visually and/or by reading the target's Position.

- [ ] **Step 3: Verify `destroy_instance`**

`destroy_instance` the target part. Expected: it's gone (`get_tree`/Explorer confirms); Ctrl+Z restores it (undoable in edit). Then `destroy_instance { path = "game.Workspace" }`. Expected: refused with the top-level-service guard error, Workspace intact.

- [ ] **Step 4: Update the handoff**

Note the two tools shipped in `HANDOFF.md` (the §3 agent-quality gaps are now closed). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: destroy_instance + place_relative shipped"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** destroy_instance (Task 3: single path, service guard, undoable, region guard, result) ✓; place_relative (Tasks 1-2: anchor-local DIRS, offsetPoint pure math, BasePart/Model anchor + target, position-only, region guard, undoable) ✓; wiring incl. RelaySpec no-drift + SystemPrompt (Task 4) ✓; PlaceSpec incl. rotated-anchor case (Task 1) ✓; live-verify incl. the guard rejection (Task 5) ✓. All §-requirements covered.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code.
- **Type/name consistency:** `Place.DIRS`, `Place.offsetPoint`, `Place.descriptors`, `anchorCFrame`, `positionTarget`, `runPlace`; `Destroy.descriptors`, `protectedReason`, `runDestroy`; `encodeResult` local to each module; `Path.resolve`/`Path.fullPath`, `RegionGuard.check`, `Serialize.encode` used exactly as in `Create.luau`/`Properties.luau`. `EXPECTED_RELAY` names match the descriptor `name`s (`destroy_instance`, `place_relative`).
