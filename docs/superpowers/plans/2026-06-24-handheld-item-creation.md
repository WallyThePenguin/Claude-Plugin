# Handheld Item Creation (`make_tool` + `grip_tool`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent `make_tool(target, name?, handle?)` to turn a built Part/Model into an equippable Roblox `Tool` (Handle + welds), and `grip_tool(tool, rig?, offset?, rot?)` to equip it on a rig, set the grip from intuitive params, and capture so it fits the grip by looking — the foundation of interactive items.

**Architecture:** A `ToolFactory` engine (PURE `gripCFrame(offset, rot) -> CFrame` unit-tested in a spec + impure `toolify`/`resolveRig`/`equip`/`applyGrip`) backs two thin descriptors in `Tools/Item.luau`. `make_tool` toolifies a built visual; `grip_tool` equips + sets `Tool.Grip` + frames the Handle and captures (reusing `context.cameraRig` + `CaptureCore`, like `camera_focus`). Both write the DataModel → RELAY.

**Tech Stack:** Luau (`--!strict`), Roblox `Tool`/`WeldConstraint`/`Humanoid` (edit-mode auto-equip + live `Tool.Grip` verified callable from the bridge this session), `CaptureCore` (existing), Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Create `src/ToolFactory.luau`** — the engine. PURE `gripCFrame` + impure `toolify`/`resolveRig`/`equip`/`applyGrip`.
- **Create `src/ToolFactorySpec.luau`** — in-Studio spec for `gripCFrame`.
- **Create `src/Tools/Item.luau`** — the `make_tool` + `grip_tool` descriptors.
- **Modify `src/Tools/init.luau`** — require + append `ItemTool.descriptors`.
- **Modify `src/RelaySpec.luau`** — add `make_tool` + `grip_tool` to `EXPECTED_RELAY`.
- **Modify `src/SystemPrompt.luau`** — a "# Building handheld items" note + tool-index lines.

**Luau testing note:** no local Luau runtime. The pure spec runs *in-Studio* (or via the bridge: `luau 'return tostring(require(script.Parent.ToolFactorySpec).run())'`) after a build + USER restart. The per-task static gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). `rojo build` does NOT type-check. Python n/a.

---

### Task 1: ToolFactory pure `gripCFrame` + spec

**Files:** Create `src/ToolFactory.luau`; Create `src/ToolFactorySpec.luau`.

- [ ] **Step 1: Create `src/ToolFactory.luau` (pure section only)**

```lua
--!strict
-- ToolFactory: the handheld-item engine. PURE gripCFrame (intuitive offset/rot -> a Tool.Grip CFrame) is
-- unit-tested in ToolFactorySpec; the impure toolify/resolveRig/equip/applyGrip (build the Tool + Handle +
-- welds, equip on a rig, set the live grip) are added in Task 2 and are live-verified. Backs make_tool +
-- grip_tool. See docs/superpowers/specs/2026-06-24-handheld-item-creation-design.md.

local ToolFactory = {}

export type Vec3ish = { x: number?, y: number?, z: number? }
export type Rotish = { rx: number?, ry: number?, rz: number? }

-- ---- pure ----

-- Build a Tool.Grip CFrame from intuitive params: a translation (studs) then an XYZ rotation (degrees).
-- Missing fields default to 0 (identity = the Handle center in the palm). PURE -> unit-testable.
function ToolFactory.gripCFrame(offset: Vec3ish?, rot: Rotish?): CFrame
	local o = offset or {}
	local r = rot or {}
	local ox = if type(o.x) == "number" then o.x else 0
	local oy = if type(o.y) == "number" then o.y else 0
	local oz = if type(o.z) == "number" then o.z else 0
	local rx = if type(r.rx) == "number" then r.rx else 0
	local ry = if type(r.ry) == "number" then r.ry else 0
	local rz = if type(r.rz) == "number" then r.rz else 0
	return CFrame.new(ox, oy, oz) * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
end

return ToolFactory
```

- [ ] **Step 2: Create `src/ToolFactorySpec.luau`**

```lua
--!strict
-- ToolFactorySpec: in-Studio self-test for the PURE ToolFactory.gripCFrame (no DataModel). Run via
-- `require(script.ToolFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.ToolFactorySpec).run())'.

