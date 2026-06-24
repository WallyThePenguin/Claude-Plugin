# Procedural Surface Textures (`paint_texture`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a `paint_texture(kind, target?, scale?, primary?, secondary?)` tool that authors a curated procedural surface texture (bricks/planks/tiles/checker/noise) via EditableImage, uploads it to a durable owned Image asset, and applies it to a Part (tiling Texture on all faces) or MeshPart (TextureContent) — so greybox Parts and custom meshes can look crafted and survive Play.

**Architecture:** A `TextureFactory` engine (PURE tileable pattern generators returning `{pos,size,color}` draw-op lists, unit-tested in a spec; impure author-EditableImage / persist-via-CreateAssetAsync(Image) / apply-Texture) backs a thin `paint_texture` descriptor in a new `Tools/Texture.luau`, appended to the registry. It is DataModel+AssetService-writing → classified RELAY. A SystemPrompt note tells the agent when to paint vs. use built-in materials.

**Tech Stack:** Luau (`--!strict`), Roblox `AssetService` (EditableImage authoring + `CreateAssetAsync(Image)` + writable `Texture`/`MeshPart.TextureContent`, all verified callable from the bridge this session), Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Create `src/TextureFactory.luau`** — the engine. PURE `checkerPattern`/`bricksPattern`/`planksPattern`/`tilesPattern`/`noisePattern` + `buildPattern` (kind dispatch + per-kind color/count defaults); impure `authorImage`/`persistImage`/`applyTexture`.
- **Create `src/TextureFactorySpec.luau`** — in-Studio spec for the pure generators.
- **Create `src/Tools/Texture.luau`** — the `paint_texture` descriptor.
- **Modify `src/Tools/init.luau`** — require + append `TextureTool.descriptors`.
- **Modify `src/RelaySpec.luau`** — add `paint_texture` to `EXPECTED_RELAY`.
- **Modify `src/SystemPrompt.luau`** — a `paint_texture` note in the "# Building with custom meshes" section + a tool-index line.

**Luau testing note:** there is no local Luau runtime. The pure-generator spec runs *in-Studio* (or via the bridge: `luau 'return tostring(require(script.Parent.TextureFactorySpec).run())'`) after a build + USER restart. The per-task static gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). `rojo build` does NOT type-check, so strict-type quibbles won't fail the gate. Python n/a here.

---

### Task 1: TextureFactory pure pattern generators + spec

**Files:** Create `src/TextureFactory.luau`; Create `src/TextureFactorySpec.luau`.

- [ ] **Step 1: Create `src/TextureFactory.luau` (pure section only)**

