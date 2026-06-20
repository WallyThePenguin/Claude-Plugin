# Spherical Camera-Lock Rig Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a stateful, navigable spherical camera locked on a target (orbit by azimuth/elevation/radius via relative moves, capturing after each) — the inspection foundation for the Asset Creator loop.

**Architecture:** A stateful `CameraRig` controller (in `deps`) wraps the proven `CaptureCore` spherical math (`frameCFrame`/`setCamera`/`resolveTarget`); it moves the real `Workspace.CurrentCamera` (so the user sees it live). Three parent-only tools (`camera_focus`/`camera_orbit`/`camera_release`) drive it and capture after each move. Optional debug gizmos (Config flag, default off) visualize the orbit sphere/camera/pivot.

**Tech Stack:** Luau (`--!strict`, Roblox Studio plugin); rokit (`rojo`/`selene`/`stylua`). Reuses `src/Tools/CaptureCore.luau`.

**Source spec:** `docs/superpowers/specs/2026-06-20-studio-agent-spherical-camera-rig-design.md`.

---

## Domain-adaptation note

Luau-in-Studio can't be unit-run here, so: **static verification here** (`selene src` 0/0, `stylua --check src`, `rojo build` via `.\build.ps1`) + an **in-Studio Spec self-test** for the pure helpers (`CameraRigSpec`, run by the user) + a **live test** (camera moves/captures in Studio). TDD applies to the pure spherical-state helpers via the Spec.

## File structure

- Create: `src/CameraRig.luau` — stateful controller; pure helpers (`wrapAzimuth`/`clampElevation`/`clampZoom`/`applyMove`) + methods (`focus`/`orbit`/`release`/`state`/`setDebug`/`isDebug`/`drawGizmos`/`removeGizmos`).
- Create: `src/CameraRigSpec.luau` — in-Studio self-test for the pure helpers.
- Create: `src/Tools/CameraRig.luau` — the 3 tool descriptors.
- Modify: `src/Config.luau` (the `cameraRigDebug` flag), `src/init.server.luau` (deps), `src/AgentLoop.luau` (thread `cameraRig`), `src/UI/Widget.luau` (send call), `src/Tools/init.luau` (register), `src/Relay.luau` (LOCAL_TOOLS), `src/SystemPrompt.luau` (docs).

---

## Task 1: Config flag `cameraRigDebug`

**Files:** Modify `src/Config.luau`

- [ ] **Step 1: Add the default** — in the `DEFAULTS` table, after the `webFetchMaxUses = 5,` line (the last entry, ~line 45), add:

```lua
	-- Camera-lock rig: when true, draw debug gizmos (orbit sphere/camera/pivot). Default off.
	cameraRigDebug = false,
```

- [ ] **Step 2: Add validation** — in `Config.set`, after the `webFetchMaxUses` branch's `end` (~line 240, just before the final `self._plugin:SetSetting(...)`), add:

```lua
	elseif key == "cameraRigDebug" then
		if type(value) ~= "boolean" then
			return false, "cameraRigDebug must be a boolean"
		end
```

- [ ] **Step 3: Add the getter** — after `Config.getConfirmDestructive` (~line 341), add:

```lua
function Config.getCameraRigDebug(self: Config): boolean
	return self:get("cameraRigDebug") :: boolean
end
```

- [ ] **Step 4: Verify** — Run: `stylua src/Config.luau && selene src 2>&1 | tail -3 && stylua --check src/Config.luau && echo clean`
Expected: `0 errors / 0 warnings` and `clean`.

- [ ] **Step 5: Commit**

```bash
git add src/Config.luau
git commit -m "feat: cameraRigDebug config flag (default off)"
```

---

## Task 2: CameraRig controller + Spec

**Files:** Create `src/CameraRig.luau`, `src/CameraRigSpec.luau`

- [ ] **Step 1: Write `src/CameraRig.luau`**