local ToolFactory = require(script.Parent.ToolFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("gripCFrame: identity default", function()
		local g = ToolFactory.gripCFrame(nil, nil)
		return g.Position == Vector3.new(0, 0, 0)
	end)

	add("gripCFrame: offset -> position", function()
		local g = ToolFactory.gripCFrame({ x = 1, y = 2, z = 3 }, nil)
		return g.Position == Vector3.new(1, 2, 3)
	end)

	add("gripCFrame: a Y rotation reorients (-Z maps to +/-X, Y unchanged)", function()
		local g = ToolFactory.gripCFrame(nil, { ry = 90 })
		local v = g:VectorToWorldSpace(Vector3.new(0, 0, -1))
		if math.abs(v.Y) > 0.01 then
			return false, "Y not preserved: " .. tostring(v.Y)
		end
		if math.abs(math.abs(v.X) - 1) > 0.01 or math.abs(v.Z) > 0.01 then
			return false, "did not map -Z to +/-X: " .. tostring(v)
		end
		return true
	end)

	add("gripCFrame: partial fields default to 0", function()
		local g = ToolFactory.gripCFrame({ y = 5 }, { rz = 0 })
		return g.Position == Vector3.new(0, 5, 0)
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
			print("[ToolFactorySpec] PASS " .. c.name)
		else
			warn("[ToolFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[ToolFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` writes the rbxm. (Spec runs in-Studio at Task 6.)

- [ ] **Step 4: Commit**

```bash
git add src/ToolFactory.luau src/ToolFactorySpec.luau
git commit -m "feat(item): ToolFactory pure gripCFrame (offset/rot -> Grip CFrame) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: ToolFactory impure (toolify / resolveRig / equip / applyGrip)

**Files:** Modify `src/ToolFactory.luau`.

- [ ] **Step 1: Add the impure functions before `return ToolFactory`**

Insert just before the final `return ToolFactory`:

```lua
-- ---- impure (live-verified) ----

-- Collect a target's BaseParts: the part itself, or every BasePart under a Model.
local function collectParts(target: Instance): { BasePart }
	local parts: { BasePart } = {}
	if target:IsA("BasePart") then
		table.insert(parts, target :: BasePart)
	else
		for _, d in target:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d :: BasePart)
			end
		end
	end
	return parts
end

-- Resolve the Handle: a `handleHint` if it's one of `parts`; else the only part; else the Model's
-- PrimaryPart (if in parts); else the first part.
local function resolveHandle(parts: { BasePart }, target: Instance, handleHint: Instance?): BasePart
	if handleHint ~= nil and handleHint:IsA("BasePart") then
		for _, p in parts do
			if p == handleHint then
				return p
			end
		end
	end
	if #parts == 1 then
		return parts[1]
	end
	if target:IsA("Model") and (target :: Model).PrimaryPart ~= nil then
		local pp = (target :: Model).PrimaryPart
		for _, p in parts do
			if p == pp then
				return p
			end
		end
	end
	return parts[1]
end

-- Turn a built Part/Model into an equippable Tool. (Tool?, err?). The Handle is renamed "Handle"; every
-- other part is WeldConstraint'd to it; all parts are unanchored; an emptied Model wrapper is destroyed.
-- THROWS only on an engine failure (callers pcall); returns (nil, err) for a bad target.
function ToolFactory.toolify(target: Instance, handleHint: Instance?, toolName: string?): (Tool?, string?)
	local parts = collectParts(target)
	if #parts == 0 then
		return nil, "no BaseParts under the target to make a Tool from"
	end
	local handle = resolveHandle(parts, target, handleHint)
	local tool = Instance.new("Tool")
	tool.Name = if toolName ~= nil and toolName ~= "" then toolName else target.Name
	tool.RequiresHandle = true
	tool.CanBeDropped = true
	handle.Anchored = false
	handle.Name = "Handle"
	for _, p in parts do
		if p ~= handle then
			p.Anchored = false
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = handle
			wc.Part1 = p
			wc.Parent = handle
			p.Parent = tool
		end
	end
	handle.Parent = tool
	tool.Parent = workspace
	if target:IsA("Model") and target ~= tool then
		target:Destroy()
	end
	return tool, nil
end

-- Resolve a rig: an explicit Model with a Humanoid, else the first workspace Model with a Humanoid +
-- RightHand. (Model?, err?).
function ToolFactory.resolveRig(rigInst: Instance?): (Model?, string?)
	if
		rigInst ~= nil
		and rigInst:IsA("Model")
		and rigInst:FindFirstChildOfClass("Humanoid") ~= nil
	then
		return rigInst :: Model, nil
	end
	for _, d in workspace:GetChildren() do
		if
			d:IsA("Model")
			and d:FindFirstChildOfClass("Humanoid") ~= nil
			and d:FindFirstChild("RightHand") ~= nil
		then
			return d :: Model, nil
		end
	end
	return nil, "no rig found — spawn one first with spawn_rig"
end

-- Equip: parent the Tool to the rig (Roblox auto-welds the Handle to the hand in edit — verified live).
function ToolFactory.equip(tool: Tool, rig: Model)
	tool.Parent = rig
end

-- Set the live grip CFrame (re-positions the Handle without re-equip — verified live).
function ToolFactory.applyGrip(tool: Tool, grip: CFrame)
	tool.Grip = grip
end
```

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (If selene flags an unused local, fix without suppressing.)

- [ ] **Step 3: Commit**

```bash
git add src/ToolFactory.luau
git commit -m "feat(item): ToolFactory impure toolify + resolveRig + equip + applyGrip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The `make_tool` + `grip_tool` tools + registry wiring

**Files:** Create `src/Tools/Item.luau`; Modify `src/Tools/init.luau`.

- [ ] **Step 1: Create `src/Tools/Item.luau`**

```lua
--!strict
-- Handheld-item tools: make_tool (toolify a built Part/Model into a Roblox Tool) + grip_tool (equip on a
-- rig + set the grip from intuitive offset/rot + capture so the agent fits the grip by LOOKING).
-- Destructive (DataModel writes); RELAY. Parent-only.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local ToolFactory = require(script.Parent.Parent.ToolFactory)
local Path = require(script.Parent.Path)
local CaptureCore = require(script.Parent.CaptureCore)

local Item = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function runMakeTool(input: any, _context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.target) ~= "string" or args.target == "" then
		return "make_tool requires { target = <path to a built Part/Model>, name?, handle? }", true
	end
	local target, terr = Path.resolve(args.target)
	if target == nil then
		return "make_tool: target '" .. tostring(args.target) .. "' did not resolve" .. (if terr ~= nil
				then " — " .. terr
				else ""),
			true
	end
	local handleHint: Instance? = nil
	if type(args.handle) == "string" and args.handle ~= "" then
		handleHint = Path.resolve(args.handle)
	end
	local toolName = if type(args.name) == "string" then args.name else nil
	local tool: Tool?, err: string?
	local function doToolify()
		tool, err = ToolFactory.toolify(target :: Instance, handleHint, toolName)
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("make_tool")
		doToolify()
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doToolify()
	end
	if tool == nil then
		return "make_tool: " .. tostring(err), true
	end
	local t = tool :: Tool
	local partCount = 0
	for _, d in t:GetDescendants() do
		if d:IsA("BasePart") then
			partCount += 1
		end
	end
	return string.format(
		"make_tool OK: '%s' at %s (Handle + %d part(s), unanchored + welded). Equip + fit it with grip_tool.",
		t.Name,
		t:GetFullName(),
		partCount
	),
		false
end

local function runGripTool(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.tool) ~= "string" or args.tool == "" then
		return "grip_tool requires { tool = <path to a Tool>, rig?, offset? {x,y,z}, rot? {rx,ry,rz} }",
			true
	end
	local toolInst = Path.resolve(args.tool)
	if toolInst == nil or not toolInst:IsA("Tool") then
		return "grip_tool: '" .. tostring(args.tool) .. "' is not a Tool (run make_tool first)", true
	end
	local tool = toolInst :: Tool
	local rigInst: Instance? = nil
	if type(args.rig) == "string" and args.rig ~= "" then
		rigInst = Path.resolve(args.rig)
	end
	local rig, rerr = ToolFactory.resolveRig(rigInst)
	if rig == nil then
		return "grip_tool: " .. tostring(rerr), true
	end
	local theRig = rig :: Model
	local grip = ToolFactory.gripCFrame(args.offset, args.rot)
	local function doEquipGrip()
		ToolFactory.equip(tool, theRig)
		ToolFactory.applyGrip(tool, grip)
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("grip_tool")
		doEquipGrip()
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doEquipGrip()
	end
	local note = string.format(
		"grip_tool: equipped '%s' on %s, grip set. Adjust offset/rot and re-call until it sits right.",
		tool.Name,
		theRig.Name
	)
	-- frame the Handle (the held item) + capture so the agent SEES the grip
	local r = if type(context) == "table" then context.cameraRig else nil
	local handle = tool:FindFirstChild("Handle")
	if r == nil or handle == nil then
		return note .. " (no camera/Handle here — capture it yourself)", false
	end
	local state, ferr = r:focus((handle :: Instance):GetFullName())
	if state == nil then
		return note .. " (couldn't frame: " .. tostring(ferr) .. ")", false
	end
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return note .. " (CaptureService produced no screenshot — focus Studio and re-call)", false
	end
	CaptureCore.settle(2)
	local config = if type(context) == "table" then context.config else nil
	local blocks, berr = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return note .. " (capture fetch failed: " .. tostring(berr) .. ")", false
	end
	local content: { any } = { { type = "text", text = note } }
	for _, b in blocks do
		table.insert(content, b)
	end
	return content, false
end

local VEC3_SCHEMA = {
	type = "object",
	properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } },
}
local ROT_SCHEMA = {
	type = "object",
	properties = { rx = { type = "number" }, ry = { type = "number" }, rz = { type = "number" } },
}

Item.descriptors = {
	{
		name = "make_tool",
		description = "Turn a built Part/Model (an item's VISUAL — make it first with generate_mesh/"
			.. "author_mesh/paint_texture/primitives) into an equippable Roblox Tool a character can HOLD. It "
			.. "picks a Handle (a single Part, else the `handle` part, else the Model's PrimaryPart/first part), "
			.. "unanchors all parts, welds the rest to the Handle, and names it 'Handle'. Inputs: target "
			.. "(required path), name? (Tool name), handle? (path to the part to grip by). Then fit it in-hand "
			.. "with grip_tool.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string", description = "Path to the built Part/Model." },
				name = { type = "string", description = "Name for the Tool." },
				handle = {
					type = "string",
					description = "Path to the part to use as the Handle (for a multi-part item).",
				},
			},
			required = { "target" },
		},
		destructive = true,
		run = runMakeTool,
	},
	{
		name = "grip_tool",
		description = "EQUIP a Tool on a rig and FIT its grip, returning a capture so you SEE it in-hand. "
			.. "Sets Tool.Grip from intuitive offset {x,y,z} (studs) + rot {rx,ry,rz} (degrees), then frames the "
			.. "item and screenshots it. LOOK at the result and RE-CALL with adjusted offset/rot until the item "
			.. "sits right in the fist (e.g. a sword's blade pointing out, gripped near the hilt). Inputs: tool "
			.. "(required path, from make_tool), rig? (path; else the first workspace rig — spawn_rig first if "
			.. "none), offset?, rot?. Requires the vision sidecar + a focused Studio.",
		inputSchema = {
			type = "object",
			properties = {
				tool = { type = "string", description = "Path to the Tool (from make_tool)." },
				rig = {
					type = "string",
					description = "Path to a Humanoid rig; omit to use the first workspace rig.",
				},
				offset = VEC3_SCHEMA,
				rot = ROT_SCHEMA,
			},
			required = { "tool" },
		},
		destructive = true,
		run = runGripTool,
	},
} :: { Descriptor }

return Item
```

- [ ] **Step 2: Wire into the registry (`src/Tools/init.luau`)**

Add the require after `local TextureTool = require(script.Texture)`:

```lua
local ItemTool = require(script.Item)
```

Add the append loop after the `TextureTool.descriptors` loop:

```lua
for _, descriptor in ItemTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Append `, make_tool, grip_tool` to the registry comment list near the top (the line ending `... save_mesh, paint_texture.`).

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Item.luau src/Tools/init.luau
git commit -m "feat(tools): make_tool + grip_tool (toolify a build into a held, grip-fitted Tool) + register

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Relay classification (no-drift)

**Files:** Modify `src/RelaySpec.luau`.

- [ ] **Step 1: Add both tools to `EXPECTED_RELAY`**

In `src/RelaySpec.luau`, the `EXPECTED_RELAY` list has `... "paint_texture",` (added last feature). Add `make_tool` and `grip_tool` after it:

```lua
	"paint_texture",
	"make_tool",
	"grip_tool",
	"capture",
```

Both write the DataModel → they relay by default (not in `Relay.LOCAL_TOOLS`); adding them to `EXPECTED_RELAY` makes the no-drift + "every EXPECTED_RELAY name is registered" cases cover them. Do NOT add them to `EXPECTED_LOCAL`.

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (RelaySpec asserts run in-Studio at Task 6.)

- [ ] **Step 3: Commit**

```bash
git add src/RelaySpec.luau
git commit -m "test(relay): classify make_tool + grip_tool as RELAY (no-drift)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: SystemPrompt note

**Files:** Modify `src/SystemPrompt.luau`.

- [ ] **Step 1: Add tool-index lines**

In `src/SystemPrompt.luau`, after the `paint_texture(...)` tool-index bullet, add:

```
- make_tool(target, name?, handle?): turn a built Part/Model into an equippable Roblox Tool (a HELD item) — see "Building handheld items".
- grip_tool(tool, rig?, offset?, rot?): equip a Tool on a rig + fit its grip, returns a capture to LOOK at — iterate offset/rot until it sits right. See "Building handheld items".
```

- [ ] **Step 2: Add the strategy section**

In `src/SystemPrompt.luau`, immediately AFTER the "# Building with custom meshes" section's last sentence (the `paint_texture` one ending "...should read as brick/wood/tile/stone."), add a new line:

```

# Building handheld items
To make an ITEM a character can HOLD and use (a sword, tool, gun, wand), first build its VISUAL with the mesh/texture tools (generate_mesh / author_mesh / paint_texture / parts), then make_tool(target) to wrap it into a Roblox Tool (it picks a Handle, unanchors + welds the parts). Then grip_tool(tool, rig) to equip it on a rig and FIT the grip: it returns a screenshot of the item in-hand — LOOK at it and re-call grip_tool with adjusted offset {x,y,z} / rot {rx,ry,rz} until the item sits naturally in the fist (e.g. a blade pointing out, gripped near the hilt). Spawn a rig first with spawn_rig if none exists. This is the held-object FOUNDATION; binding use-animations + behavior to the item comes later.
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean (the only risk is a malformed long string).

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): 'Building handheld items' note (make_tool -> grip_tool, fit grip by looking)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bridge dogfood — the acceptance gate

**Files:** none (live verification + HANDOFF + memory).

> Gate to enter: Tasks 1–5 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio** (Studio must also be FOCUSED for captures). The sidecar needs NO restart. Verify by LOOKING at captures, never coordinates. Drive via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; use a here-string for Luau with quotes; the `tool` command's 150s window covers the captures).

- [ ] **Step 1: Run the pure spec + RelaySpec via the bridge**

Run:
```
& scripts/studio-agent.ps1 luau 'return "Tool=" .. tostring(require(script.Parent.ToolFactorySpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run().passed)'
```
Expected: `Tool=true Relay=true` (the Output shows `[ToolFactorySpec] 4/4 passed`; RelaySpec now covers make_tool + grip_tool so no-drift stays green). If `Tool` is false, a gripCFrame case failed — fix and rebuild.

- [ ] **Step 2: Build a simple sword visual + make_tool**

Build a 3-part sword (blade + crossguard + grip) from primitives via the bridge:
```
$code = @'
local function part(name, size, cf, color, mat)
  local p = Instance.new("Part") p.Name = name p.Anchored = true p.Size = size p.CFrame = cf
  p.Color = color p.Material = mat return p
end
local m = Instance.new("Model") m.Name = "Sword"
local grip = part("Grip", Vector3.new(0.3, 1.4, 0.3), CFrame.new(0, 0, 0), Color3.fromRGB(80, 50, 30), Enum.Material.Wood)
local guard = part("Guard", Vector3.new(1.4, 0.25, 0.3), CFrame.new(0, 0.8, 0), Color3.fromRGB(120, 90, 40), Enum.Material.Metal)
local blade = part("Blade", Vector3.new(0.3, 3.2, 0.12), CFrame.new(0, 2.5, 0), Color3.fromRGB(200, 200, 210), Enum.Material.Metal)
m.PrimaryPart = grip
grip.Parent = m guard.Parent = m blade.Parent = m
m.Parent = workspace
return m:GetFullName()
'@
& scripts/studio-agent.ps1 luau $code
& scripts/studio-agent.ps1 tool make_tool '{"target":"Workspace.Sword","name":"Sword","handle":"Workspace.Sword.Grip"}'
```
Expected: `make_tool OK: 'Sword' at Workspace.Sword (Handle + 3 part(s), unanchored + welded)...`. (Confirm via the bridge that `Workspace.Sword` is now a Tool with a `Handle` child + 2 WeldConstraints.)

- [ ] **Step 3: spawn a rig + grip_tool — LOOK and iterate**

```
& scripts/studio-agent.ps1 tool spawn_rig '{"type":"avatar"}'
& scripts/studio-agent.ps1 tool grip_tool '{"tool":"Workspace.Sword","rig":"Workspace.AgentRig"}'
```
READ the returned capture: the rig holds the sword (likely centered/wrong at first — identity grip puts the grip's CENTER in the palm). Iterate, e.g.:
```
& scripts/studio-agent.ps1 tool grip_tool '{"tool":"AgentRig.Sword","rig":"Workspace.AgentRig","offset":{"x":0,"y":-0.7,"z":0},"rot":{"rx":90}}'
```
(Note: after equip the Tool path is under the rig, e.g. `Workspace.AgentRig.Sword`.) READ each capture and adjust `offset`/`rot` until the blade points OUT of the fist, gripped near the hilt. This is the core gate — the capture-iterated grip fit.

- [ ] **Step 4: Structural confirm**

```
$code = @'
local tool = workspace.AgentRig:FindFirstChild("Sword")
if tool == nil then return "Sword not equipped" end
local hasGrip = false
for _, d in workspace.AgentRig:GetDescendants() do if d:IsA("Weld") and d.Name == "RightGrip" then hasGrip = true end end
return "Tool=" .. tool.ClassName .. " Handle=" .. tostring(tool:FindFirstChild("Handle") ~= nil) .. " RightGrip=" .. tostring(hasGrip) .. " Grip=" .. tostring(tool.Grip)
'@
& scripts/studio-agent.ps1 luau $code
```
Expected: `Tool=Tool Handle=true RightGrip=true Grip=...` (the auto-weld exists and Tool.Grip reflects the final params).

- [ ] **Step 5: Clean up + HANDOFF + memory + final commit**

Destroy the probe artifacts (`AgentRig` + the equipped `Sword`, and any leftover `ProbeTool`) — ASK the user before clearing anything else; leave `Rig`/`UAL2_Standard`. Confirm `selene src` 0/0. Update `HANDOFF.md` with a new START-HERE block (handheld item creation SHIPPED + bridge-verified: `make_tool` toolifies a build; `grip_tool` equips + fits the grip by capture; edit-mode equip auto-welds; the interactive-items roadmap #1 done). Update memory (a new fact or extend an existing one: edit-mode Tool equip auto-welds Handle→RightHand; `Tool.Grip` is a live CFrame; the roadmap). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: handheld item creation shipped + bridge-verified (make_tool + grip_tool)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 primitives → Task 2 (toolify/equip) + Task 3 (grip_tool); §2 two-tool decision → Task 3; §2 intuitive grip params → Task 1 (`gripCFrame`) + Task 3; §3 make_tool behavior → Task 3 (`runMakeTool`) + Task 2 (`toolify`); §3 grip_tool behavior → Task 3 (`runGripTool`) + Task 2 (`equip`/`applyGrip`/`resolveRig`); §4 modules → Tasks 1-3 + init (Task 3) + RelaySpec (Task 4) + SystemPrompt (Task 5); §5 edge cases (anchored→unanchor, Handle fallback, live grip, rig resolution, capture degrade) → Task 2 (`toolify`/`resolveRig`) & Task 3 (grip_tool degrade); §6 testing → Task 1 (spec) & Task 6 (dogfood). Out-of-scope items (animations/state-machine/hits/NPCs/auto-grip/deploy) correctly absent.
- **Type/name consistency:** `gripCFrame`/`toolify`/`resolveRig`/`equip`/`applyGrip` (Tasks 1-2) are consumed by `runMakeTool`/`runGripTool` (Task 3) with identical names/signatures; `Vec3ish`/`Rotish` types defined in Task 1 are used by `gripCFrame`. Tool names `make_tool`/`grip_tool` match across Item.luau, init.luau, RelaySpec, SystemPrompt. The `grip_tool` capture mirrors `CameraRig.luau` (`context.cameraRig:focus` + `CaptureCore.triggerCapture/settle/fetchCaptures`) exactly. `WeldConstraint`/`Tool`/`RightGrip` match the verified session patterns.
- **Degrade:** every `runMakeTool`/`runGripTool` path returns `(content, isError)`; a capture failure in `grip_tool` still applies the grip and returns a text note (isError=false) — the grip never fails on a capture problem.