```lua
--!strict
-- TextureFactory: the procedural-texture engine. PURE pattern generators (checkerPattern, bricksPattern,
-- planksPattern, tilesPattern, noisePattern) + buildPattern return a tileable list of {pos,size,color}
-- draw-ops and are unit-tested in TextureFactorySpec; the impure authorImage/persistImage/applyTexture
-- (EditableImage authoring, CreateAssetAsync(Image) upload, Texture/TextureContent apply) are added in
-- Task 2 and are live-verified. Backs paint_texture. See
-- docs/superpowers/specs/2026-06-23-procedural-textures-design.md.

local TextureFactory = {}

local TILE = 256 -- authored image resolution (px)

export type DrawOp = { pos: Vector2, size: Vector2, color: Color3 }

-- ---- pure ----

-- Deterministic pseudo-random in [0,1) from (seed, i). PURE (no math.random) -> testable.
local function prand(seed: number, i: number): number
	local x = math.sin(seed * 127.1 + i * 311.7) * 43758.5453
	return x - math.floor(x)
end

-- A two-color cols x cols checkerboard: a full bg fill of `a`, then the `b` cells in checker parity. PURE.
function TextureFactory.checkerPattern(tile: number, cols: number, a: Color3, b: Color3): { DrawOp }
	local ops: { DrawOp } = { { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = a } }
	local cell = tile / cols
	for r = 0, cols - 1 do
		for c = 0, cols - 1 do
			if (r + c) % 2 == 1 then
				table.insert(ops, {
					pos = Vector2.new(c * cell, r * cell),
					size = Vector2.new(cell, cell),
					color = b,
				})
			end
		end
	end
	return ops
end

-- A running-bond brick wall: a mortar bg, then inset brick rects; odd rows offset half a brick, drawn
-- from -brickW so the wrap reads continuous (DrawRectangle clips overflow). PURE.
function TextureFactory.bricksPattern(
	tile: number,
	rows: number,
	brick: Color3,
	mortar: Color3
): { DrawOp }
	local ops: { DrawOp } = { { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = mortar } }
	local rowH = tile / rows
	local brickW = tile / rows
	local gap = math.max(2, tile * 0.012)
	for r = 0, rows - 1 do
		local offset = if r % 2 == 1 then brickW / 2 else 0
		local x = -brickW + offset
		while x < tile do
			table.insert(ops, {
				pos = Vector2.new(x + gap / 2, r * rowH + gap / 2),
				size = Vector2.new(brickW - gap, rowH - gap),
				color = brick,
			})
			x += brickW
		end
	end
	return ops
end

-- Vertical planks: a seam bg, then `count` plank rects with seam gaps, each shaded slightly by prand. PURE.
function TextureFactory.planksPattern(
	tile: number,
	count: number,
	plank: Color3,
	seam: Color3
): { DrawOp }
	local ops: { DrawOp } = { { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = seam } }
	local plankW = tile / count
	local gap = math.max(2, tile * 0.01)
	for i = 0, count - 1 do
		local shade = 0.85 + prand(7, i) * 0.3
		local c = Color3.new(
			math.clamp(plank.R * shade, 0, 1),
			math.clamp(plank.G * shade, 0, 1),
			math.clamp(plank.B * shade, 0, 1)
		)
		table.insert(ops, {
			pos = Vector2.new(i * plankW + gap / 2, 0),
			size = Vector2.new(plankW - gap, tile),
			color = c,
		})
	end
	return ops
end

-- A grid of tiles: a grout bg, then cols x cols tile rects inset by a grout gap. PURE.
function TextureFactory.tilesPattern(
	tile: number,
	cols: number,
	tileColor: Color3,
	grout: Color3
): { DrawOp }
	local ops: { DrawOp } = { { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = grout } }
	local cell = tile / cols
	local gap = math.max(2, tile * 0.02)
	for r = 0, cols - 1 do
		for c = 0, cols - 1 do
			table.insert(ops, {
				pos = Vector2.new(c * cell + gap / 2, r * cell + gap / 2),
				size = Vector2.new(cell - gap, cell - gap),
				color = tileColor,
			})
		end
	end
	return ops
end

-- Grunge: a base bg, then `cells` small speckle squares at deterministic prand positions. PURE.
function TextureFactory.noisePattern(
	tile: number,
	cells: number,
	base: Color3,
	speckle: Color3,
	seed: number
): { DrawOp }
	local ops: { DrawOp } = { { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = base } }
	local s = tile * 0.05
	for i = 1, cells do
		local x = prand(seed, i) * tile
		local y = prand(seed, i + 1000) * tile
		table.insert(ops, {
			pos = Vector2.new(x, y),
			size = Vector2.new(s, s),
			color = speckle,
		})
	end
	return ops
end

-- Per-kind defaults (p=primary, s=secondary, n=count/cols/rows/cells). buildPattern resolves a caller's
-- optional colors against these and dispatches to the right generator. PURE.
local DEFAULTS = {
	bricks = { p = Color3.fromRGB(150, 70, 55), s = Color3.fromRGB(200, 195, 185), n = 6 },
	planks = { p = Color3.fromRGB(150, 110, 70), s = Color3.fromRGB(90, 65, 40), n = 5 },
	tiles = { p = Color3.fromRGB(210, 210, 215), s = Color3.fromRGB(120, 120, 125), n = 4 },
	checker = { p = Color3.fromRGB(230, 230, 230), s = Color3.fromRGB(40, 40, 45), n = 4 },
	noise = { p = Color3.fromRGB(130, 130, 130), s = Color3.fromRGB(90, 90, 90), n = 90 },
}

function TextureFactory.buildPattern(kind: string, primary: Color3?, secondary: Color3?): { DrawOp }
	local d = DEFAULTS[kind] or DEFAULTS.noise
	local p = primary or d.p
	local s = secondary or d.s
	if kind == "bricks" then
		return TextureFactory.bricksPattern(TILE, d.n, p, s)
	elseif kind == "planks" then
		return TextureFactory.planksPattern(TILE, d.n, p, s)
	elseif kind == "tiles" then
		return TextureFactory.tilesPattern(TILE, d.n, p, s)
	elseif kind == "checker" then
		return TextureFactory.checkerPattern(TILE, d.n, p, s)
	end
	return TextureFactory.noisePattern(TILE, d.n, p, s, 1)
end

return TextureFactory
```