```lua
--!strict
-- CameraRig: a stateful, navigable "spherical camera-lock rig". Locks the editor camera aiming at a
-- target and orbits it on a sphere (azimuth + elevation + radius), driven by relative moves. Reuses
-- CaptureCore for all framing/camera math (frameCFrame/setCamera/saveCamera/restoreCamera/resolveTarget),
-- so it never hand-writes CFrames. PURE helpers (wrapAzimuth/clampElevation/clampZoom/applyMove) are
-- unit-tested in CameraRigSpec; the methods touch CaptureCore + Workspace. One instance in deps.cameraRig.
-- Optional DEBUG gizmos (Config cameraRigDebug, default off) visualize the orbit sphere/camera/pivot.

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local CaptureCore = require(script.Parent.Tools.CaptureCore)

local CameraRig = {}
CameraRig.__index = CameraRig

local ELEV_MIN, ELEV_MAX = -89, 89
local ZOOM_MIN, ZOOM_MAX = 0.2, 8
local GIZMO_FOLDER = "__StudioAgentCameraRig"
local GIZMO_TAG = "StudioAgentCameraRigGizmo"

export type State = { azimuth: number, elevation: number, distScale: number }
export type Move = { azimuth: number?, elevation: number?, zoom: number?, relative: boolean? }

-- ---- pure helpers (no DataModel — directly unit-testable) ----

function CameraRig.wrapAzimuth(a: number): number
	if a ~= a then
		return 0
	end
	local r = a % 360
	if r < 0 then
		r += 360
	end
	return r
end

function CameraRig.clampElevation(e: number): number
	if e ~= e then
		return 0
	end
	if e < ELEV_MIN then
		return ELEV_MIN
	end
	if e > ELEV_MAX then
		return ELEV_MAX
	end
	return e
end

function CameraRig.clampZoom(z: number): number
	if z ~= z then
		return 1
	end
	if z < ZOOM_MIN then
		return ZOOM_MIN
	end
	if z > ZOOM_MAX then
		return ZOOM_MAX
	end
	return z
end

-- Apply a move to a state. relative (default true) adds deltas; false sets absolute values. Missing
-- fields keep the current value. Returns a NEW clamped/wrapped state.
function CameraRig.applyMove(state: State, move: Move): State
	local relative = move.relative ~= false
	local az, el, z = state.azimuth, state.elevation, state.distScale
	if move.azimuth ~= nil then
		az = if relative then az + move.azimuth else move.azimuth
	end
	if move.elevation ~= nil then
		el = if relative then el + move.elevation else move.elevation
	end
	if move.zoom ~= nil then
		z = if relative then z + move.zoom else move.zoom
	end
	return {
		azimuth = CameraRig.wrapAzimuth(az),
		elevation = CameraRig.clampElevation(el),
		distScale = CameraRig.clampZoom(z),
	}
end

-- ---- instance (live controller) ----

export type CameraRig = typeof(setmetatable(
	{} :: {
		_config: any,
		_center: Vector3?,
		_size: Vector3?,
		_state: State,
		_saved: any,
	},
	CameraRig
))

local function defaultState(): State
	return { azimuth = 35, elevation = 20, distScale = 1 }
end

function CameraRig.new(config: any): CameraRig
	return setmetatable({
		_config = config,
		_center = nil,
		_size = nil,
		_state = defaultState(),
		_saved = nil,
	}, CameraRig)
end

function CameraRig.isDebug(self: CameraRig): boolean
	return self._config ~= nil and self._config:getCameraRigDebug() == true
end

local function removeFolder()
	local existing = Workspace:FindFirstChild(GIZMO_FOLDER)
	if existing ~= nil then
		existing:Destroy()
	end
end

function CameraRig.removeGizmos(_self: CameraRig)
	removeFolder()
end

local function gizmoBall(color: Color3, diameter: number, pos: Vector3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Locked = true
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = transparency
	p.Size = Vector3.new(diameter, diameter, diameter)
	p.CFrame = CFrame.new(pos)
	return p
end

-- Draw/refresh the debug gizmos: orbit sphere + pivot marker + camera marker. No-op if not focused.
function CameraRig.drawGizmos(self: CameraRig)
	removeFolder()
	if self._center == nil then
		return
	end
	local center = self._center :: Vector3
	local cam = Workspace.CurrentCamera
	if cam == nil then
		return
	end
	local camPos = cam.CFrame.Position
	local radius = math.max((camPos - center).Magnitude, 1)
	local folder = Instance.new("Folder")
	folder.Name = GIZMO_FOLDER
	CollectionService:AddTag(folder, GIZMO_TAG)

	local sphere = gizmoBall(Color3.fromRGB(80, 160, 255), radius * 2, center, 0.85)
	sphere.Name = "OrbitSphere"
	sphere.Parent = folder

	local pivot = gizmoBall(Color3.fromRGB(255, 200, 0), 1, center, 0)
	pivot.Name = "Pivot"
	pivot.Parent = folder

	local camMarker = gizmoBall(Color3.fromRGB(255, 60, 60), 1.5, camPos, 0)
	camMarker.Name = "CameraMarker"
	camMarker.Parent = folder

	folder.Parent = Workspace
end

function CameraRig.setDebug(self: CameraRig, on: boolean)
	if self._config ~= nil then
		self._config:set("cameraRigDebug", on == true)
	end
	if on then
		self:drawGizmos()
	else
		self:removeGizmos()
	end
end

-- Lock onto a target (path or selection). Frames it at a 3/4 view, saves the user's camera (first
-- focus), sets the camera, refreshes gizmos if debug. Returns (state, errString?).
function CameraRig.focus(self: CameraRig, target: any): (State?, string?)
	local center, size, err = CaptureCore.resolveTarget(target)
	if center == nil or size == nil then
		return nil, err
	end
	if self._saved == nil then
		self._saved = CaptureCore.saveCamera()
	end
	self._center = center
	self._size = size
	self._state = defaultState()
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(
			center :: Vector3,
			size :: Vector3,
			self._state.azimuth,
			self._state.elevation,
			self._state.distScale
		)
	)
	if self:isDebug() then
		self:drawGizmos()
	end
	return self._state, nil
end

-- Apply a relative/absolute orbit move. Requires a prior focus. Returns (state, errString?).
function CameraRig.orbit(self: CameraRig, move: Move): (State?, string?)
	if self._center == nil or self._size == nil then
		return nil, "no target locked — call camera_focus first."
	end
	self._state = CameraRig.applyMove(self._state, move)
	CaptureCore.setCamera(
		CaptureCore.frameCFrame(
			self._center :: Vector3,
			self._size :: Vector3,
			self._state.azimuth,
			self._state.elevation,
			self._state.distScale
		)
	)
	if self:isDebug() then
		self:drawGizmos()
	end
	return self._state, nil
end

-- Restore the user's pre-focus camera + clear gizmos + unlock. Returns whether a target was locked.
function CameraRig.release(self: CameraRig): boolean
	self:removeGizmos()
	if self._saved ~= nil then
		CaptureCore.restoreCamera(self._saved)
		self._saved = nil
	end
	local was = self._center ~= nil
	self._center = nil
	self._size = nil
	return was
end

function CameraRig.state(self: CameraRig): State
	return self._state
end

return CameraRig
```