- [ ] **Step 2: Create `src/TextureFactorySpec.luau`**

```lua
--!strict
-- TextureFactorySpec: in-Studio self-test for the PURE TextureFactory generators (no DataModel). Run via
-- `require(script.TextureFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.TextureFactorySpec).run())'.

local TextureFactory = require(script.Parent.TextureFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

-- Every pattern's first op is a full-tile background fill (the bg-first invariant).
local function bgIsFullTile(ops: { TextureFactory.DrawOp }, tile: number): boolean
	local bg = ops[1]
	return bg ~= nil and bg.pos == Vector2.new(0, 0) and bg.size == Vector2.new(tile, tile)
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	local A = Color3.fromRGB(10, 20, 30)
	local B = Color3.fromRGB(200, 210, 220)

	add("checkerPattern: bg-first + half the cells of a cols x cols grid", function()
		local ops = TextureFactory.checkerPattern(256, 4, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		-- 4x4 = 16 cells, half are the b-color -> 8 cell ops + 1 bg
		if #ops ~= 9 then
			return false, "ops=" .. #ops
		end
		if ops[1].color ~= A or ops[2].color ~= B then
			return false, "colors wrong"
		end
		return true
	end)

	add("tilesPattern: bg-first + cols*cols inset tiles", function()
		local ops = TextureFactory.tilesPattern(256, 4, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		if #ops ~= 1 + 16 then
			return false, "ops=" .. #ops
		end
		-- a tile is inset (smaller than a full cell of 64)
		if ops[2].size.X >= 64 then
			return false, "tile not inset"
		end
		return true
	end)

	add("planksPattern: bg-first + count planks, deterministic", function()
		local ops1 = TextureFactory.planksPattern(256, 5, A, B)
		local ops2 = TextureFactory.planksPattern(256, 5, A, B)
		if not bgIsFullTile(ops1, 256) then
			return false, "no full-tile bg"
		end
		if #ops1 ~= 1 + 5 then
			return false, "ops=" .. #ops1
		end
		-- planks span the full height; deterministic (same input -> same shaded color)
		if ops1[2].size.Y ~= 256 then
			return false, "plank not full height"
		end
		if ops1[2].color ~= ops2[2].color then
			return false, "not deterministic"
		end
		return true
	end)

	add("bricksPattern: bg-first; odd rows offset from even rows", function()
		local ops = TextureFactory.bricksPattern(256, 6, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		if #ops < 1 + 6 then
			return false, "too few bricks: " .. #ops
		end
		-- find the first brick whose row is 0 (y near 0) and first whose row is 1 (y near 256/6)
		local rowH = 256 / 6
		local firstRow0X, firstRow1X
		for i = 2, #ops do
			local op = ops[i]
			if firstRow0X == nil and op.pos.Y < rowH * 0.5 then
				firstRow0X = op.pos.X
			elseif firstRow1X == nil and op.pos.Y >= rowH * 0.5 and op.pos.Y < rowH * 1.5 then
				firstRow1X = op.pos.X
			end
		end
		if firstRow0X == nil or firstRow1X == nil then
			return false, "rows not found"
		end
		-- running bond: the two rows' first-brick x differ by ~half a brick (256/6/2 ~= 21)
		if math.abs((firstRow1X - firstRow0X)) < 5 then
			return false, "rows not offset (running bond missing)"
		end
		return true
	end)

	add("noisePattern: bg-first + cells speckles, deterministic by seed", function()
		local a = TextureFactory.noisePattern(256, 40, A, B, 1)
		local b = TextureFactory.noisePattern(256, 40, A, B, 1)
		if not bgIsFullTile(a, 256) then
			return false, "no full-tile bg"
		end
		if #a ~= 1 + 40 then
			return false, "ops=" .. #a
		end
		if a[2].pos ~= b[2].pos then
			return false, "not deterministic"
		end
		return true
	end)

	add("buildPattern: dispatches by kind + applies defaults; unknown -> noise default", function()
		local bricks = TextureFactory.buildPattern("bricks", nil, nil)
		local checker = TextureFactory.buildPattern("checker", nil, nil)
		if not bgIsFullTile(bricks, 256) or not bgIsFullTile(checker, 256) then
			return false, "bg missing"
		end
		-- checker default cols=4 -> 9 ops; a custom primary overrides the default bg color
		if #checker ~= 9 then
			return false, "checker ops=" .. #checker
		end
		local custom = TextureFactory.buildPattern("checker", Color3.fromRGB(1, 2, 3), nil)
		if custom[1].color ~= Color3.fromRGB(1, 2, 3) then
			return false, "primary override ignored"
		end
		local unknown = TextureFactory.buildPattern("bogus", nil, nil)
		if not bgIsFullTile(unknown, 256) then
			return false, "unknown kind did not fall back"
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
			print("[TextureFactorySpec] PASS " .. c.name)
		else
			warn("[TextureFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[TextureFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0 errors / 0 warnings; `rojo build` writes the rbxm. (The spec runs in-Studio at Task 6.)

- [ ] **Step 4: Commit**

```bash
git add src/TextureFactory.luau src/TextureFactorySpec.luau
git commit -m "feat(texture): TextureFactory pure pattern generators (brick/plank/tile/checker/noise) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: TextureFactory impure author / persist / apply

**Files:** Modify `src/TextureFactory.luau`.

- [ ] **Step 1: Add the service handle**

In `src/TextureFactory.luau`, just under `local TextureFactory = {}`, add:

```lua
local AssetService = game:GetService("AssetService")
```

- [ ] **Step 2: Add the impure functions before `return TextureFactory`**

Insert just before the final `return TextureFactory`:

```lua
-- ---- impure (live-verified) ----

-- Author a TILE x TILE EditableImage by drawing each op as an opaque rectangle. THROWS on an
-- EditableImage/draw failure (callers pcall). (CreateEditableImage + DrawRectangle verified at
-- PluginSecurity in edit this session.)
function TextureFactory.authorImage(ops: { DrawOp }): EditableImage
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(TILE, TILE) })
	local over = Enum.ImageCombineType.Overwrite
	for _, op in ops do
		img:DrawRectangle(op.pos, op.size, op.color, 0, over)
	end
	return img
end

-- Upload the EditableImage to a durable, creator-OWNED Image asset. (id, nil) on success, (nil, err) on
-- failure. Needs the "CreateAssetAsync Lua API" Studio beta flag. Verified shape: (Enum.CreateAssetResult,
-- assetId:number).
function TextureFactory.persistImage(em: EditableImage, name: string): (number?, string?)
	local ok, result, assetId = pcall(function()
		return AssetService:CreateAssetAsync(em, Enum.AssetType.Image, { Name = name })
	end)
	if not ok then
		return nil,
			"CreateAssetAsync(Image) failed (is the 'CreateAssetAsync Lua API' beta flag on?): "
				.. tostring(result)
	end
	if result ~= Enum.CreateAssetResult.Success or type(assetId) ~= "number" then
		return nil, "image upload not successful (result=" .. tostring(result) .. ")"
	end
	return assetId :: number, nil
end

-- Apply a durable Image asset to `target`. A MeshPart gets its writable TextureContent set; any other
-- BasePart gets a tiling Texture on all six faces (clearing prior Texture children first so a re-paint
-- REPLACES rather than stacks). Returns a human-readable mode descriptor. TextureContent is writable
-- (verified this session). THROWS on failure (callers pcall).
function TextureFactory.applyTexture(target: BasePart, imageId: number, scale: number): string
	local content = Content.fromUri("rbxassetid://" .. tostring(imageId))
	if target:IsA("MeshPart") then
		(target :: MeshPart).TextureContent = content
		return "MeshPart.TextureContent"
	end
	for _, ch in target:GetChildren() do
		if ch:IsA("Texture") then
			ch:Destroy()
		end
	end
	for _, face in Enum.NormalId:GetEnumItems() do
		local tex = Instance.new("Texture")
		tex.Face = face
		tex.StudsPerTileU = scale
		tex.StudsPerTileV = scale
		tex.TextureContent = content
		tex.Parent = target
	end
	return "Texture x6 @ StudsPerTile=" .. tostring(scale)
end
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (If selene flags `Content` as undefined, it is a known global in this codebase — `MeshFactory.luau` uses `Content.fromObject`/`Content.fromUri` the same way and passes selene; match that usage.)

- [ ] **Step 4: Commit**

```bash
git add src/TextureFactory.luau
git commit -m "feat(texture): impure authorImage + persistImage(Image asset) + applyTexture (Texture/TextureContent)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The `paint_texture` tool + registry wiring

**Files:** Create `src/Tools/Texture.luau`; Modify `src/Tools/init.luau`.

- [ ] **Step 1: Create `src/Tools/Texture.luau`**

```lua
--!strict
-- paint_texture: author a curated procedural surface texture via EditableImage and apply it durably to a
-- Part (tiling Texture on all faces) or MeshPart (TextureContent). Persists at paint time
-- (CreateAssetAsync Image) so it survives Play. Destructive (DataModel + AssetService); RELAY. Parent-only.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local TextureFactory = require(script.Parent.Parent.TextureFactory)
local Path = require(script.Parent.Path)

local Texture = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local KINDS: { [string]: boolean } =
	{ bricks = true, planks = true, tiles = true, checker = true, noise = true }

local function parseColor(c: any): Color3?
	if
		type(c) == "table"
		and type(c.r) == "number"
		and type(c.g) == "number"
		and type(c.b) == "number"
	then
		return Color3.fromRGB(
			math.clamp(math.round(c.r), 0, 255),
			math.clamp(math.round(c.g), 0, 255),
			math.clamp(math.round(c.b), 0, 255)
		)
	end
	return nil
end

-- Resolve the target BasePart: an explicit path, else the first BasePart in the selection.
local function resolveTarget(args: any): (BasePart?, string?)
	if type(args.target) == "string" and args.target ~= "" then
		local inst, perr = Path.resolve(args.target)
		if inst == nil then
			return nil,
				"target '" .. tostring(args.target) .. "' did not resolve" .. (if perr ~= nil
					then " — " .. perr
					else "")
		end
		if not inst:IsA("BasePart") then
			return nil, "target must be a Part or MeshPart (got " .. inst.ClassName .. ")"
		end
		return inst :: BasePart, nil
	end
	for _, s in Selection:Get() do
		if s:IsA("BasePart") then
			return s :: BasePart, nil
		end
	end
	return nil, "no target: pass a path to a Part/MeshPart or select one"
end

local function runPaint(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local kind = args.kind
	if type(kind) ~= "string" or not KINDS[kind] then
		return "paint_texture requires { kind = 'bricks'|'planks'|'tiles'|'checker'|'noise', target?, scale?, primary?, secondary? }",
			true
	end
	local target, terr = resolveTarget(args)
	if target == nil then
		return "paint_texture: " .. tostring(terr), true
	end
	local scale = if type(args.scale) == "number" and args.scale > 0 then args.scale else 4
	-- author + upload (yields) BEFORE the ChangeHistory recording
	local ops = TextureFactory.buildPattern(kind, parseColor(args.primary), parseColor(args.secondary))
	local okA, em = pcall(TextureFactory.authorImage, ops)
	if not okA then
		return "paint_texture: authoring failed — " .. tostring(em), true
	end
	local imageId, perr = TextureFactory.persistImage(em, kind .. "_tex")
	if imageId == nil then
		return "paint_texture: " .. tostring(perr), true
	end
	-- apply inside an undoable recording (no yield here)
	local okApply, mode = pcall(function()
		if RunService:IsEdit() then
			local rid = ChangeHistoryService:TryBeginRecording("paint_texture")
			local m = TextureFactory.applyTexture(target :: BasePart, imageId :: number, scale)
			if rid ~= nil then
				ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
			end
			return m
		end
		return TextureFactory.applyTexture(target :: BasePart, imageId :: number, scale)
	end)
	if not okApply then
		return "paint_texture: apply failed — " .. tostring(mode), true
	end
	return string.format(
		"paint_texture OK: '%s' on %s (image rbxassetid://%d; %s). Persisted — survives Play.",
		kind,
		(target :: BasePart):GetFullName(),
		imageId :: number,
		tostring(mode)
	),
		false
end

local COLOR_SCHEMA = {
	type = "object",
	description = "Color {r,g,b} 0-255.",
	properties = { r = { type = "number" }, g = { type = "number" }, b = { type = "number" } },
}

Texture.descriptors = {
	{
		name = "paint_texture",
		description = "PAINT a custom procedural SURFACE TEXTURE onto a Part or MeshPart so it looks CRAFTED "
			.. "(beyond flat built-in materials), with no Cube or external assets. kind='bricks'|'planks'|"
			.. "'tiles'|'checker'|'noise'. It authors the texture, uploads it to a durable owned Image asset, "
			.. "and applies it (a Part gets a tiling Texture on all faces; a MeshPart gets its TextureContent) "
			.. "so it SURVIVES PLAY immediately. Inputs: kind (required), target? (path to a Part/MeshPart; "
			.. "else the selection), scale? (studs-per-tile for a Part, default 4; ignored for a MeshPart), "
			.. "primary?/secondary? ({r,g,b} 0-255; per-kind defaults). Needs the 'CreateAssetAsync Lua API' "
			.. "beta flag; ~30 paints/min. Re-painting a Part replaces its texture.",
		inputSchema = {
			type = "object",
			properties = {
				kind = {
					type = "string",
					description = "'bricks'|'planks'|'tiles'|'checker'|'noise'.",
				},
				target = {
					type = "string",
					description = "Path to a Part/MeshPart; omit to use the selection.",
				},
				scale = {
					type = "number",
					description = "Studs per tile for a Part (default 4); ignored for a MeshPart.",
				},
				primary = COLOR_SCHEMA,
				secondary = COLOR_SCHEMA,
			},
			required = { "kind" },
		},
		destructive = true,
		run = runPaint,
	},
} :: { Descriptor }

return Texture
```

- [ ] **Step 2: Wire into the registry (`src/Tools/init.luau`)**

Add the require after `local MeshTool = require(script.Mesh)` (line ~42):

```lua
local TextureTool = require(script.Texture)
```

Add the append loop after the `MeshTool.descriptors` loop (after the block ending at line ~149):

```lua
for _, descriptor in TextureTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Also append `paint_texture` to the registry comment list near the top (the line ending `... generate_mesh, author_mesh, save_mesh.` becomes `... generate_mesh, author_mesh, save_mesh, paint_texture.`).

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Texture.luau src/Tools/init.luau
git commit -m "feat(tools): paint_texture (procedural EditableImage textures) + register

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Relay classification (no-drift)

**Files:** Modify `src/RelaySpec.luau`.

- [ ] **Step 1: Add `paint_texture` to `EXPECTED_RELAY`**

In `src/RelaySpec.luau`, the `EXPECTED_RELAY` list has `generate_mesh`, `author_mesh`, `save_mesh` (around lines 40-42). Add `paint_texture` right after `save_mesh`:

```lua
	"generate_mesh",
	"author_mesh",
	"save_mesh",
	"paint_texture",
	"capture",
```

`paint_texture` writes the DataModel + uses AssetService, so it relays by default (it is NOT in `Relay.LOCAL_TOOLS`); adding it to `EXPECTED_RELAY` makes the "every registered tool is classified" no-drift guard pass and asserts it relays. Do NOT add it to `EXPECTED_LOCAL`.

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (RelaySpec's assertions run in-Studio at Task 6 — expect `RelaySpec` green, the no-drift + "every EXPECTED_RELAY name is registered" cases now covering `paint_texture`.)

- [ ] **Step 3: Commit**

```bash
git add src/RelaySpec.luau
git commit -m "test(relay): classify paint_texture as RELAY (no-drift)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: SystemPrompt note

**Files:** Modify `src/SystemPrompt.luau`.

- [ ] **Step 1: Add a tool-index line**

In `src/SystemPrompt.luau`, near the other tool-index bullets (where `generate_mesh`/`author_mesh` are listed), add:

```
- paint_texture(kind, target?): paint a CUSTOM procedural surface texture (bricks/planks/tiles/checker/noise) onto a Part/MeshPart — crafted surfaces beyond flat built-in materials; persists immediately (survives Play). See "Building with custom meshes".
```

- [ ] **Step 2: Extend the "# Building with custom meshes" section**

In `src/SystemPrompt.luau`, the "# Building with custom meshes" section ends with the sentence about `save_mesh` ("...Run save_mesh once on the finished build, not on every iteration."). Immediately AFTER that sentence (same paragraph/line, append), add:

```
 To make a surface look CRAFTED instead of flat-colored, paint_texture(kind, target) applies a custom procedural texture (kind='bricks'|'planks'|'tiles'|'checker'|'noise') — a Part gets a tiling material on all faces (scale = studs-per-tile), a MeshPart gets its TextureContent. Use it on walls/floors/props to beat the generic flat-material look; it uploads + applies a durable owned Image asset immediately, so it survives Play (no save_mesh needed for textures). Prefer it over a bare BrickColor when a surface should read as brick/wood/tile/stone.
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean (the only risk is a malformed long string — fix if rojo/selene errors).

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): paint_texture strategy note (crafted surfaces; persists, survives Play)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bridge dogfood — the acceptance gate

**Files:** none (live verification + HANDOFF + memory).

> Gate to enter: Tasks 1–5 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio** (Studio must also be FOCUSED for captures). The sidecar needs NO restart. The **"CreateAssetAsync Lua API" beta flag must be ON**. Verify by LOOKING at captures, never coordinates. Drive via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; use a PowerShell here-string `$code = @'…'@` for Luau with quotes; the `tool` command has a 150s window vs `luau`'s 30s — paint_texture uploads, so use `tool`).

- [ ] **Step 1: Run the pure spec + RelaySpec via the bridge**

Run:
```
& scripts/studio-agent.ps1 luau 'return "Texture=" .. tostring(require(script.Parent.TextureFactorySpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run().passed)'
```
Expected: `Texture=true Relay=true` (the Studio Output shows `[TextureFactorySpec] 6/6 passed` and the RelaySpec count; `paint_texture` is now classified so no-drift stays green). If `Texture` is false, a pure generator case failed — fix and rebuild.

- [ ] **Step 2: Paint each kind on a Part — LOOK**

Build a wall to paint, then paint bricks:
```
& scripts/studio-agent.ps1 luau 'local p=Instance.new("Part") p.Name="TexWall" p.Anchored=true p.Size=Vector3.new(12,8,1) p.CFrame=CFrame.new(0,5,-14) p.Parent=workspace return p:GetFullName()'
& scripts/studio-agent.ps1 tool paint_texture '{"kind":"bricks","target":"Workspace.TexWall"}'
```
Then frame + capture and READ:
```
& scripts/studio-agent.ps1 tool camera_focus '{"target":"Workspace.TexWall"}'
& scripts/studio-agent.ps1 capture "$env:TEMP/tex-bricks.png"
```
Read `tex-bricks.png` — expect a recognizable brick surface (offset rows, mortar lines). Repeat the `paint_texture` + capture for `planks`, `tiles`, `checker`, `noise` (e.g. `tex-planks.png`, …), reading each: planks = vertical wood boards with seams; tiles = a grid with grout; checker = two-color squares; noise = a grunged/speckled surface. (Images may take a few seconds to moderate; if a face is blank/grey, wait ~15-30s and re-capture — the durable ref renders once moderated.)

- [ ] **Step 3: Paint a MeshPart (TextureContent path) — LOOK**

Persist a fresh barrel or reuse a durable MeshPart, then paint it:
```
& scripts/studio-agent.ps1 tool paint_texture '{"kind":"tiles","target":"Workspace.TexProbeBarrel"}'
& scripts/studio-agent.ps1 tool camera_focus '{"target":"Workspace.TexProbeBarrel"}'
& scripts/studio-agent.ps1 capture "$env:TEMP/tex-meshpart.png"
```
Read `tex-meshpart.png` — the mesh shows the tile texture (the `MeshPart.TextureContent` apply path). (If no `TexProbeBarrel` exists, `generate_mesh` one first, or target any MeshPart in the scene.)

- [ ] **Step 4: Confirm durability + replace-on-repaint**

```
$code = @'
local w = workspace:FindFirstChild("TexWall")
local out = {}
local n = 0
for _, c in w:GetChildren() do if c:IsA("Texture") then n += 1 table.insert(out, c.Face.Name .. "=" .. tostring(c.TextureContent.SourceType) .. ":" .. tostring(c.TextureContent.Uri)) end end
return "textures=" .. n .. " | " .. table.concat(out, " ")
'@
& scripts/studio-agent.ps1 luau $code
```
Expected: `textures=6` (one per face), each `SourceType=Uri` with a `rbxassetid://…` (durable → survives Play). Then re-paint the same wall (`paint_texture {kind:"checker", target:"Workspace.TexWall"}`) and re-run the probe — still `textures=6` (REPLACED, not 12 — proves the clear-then-apply).

- [ ] **Step 5: Clean up + HANDOFF + memory + final commit**

Leave the user's `Rig`/`UAL2_Standard` alone; ASK before clearing test artifacts (the user previously chose "leave everything"). Confirm `selene src` 0/0. Update `HANDOFF.md` with a new START-HERE block (procedural textures SHIPPED + bridge-verified: `paint_texture`, 5 tileable kinds, EditableImage author → CreateAssetAsync(Image) → tiling Texture / TextureContent, persists at paint time so it survives Play). Update memory `roblox-bridge-mesh-creation` with the EditableImage-authoring verification (CreateEditableImage + Draw* + WritePixelsBuffer/ReadPixelsBuffer; Texture/Decal/MeshPart.TextureContent writable). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: procedural textures shipped + bridge-verified (paint_texture)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 primitives → Task 2 (impure author/persist/apply); §2 persist-at-paint-time → Task 3 (`runPaint` persists then applies the durable id); §2 kinds + two-color params → Task 1 (`buildPattern` + DEFAULTS) & Task 3 (`parseColor`); §3 tool behavior/flow/failure → Task 3; §4 modules → Tasks 1-3 (engine + spec + tool) + Task 3 init + Task 4 RelaySpec + Task 5 SystemPrompt; §5 edge cases (re-paint replace, MeshPart vs Part, scale-ignored-for-mesh, moderation) → Task 2 (`applyTexture` clears Textures) & Task 3 & Task 6 Step 4; §6 testing → Task 1 (spec) & Task 6 (dogfood). Out-of-scope items (text, per-face, PBR maps, decal-stretch) correctly absent.
- **Type/name consistency:** the pure generators (`checkerPattern`/`bricksPattern`/`planksPattern`/`tilesPattern`/`noisePattern`, Task 1) + `buildPattern` are consumed by `authorImage` (Task 2) and `runPaint` (Task 3) with identical names/signatures; `DrawOp` is defined in Task 1 and used in the spec + Task 2; `authorImage`/`persistImage`/`applyTexture` (Task 2) are called in `runPaint` (Task 3) field-for-field; the tool name `paint_texture` matches across Texture.luau, init.luau, RelaySpec, SystemPrompt. `Content.fromUri`, `CreateEditableImage({Size})`, `DrawRectangle(pos,size,color,0,Overwrite)`, `CreateAssetAsync(em, Enum.AssetType.Image)`, and the writable `Texture`/`MeshPart.TextureContent` all match the verified session patterns.
- **Degrade:** every `runPaint` path is pcall-wrapped → `(string, isError)`; an author/upload/apply failure returns a clear error and never throws.