- [ ] **Step 2: Write `src/CameraRigSpec.luau`**

```lua
--!strict
-- CameraRigSpec: in-Studio self-test for the PURE CameraRig helpers (no DataModel). Run via
-- temporarily adding `require(script.CameraRigSpec).run()` to init.server.luau, build, reopen Studio,
-- read Output. Mirrors SkillCatalogSpec.

local CameraRig = require(script.Parent.CameraRig)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function approx(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("wrapAzimuth wraps into [0,360)", function()
		return approx(CameraRig.wrapAzimuth(370), 10)
			and approx(CameraRig.wrapAzimuth(-30), 330)
			and approx(CameraRig.wrapAzimuth(360), 0)
			and approx(CameraRig.wrapAzimuth(45), 45)
	end)

	add("clampElevation clamps to [-89,89]", function()
		return approx(CameraRig.clampElevation(95), 89)
			and approx(CameraRig.clampElevation(-120), -89)
			and approx(CameraRig.clampElevation(45), 45)
	end)

	add("clampZoom clamps to [0.2,8]", function()
		return approx(CameraRig.clampZoom(0), 0.2)
			and approx(CameraRig.clampZoom(99), 8)
			and approx(CameraRig.clampZoom(1), 1)
	end)

	add("applyMove relative adds deltas + clamps/wraps", function()
		local s = { azimuth = 35, elevation = 20, distScale = 1 }
		local a = CameraRig.applyMove(s, { azimuth = 30 })
		local b = CameraRig.applyMove(s, { elevation = 80 }) -- 100 -> 89
		local c = CameraRig.applyMove(s, { zoom = 10 }) -- 11 -> 8
		return approx(a.azimuth, 65)
			and approx(a.elevation, 20)
			and approx(b.elevation, 89)
			and approx(c.distScale, 8)
	end)

	add("applyMove absolute sets values; missing fields unchanged", function()
		local s = { azimuth = 35, elevation = 20, distScale = 1 }
		local abs = CameraRig.applyMove(s, { elevation = 89, azimuth = 400, relative = false })
		local none = CameraRig.applyMove(s, {})
		return approx(abs.elevation, 89)
			and approx(abs.azimuth, 40) -- 400 wraps to 40
			and approx(abs.distScale, 1)
			and approx(none.azimuth, 35)
			and approx(none.elevation, 20)
			and approx(none.distScale, 1)
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
			print("[CameraRigSpec] PASS " .. c.name)
		else
			warn("[CameraRigSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[CameraRigSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Verify** — Run: `stylua src/CameraRig.luau src/CameraRigSpec.luau && selene src 2>&1 | tail -3 && stylua --check src/CameraRig.luau src/CameraRigSpec.luau && echo clean`
Expected: `0 errors / 0 warnings` and `clean`. (If selene flags a single-arg `assert`, none is used here; if it flags an unused var, fix inline.)

- [ ] **Step 4: Commit**

```bash
git add src/CameraRig.luau src/CameraRigSpec.luau
git commit -m "feat: CameraRig controller (spherical state + camera + debug gizmos) + spec"
```

---

## Task 3: Camera tools + registration

**Files:** Create `src/Tools/CameraRig.luau`; Modify `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/CameraRig.luau`**

```lua
--!strict
-- Camera-rig tools: camera_focus / camera_orbit / camera_release. Drive the stateful spherical
-- CameraRig (context.cameraRig) and capture after each move so the agent SEES the result. Parent-only
-- (not in subagent allowlists; nil-guards context.cameraRig). Non-destructive (a camera move isn't a
-- place-content edit). focus/orbit return a tool_result blocks array (a state line + the image), like
-- capture_angles; on any failure they fall back to a string error (isError=true).

local CaptureCore = require(script.Parent.CaptureCore)

local CameraRigTools = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function rig(context: any): any
	return if type(context) == "table" then context.cameraRig else nil
end

local function stateLine(prefix: string, s: any): string
	return string.format(
		"%s — azimuth %d°, elevation %d°, zoom %.2f",
		prefix,
		math.floor(s.azimuth + 0.5),
		math.floor(s.elevation + 0.5),
		s.distScale
	)
end

-- After a camera move, capture the viewport and return [state text + image]. (content, isError).
local function captureWithState(text: string, context: any): (any, boolean)
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return "camera: CaptureService did not produce a screenshot (focus Studio and retry).", true
	end
	CaptureCore.settle(2)
	local config = if type(context) == "table" then context.config else nil
	local blocks, err = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return err :: string, true
	end
	local content: { any } = { { type = "text", text = text } }
	for _, b in blocks do
		table.insert(content, b)
	end
	return content, false
end

local function maybeSetDebug(r: any, args: any)
	if type(args.debug) == "boolean" then
		r:setDebug(args.debug)
	end
end

local function runFocus(input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_focus is not available here (no camera rig in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	maybeSetDebug(r, args)
	local state, err = r:focus(args.target)
	if state == nil then
		return "camera_focus: " .. tostring(err), true
	end
	return captureWithState(stateLine("locked + framed", state), context)
end

local function runOrbit(input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_orbit is not available here (no camera rig in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	maybeSetDebug(r, args)
	local move = {
		azimuth = if type(args.azimuth) == "number" then args.azimuth else nil,
		elevation = if type(args.elevation) == "number" then args.elevation else nil,
		zoom = if type(args.zoom) == "number" then args.zoom else nil,
		relative = args.relative ~= false,
	}
	local state, err = r:orbit(move)
	if state == nil then
		return "camera_orbit: " .. tostring(err), true
	end
	return captureWithState(stateLine("moved", state), context)
end

local function runRelease(_input: any, context: any): (any, boolean)
	local r = rig(context)
	if r == nil then
		return "camera_release is not available here (no camera rig in this context)", true
	end
	local was = r:release()
	return (
		if was
			then "camera released — your view is restored."
			else "camera was not locked; nothing to release."
	),
		false
end

CameraRigTools.descriptors = {
	{
		name = "camera_focus",
		description = "LOCK the camera onto a target and frame it (a 3/4 view), then capture so you SEE "
			.. "it. The camera stays locked aiming at the target center; use camera_orbit to move around "
			.. "it and camera_release when done. Inputs: target (instance path; omit to use the current "
			.. "selection), debug (optional bool — show/hide the orbit-sphere gizmos). Returns the framed "
			.. "image + the camera state. Requires the vision sidecar (like capture).",
		inputSchema = {
			type = "object",
			properties = {
				target = {
					type = "string",
					description = "Instance path; omit to use the selection.",
				},
				debug = {
					type = "boolean",
					description = "Show/hide the debug gizmos (orbit sphere/pivot/camera).",
				},
			},
		},
		destructive = false,
		run = runFocus,
	},
	{
		name = "camera_orbit",
		description = "Move the locked camera on its sphere and capture. Relative by default — azimuth "
			.. "(horizontal orbit, deg), elevation (vertical orbit, deg; ~89 = birds-eye), zoom (radius "
			.. "delta; negative = closer). Pass relative=false to SET absolute values instead (e.g. "
			.. "elevation=89 for top-down). Requires a prior camera_focus. Returns the new image + state. "
			.. "(You NEVER compute CFrames — describe the move and the rig does the math.)",
		inputSchema = {
			type = "object",
			properties = {
				azimuth = { type = "number", description = "Horizontal orbit in degrees." },
				elevation = { type = "number", description = "Vertical orbit in degrees (~89 = top)." },
				zoom = {
					type = "number",
					description = "Radius change (relative) or absolute zoom scale if relative=false.",
				},
				relative = {
					type = "boolean",
					description = "Default true (deltas). false = set absolute azimuth/elevation/zoom.",
				},
				debug = {
					type = "boolean",
					description = "Show/hide the debug gizmos.",
				},
			},
		},
		destructive = false,
		run = runOrbit,
	},
	{
		name = "camera_release",
		description = "Restore the user's original camera (undo the lock) and remove any debug gizmos. "
			.. "Call this when you're done inspecting so the user gets their view back.",
		inputSchema = { type = "object", properties = {} },
		destructive = false,
		run = runRelease,
	},
} :: { Descriptor }

return CameraRigTools
```

- [ ] **Step 2: Register in `src/Tools/init.luau`** — after `local RubricsTool = require(script.Rubrics)` add:

```lua
local CameraRigTool = require(script.CameraRig)
```

After the `RubricsTool` registration loop add:

```lua
for _, descriptor in CameraRigTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

- [ ] **Step 3: Verify** — Run: `stylua src/Tools/CameraRig.luau src/Tools/init.luau && selene src 2>&1 | tail -3 && stylua --check src/Tools/CameraRig.luau src/Tools/init.luau && echo clean`
Expected: `0 errors / 0 warnings` and `clean`.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/CameraRig.luau src/Tools/init.luau
git commit -m "feat: camera_focus/camera_orbit/camera_release tools + register"
```

---

## Task 4: Wiring (deps, thread, Widget, relay, SystemPrompt)

**Files:** Modify `src/init.server.luau`, `src/AgentLoop.luau`, `src/UI/Widget.luau`, `src/Relay.luau`, `src/SystemPrompt.luau`

- [ ] **Step 1: `src/init.server.luau`** — after `local RubricStore = require(script.RubricStore)` add:

```lua
local CameraRig = require(script.CameraRig)
```

In `deps`, after `rubrics = RubricStore.new(),` add:

```lua
	cameraRig = CameraRig.new(config),
```

- [ ] **Step 2: `src/AgentLoop.luau` — thread `cameraRig` (same pattern as `rubrics`)**

In `runLoop`'s signature, change:

```lua
	rubrics: any,
	snapshot: number,
```
to:
```lua
	rubrics: any,
	cameraRig: any,
	snapshot: number,
```

In `toolContext`, change:
```lua
		rubrics = rubrics,
	}
```
to:
```lua
		rubrics = rubrics,
		cameraRig = cameraRig,
	}
```

In `AgentLoop.send`'s signature, change:
```lua
	rubrics: any,
	userText: string,
```
to:
```lua
	rubrics: any,
	cameraRig: any,
	userText: string,
```

In the `pcall(runLoop, ...)` call, change:
```lua
			rubrics,
			snapshot,
```
to:
```lua
			rubrics,
			cameraRig,
			snapshot,
```

- [ ] **Step 3: `src/UI/Widget.luau`** — in the `deps.agentLoop.send(...)` call, change:

```lua
			deps.rubrics,
			text,
```
to:
```lua
			deps.rubrics,
			deps.cameraRig,
			text,
```

- [ ] **Step 4: `src/Relay.luau`** — in `LOCAL_TOOLS`, after `use_rubric = true,` add:

```lua
	camera_focus = true,
	camera_orbit = true,
	camera_release = true,
```

- [ ] **Step 5: `src/SystemPrompt.luau` — document the tools + workflow**

After the `- use_rubric(category): ...` tool line add:

```lua
- camera_focus(target) / camera_orbit(...) / camera_release(): lock the camera onto a target and orbit it on a sphere to inspect from any angle — see "Inspecting visually".
```

Before the `# Track multi-step work` section header, add this section:

```
# Inspecting visually (camera rig)
To inspect anything 3D from any angle, LOCK the camera onto it with camera_focus(target) — the camera frames it and stays aimed at its center. Then camera_orbit to move around it on a sphere: azimuth (horizontal), elevation (vertical; ~89 = birds-eye), zoom (radius). Moves are RELATIVE by default ("orbit 45° left" = azimuth=-45); pass relative=false to set an absolute view (elevation=89 for top-down). Each call captures, so you SEE where you landed — iterate. Call camera_release when done so the user gets their view back. You never compute CFrames; describe the move. (Requires the vision sidecar, like capture; edit / Server view.)
```

- [ ] **Step 6: Verify the whole build** — Run: `stylua src && selene src 2>&1 | tail -3 && stylua --check src && echo "stylua clean"`
Expected: `0 errors / 0 warnings` and `stylua clean`.
Then Run (PowerShell): `.\build.ps1`
Expected: `Built project to StudioAgent.rbxm` + `Installed -> ...Plugins\StudioAgent.rbxm`.

- [ ] **Step 7: Commit**

```bash
git add src/init.server.luau src/AgentLoop.luau src/UI/Widget.luau src/Relay.luau src/SystemPrompt.luau
git commit -m "feat: wire CameraRig into deps, send/runLoop, relay, and SystemPrompt"
```

---

## Task 5: In-Studio verification (user) + handoff

**Files:** none (verification only; assistant has done all static verification).

- [ ] **Step 1: Spec self-test (user, in Studio)** — temporarily add `require(script.CameraRigSpec).run()` near the end of `src/init.server.luau`; `.\build.ps1`; reopen Studio; read Output. Expected: `[CameraRigSpec] 5/5 passed`. Remove the temp line + rebuild.

- [ ] **Step 2: Live test (user, in Studio; sidecar + a part in the scene)** — in a chat: "camera_focus on <a part>" → the viewport swings to a ¾ framed view + a capture returns. "camera_orbit elevation 89 (absolute)" → view rises to birds-eye + captures. "camera_orbit azimuth -90" → orbits a quarter-turn + captures. "turn on camera debug and orbit" → the orbit-sphere/pivot/camera gizmos appear. "camera_release" → original view restored, gizmos gone.

- [ ] **Step 3: Report** — if the Spec passes + the live checks hold, the rig is delivered. Failures will be runtime/integration (static layer is green) — capture the Output and debug from the symptom.

---

## Self-review (completed by author)

- **Spec coverage:** invisible math controller + `frameCFrame` reuse → Task 2 (`focus`/`orbit` call `CaptureCore.frameCFrame`/`setCamera`). Spherical model + clamps → Task 2 pure helpers + Spec (Task 2). 3 tools + auto-capture → Task 3. Debug mode (Config flag default off + gizmos) → Task 1 + Task 2 (`drawGizmos`/`setDebug`) + the `debug` tool param (Task 3). Wiring (deps/preamble-not-needed/toolContext/Widget/relay/SystemPrompt) → Task 4. Testing → Task 2 Spec + Task 4 build + Task 5. Camera save/restore (release) → Task 2 `focus`/`release`. **No gaps.**
- **Placeholder scan:** none — full code in every new file; every edit names the exact anchor + inserted code.
- **Type/name consistency:** `CameraRig.{wrapAzimuth,clampElevation,clampZoom,applyMove,new,focus,orbit,release,state,setDebug,isDebug,drawGizmos,removeGizmos}`, the `State`/`Move` types, `context.cameraRig`, the `cameraRig` deps key + threaded param, the 3 tool names (`camera_focus`/`camera_orbit`/`camera_release`), and `Config.getCameraRigDebug`/the `cameraRigDebug` key are used identically across Tasks 1-4. `require(script.Parent.Tools.CaptureCore)` (from `src/CameraRig.luau`) and `require(script.Parent.CaptureCore)` (from `src/Tools/CameraRig.luau`) are the correct relative paths.
