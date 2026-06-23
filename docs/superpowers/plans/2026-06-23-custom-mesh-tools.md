# Custom-mesh tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent two curated, reliable, strategy-guided tools — `generate_mesh` (Cube text-to-3D, for man-made objects) and `author_mesh` (procedural pines/rocks via EditableMesh, for the organics Cube botches) — so it builds with custom meshes and picks the right path.

**Architecture:** A `MeshFactory` engine (pure geometry helpers unit-tested in a spec + impure EditableMesh/Cube builders) backs two thin tool descriptors in `Tools/Mesh.luau`, appended to the registry. Both are DataModel-writing → classified RELAY. A SystemPrompt section bakes in the learned strategy (Cube=man-made, procedural=organic) and the `learn`-loop nudge.

**Tech Stack:** Luau (`--!strict`), Roblox AssetService/GenerationService (EditableMesh + Cube, verified callable from the bridge), Rojo, `selene`/`stylua`, the dev bridge.

---

## File Structure

- **Create `src/MeshFactory.luau`** — the engine. PURE `coneGeometry`/`scaleFactorForHeight`/`rockClusterLayout` + impure `buildMeshPart`/`buildPine`/`buildRock`/`generateViaCube`/`groundModel`.
- **Create `src/MeshFactorySpec.luau`** — in-Studio spec for the pure helpers.
- **Create `src/Tools/Mesh.luau`** — the `generate_mesh` + `author_mesh` descriptors.
- **Modify `src/Tools/init.luau`** — require + append `MeshTool.descriptors`.
- **Modify `src/RelaySpec.luau`** — add both tools to `EXPECTED_RELAY`.
- **Modify `src/SystemPrompt.luau`** — the "# Building with custom meshes" section + tool-index line.

**Luau testing note:** there is no local Luau runtime. Pure-helper specs run *in-Studio* (or via the bridge: `luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'`) after the build+restart. The per-task gate is `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0). Python n/a here.

---

### Task 1: MeshFactory pure geometry + spec

**Files:** Create `src/MeshFactory.luau`; Create `src/MeshFactorySpec.luau`.

- [ ] **Step 1: Create `src/MeshFactory.luau` (pure helpers only)**

```lua
--!strict
-- MeshFactory: the custom-mesh engine. PURE geometry helpers (coneGeometry, scaleFactorForHeight,
-- rockClusterLayout) are unit-tested in MeshFactorySpec; the impure builders (EditableMesh assembly,
-- Cube generation, grounding) are added in Task 2 and are live-verified. Backs generate_mesh +
-- author_mesh. See docs/superpowers/specs/2026-06-23-custom-mesh-tools-design.md.

local MeshFactory = {}

export type Geometry = { vertices: { Vector3 }, triangles: { { number } } }

-- A cone: apex at (0,height,0); a base ring of `segments` verts at y=0, radius `radius`; a base center.
-- Vertex order: [1]=apex, [2]=baseCenter, [3..2+segments]=ring. Triangles index into that list: a side
-- fan (apex, ring[i], ring[i+1]) + a base cap (center, ring[i+1], ring[i]), wound so faces point
-- outward/down. PURE (no DataModel) -> unit-testable.
function MeshFactory.coneGeometry(radius: number, height: number, segments: number): Geometry
	local vertices: { Vector3 } = {}
	local triangles: { { number } } = {}
	vertices[1] = Vector3.new(0, height, 0)
	vertices[2] = Vector3.new(0, 0, 0)
	for i = 0, segments - 1 do
		local a = (i / segments) * math.pi * 2
		vertices[3 + i] = Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
	end
	for i = 0, segments - 1 do
		local cur = 3 + i
		local nxt = 3 + ((i + 1) % segments)
		table.insert(triangles, { 1, cur, nxt })
		table.insert(triangles, { 2, nxt, cur })
	end
	return { vertices = vertices, triangles = triangles }
end

-- Scale factor to bring a model of `currentHeight` to `targetHeight`. Guards a zero/negative current.
function MeshFactory.scaleFactorForHeight(currentHeight: number, targetHeight: number): number
	if currentHeight <= 0 then
		return 1
	end
	return targetHeight / currentHeight
end

-- Deterministic pseudo-random in [0,1) from (seed, i). PURE (no math.random global) -> testable.
local function prand(seed: number, i: number): number
	local x = math.sin(seed * 127.1 + i * 311.7) * 43758.5453
	return x - math.floor(x)
end

export type RockPiece = { size: Vector3, offset: Vector3, rot: Vector3, color: Color3 }

-- A 3-block rock cluster sized to `size`, deterministically varied by `seed`. PURE.
function MeshFactory.rockClusterLayout(size: number, seed: number): { RockPiece }
	local pieces: { RockPiece } = {}
	local greys = {
		Color3.fromRGB(98, 100, 106),
		Color3.fromRGB(86, 88, 94),
		Color3.fromRGB(108, 110, 116),
	}
	local bases = {
		{ s = Vector3.new(1.1, 0.75, 0.95), o = Vector3.new(0, 0.36, 0) },
		{ s = Vector3.new(0.68, 0.55, 0.74), o = Vector3.new(0.44, 0.26, 0.2) },
		{ s = Vector3.new(0.54, 0.44, 0.5), o = Vector3.new(-0.38, 0.22, -0.18) },
	}
	for i, b in bases do
		local jitter = (prand(seed, i) - 0.5) * 0.3
		pieces[i] = {
			size = b.s * size * (1 + jitter),
			offset = b.o * size,
			rot = Vector3.new(prand(seed, i * 2) * 30, prand(seed, i * 3) * 360, prand(seed, i * 5) * 25),
			color = greys[i],
		}
	end
	return pieces
end

return MeshFactory
```

- [ ] **Step 2: Create `src/MeshFactorySpec.luau`**

```lua
--!strict
-- MeshFactorySpec: in-Studio self-test for the PURE MeshFactory helpers (no DataModel). Run via
-- `require(script.MeshFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'.

local MeshFactory = require(script.Parent.MeshFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("coneGeometry vertex/triangle counts", function()
		local g = MeshFactory.coneGeometry(2, 5, 8)
		if #g.vertices ~= 10 then
			return false, "verts=" .. #g.vertices
		end
		if #g.triangles ~= 16 then
			return false, "tris=" .. #g.triangles
		end
		return true
	end)

	add("coneGeometry apex + base center positions", function()
		local g = MeshFactory.coneGeometry(2, 5, 8)
		return g.vertices[1] == Vector3.new(0, 5, 0) and g.vertices[2] == Vector3.new(0, 0, 0)
	end)

	add("coneGeometry ring sits at y=0 with radius", function()
		local g = MeshFactory.coneGeometry(3, 4, 6)
		return math.abs(g.vertices[3].Magnitude - 3) < 0.001 and math.abs(g.vertices[3].Y) < 0.001
	end)

	add("scaleFactorForHeight", function()
		return MeshFactory.scaleFactorForHeight(2, 10) == 5
			and MeshFactory.scaleFactorForHeight(0, 10) == 1
	end)

	add("rockClusterLayout: 3 pieces, deterministic by seed, seed varies output", function()
		local a = MeshFactory.rockClusterLayout(3, 7)
		local b = MeshFactory.rockClusterLayout(3, 7)
		local c = MeshFactory.rockClusterLayout(3, 9)
		if #a ~= 3 then
			return false, "count=" .. #a
		end
		if a[1].size ~= b[1].size or a[2].rot ~= b[2].rot then
			return false, "not deterministic"
		end
		if a[1].size == c[1].size then
			return false, "seed had no effect"
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
			print("[MeshFactorySpec] PASS " .. c.name)
		else
			warn("[MeshFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[MeshFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0 errors / 0 warnings; `rojo build` writes the rbxm. (Spec runs in-Studio at Task 6.)

- [ ] **Step 4: Commit**

```bash
git add src/MeshFactory.luau src/MeshFactorySpec.luau
git commit -m "feat: MeshFactory pure geometry (cone/scale/rock-cluster) + spec

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: MeshFactory impure builders

**Files:** Modify `src/MeshFactory.luau`.

- [ ] **Step 1: Add the impure builders**

In `src/MeshFactory.luau`, add a service handle just under `local MeshFactory = {}`:

```lua
local AssetService = game:GetService("AssetService")
```

Then insert these functions just before the final `return MeshFactory`:

```lua
-- ---- impure (live-verified) ----

-- Build a MeshPart from a Geometry via EditableMesh. Anchored + colored. (Content is a Luau global;
-- Content.fromObject wraps the EditableMesh — verified callable at PluginSecurity in edit.)
function MeshFactory.buildMeshPart(geometry: Geometry, color: Color3, material: Enum.Material): BasePart
	local em = AssetService:CreateEditableMesh()
	local ids: { number } = {}
	for i, v in geometry.vertices do
		ids[i] = em:AddVertex(v)
	end
	for _, t in geometry.triangles do
		em:AddTriangle(ids[t[1]], ids[t[2]], ids[t[3]])
	end
	local mp = AssetService:CreateMeshPartAsync(Content.fromObject(em))
	mp.Anchored = true
	mp.Color = color
	mp.Material = material
	return mp
end

export type PineParams = { height: number?, tiers: number?, color: Color3? }

-- A stylized pine: a Cylinder trunk + `tiers` stacked EditableMesh cones. Built at the origin, base y=0.
function MeshFactory.buildPine(params: PineParams): Model
	local height = if type(params.height) == "number" then params.height :: number else 10
	local tiers = if type(params.tiers) == "number" then math.clamp(params.tiers :: number, 1, 5) else 3
	local color = if typeof(params.color) == "Color3"
		then params.color :: Color3
		else Color3.fromRGB(60, 116, 60)
	local model = Instance.new("Model")
	model.Name = "Pine"
	local trunkH = height * 0.28
	local trunk = Instance.new("Part")
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Anchored = true
	trunk.Size = Vector3.new(trunkH, height * 0.12, height * 0.12)
	trunk.CFrame = CFrame.new(0, trunkH / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	trunk.Color = Color3.fromRGB(96, 66, 42)
	trunk.Material = Enum.Material.Wood
	trunk.Parent = model
	local canopyBottom = trunkH * 0.7
	local span = height - canopyBottom
	for i = 0, tiers - 1 do
		local frac = i / tiers
		local geo = MeshFactory.coneGeometry((1 - frac * 0.55) * height * 0.34, span * (0.55 + 0.12 * (1 - frac)), 9)
		local cone = MeshFactory.buildMeshPart(geo, color:Lerp(Color3.fromRGB(122, 170, 96), frac * 0.35), Enum.Material.Grass)
		cone.CFrame = CFrame.new(0, canopyBottom + span * frac, 0)
		cone.Parent = model
	end
	return model
end

export type RockParams = { size: number?, color: Color3?, seed: number? }

-- A clustered-block rock boulder (Rock material), deterministically varied by seed. Base y~0.
function MeshFactory.buildRock(params: RockParams): Model
	local size = if type(params.size) == "number" then params.size :: number else 3
	local seed = if type(params.seed) == "number" then params.seed :: number else 1
	local model = Instance.new("Model")
	model.Name = "Rock"
	for _, piece in MeshFactory.rockClusterLayout(size, seed) do
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = piece.size
		p.CFrame = CFrame.new(piece.offset)
			* CFrame.Angles(math.rad(piece.rot.X), math.rad(piece.rot.Y), math.rad(piece.rot.Z))
		p.Color = if typeof(params.color) == "Color3" then params.color :: Color3 else piece.color
		p.Material = Enum.Material.Rock
		p.Parent = model
	end
	return model
end

-- Generate a Model from a text prompt via Cube. (Model, nil) on success, (nil, err) on failure.
function MeshFactory.generateViaCube(prompt: string): (Model?, string?)
	local GenerationService = game:GetService("GenerationService")
	local ok, result = pcall(function()
		return GenerationService:GenerateModelAsync(
			{ TextPrompt = prompt },
			{ PredefinedSchema = "Body1" }
		)
	end)
	if not ok then
		return nil, "Cube generation failed (rate-limited ~5/min, beta): " .. tostring(result)
	end
	if typeof(result) ~= "Instance" then
		return nil, "Cube returned no model (type " .. typeof(result) .. ")"
	end
	return result :: Model, nil
end

-- Scale `model` to `height` (if given) then ground its AABB base at `position`.
function MeshFactory.groundModel(model: Model, position: Vector3, height: number?)
	if height ~= nil then
		local _, size = model:GetBoundingBox()
		model:ScaleTo(MeshFactory.scaleFactorForHeight(size.Y, height))
	end
	local cf, size = model:GetBoundingBox()
	local base = cf.Position - Vector3.new(0, size.Y / 2, 0)
	model:PivotTo(model:GetPivot() + (position - base))
end
```

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (If selene flags an unused local, fix without suppressing.)

- [ ] **Step 3: Commit**

```bash
git add src/MeshFactory.luau
git commit -m "feat: MeshFactory impure builders (EditableMesh meshpart, pine, rock, Cube gen, ground)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The `generate_mesh` + `author_mesh` tools

**Files:** Create `src/Tools/Mesh.luau`; Modify `src/Tools/init.luau`.

- [ ] **Step 1: Create `src/Tools/Mesh.luau`**

```lua
--!strict
-- Mesh tools: generate_mesh (Cube text-to-3D, MAN-MADE objects) + author_mesh (procedural pine/rock,
-- the organics Cube botches). Thin wrappers over MeshFactory: validate input, build, ground, place,
-- return a summary. Destructive (DataModel writes); RELAY (classified in RelaySpec). Parent-only.

local Selection = game:GetService("Selection")

local MeshFactory = require(script.Parent.Parent.MeshFactory)

local Mesh = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

-- {x,y,z} input, else the current Selection's pivot, else origin.
local function resolvePosition(args: any): Vector3
	local p = if type(args) == "table" then args.position else nil
	if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
		return Vector3.new(p.x, p.y, p.z)
	end
	local sel = Selection:Get()
	if #sel > 0 then
		local ok, cf = pcall(function()
			return (sel[1] :: any):GetPivot()
		end)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
	end
	return Vector3.new(0, 0, 0)
end

local function parseColor(c: any): Color3?
	if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
		return Color3.fromRGB(c.r, c.g, c.b)
	end
	return nil
end

local function runGenerate(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.prompt) ~= "string" or args.prompt == "" then
		return "generate_mesh requires { prompt = <string>, name?, position?, height? }", true
	end
	local model, err = MeshFactory.generateViaCube(args.prompt)
	if model == nil then
		return "generate_mesh: " .. tostring(err), true
	end
	model.Name = if type(args.name) == "string" and args.name ~= "" then args.name else "GenMesh"
	MeshFactory.groundModel(
		model,
		resolvePosition(args),
		if type(args.height) == "number" then args.height else nil
	)
	model.Parent = workspace
	local meshes = 0
	for _, d in model:GetDescendants() do
		if d:IsA("MeshPart") then
			meshes += 1
		end
	end
	local _, size = model:GetBoundingBox()
	return string.format(
		"generate_mesh OK: '%s' (%d MeshPart(s), %.1f x %.1f x %.1f) at %s. Cube is for MAN-MADE objects; use author_mesh for trees/rocks/foliage.",
		model.Name,
		meshes,
		size.X,
		size.Y,
		size.Z,
		model:GetFullName()
	),
		false
end

local KINDS: { [string]: boolean } = { pine = true, rock = true }

local function runAuthor(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local kind = args.kind
	if type(kind) ~= "string" or not KINDS[kind] then
		return "author_mesh requires { kind = 'pine'|'rock', name?, position?, height?/tiers?/size?/seed?/color? }",
			true
	end
	local model: Model
	if kind == "pine" then
		model = MeshFactory.buildPine({
			height = args.height,
			tiers = args.tiers,
			color = parseColor(args.color),
		})
	else
		model = MeshFactory.buildRock({
			size = args.size,
			seed = args.seed,
			color = parseColor(args.color),
		})
	end
	if type(args.name) == "string" and args.name ~= "" then
		model.Name = args.name
	end
	MeshFactory.groundModel(model, resolvePosition(args), nil)
	model.Parent = workspace
	return "author_mesh OK: '" .. model.Name .. "' (" .. kind .. ") at " .. model:GetFullName(), false
end

local POS_SCHEMA = {
	type = "object",
	description = "Ground position {x,y,z}; omit to use the selection or origin.",
	properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } },
}
local COLOR_SCHEMA = {
	type = "object",
	description = "Color {r,g,b} 0-255.",
	properties = { r = { type = "number" }, g = { type = "number" }, b = { type = "number" } },
}

Mesh.descriptors = {
	{
		name = "generate_mesh",
		description = "GENERATE a custom textured 3D mesh from a TEXT prompt via Roblox's Cube model. BEST "
			.. "for MAN-MADE objects (barrels, carts, crates, buildings, furniture, lamps, signs). Its ORGANIC "
			.. "single-meshes (trees, rocks, foliage) come out CREATURE-LIKE — use author_mesh for those. Inputs: "
			.. "prompt (required), name?, position? ({x,y,z}; else selection/origin), height? (target studs — Cube "
			.. "normalizes to ~2). Rate-limited ~5/min (beta); on a rate error, wait and retry.",
		inputSchema = {
			type = "object",
			properties = {
				prompt = { type = "string", description = "What to generate, e.g. 'a wooden barrel'." },
				name = { type = "string", description = "Name for the resulting Model." },
				position = POS_SCHEMA,
				height = { type = "number", description = "Target height in studs." },
			},
			required = { "prompt" },
		},
		destructive = true,
		run = runGenerate,
	},
	{
		name = "author_mesh",
		description = "Build a clean PROCEDURAL ORGANIC mesh — the natural shapes Cube botches. kind='pine' "
			.. "(cylinder trunk + stacked EditableMesh cones) or 'rock' (clustered boulders). Inputs: kind "
			.. "(required), name?, position? ({x,y,z}; else selection/origin); pine params height?/tiers?/color? "
			.. "({r,g,b}); rock params size?/seed?/color?. Compose scenes from generate_mesh (man-made) + "
			.. "author_mesh (organic) + Parts + crafted lighting.",
		inputSchema = {
			type = "object",
			properties = {
				kind = { type = "string", description = "'pine' or 'rock'." },
				name = { type = "string", description = "Name for the resulting Model." },
				position = POS_SCHEMA,
				height = { type = "number", description = "pine: total height in studs." },
				tiers = { type = "number", description = "pine: cone count (1-5)." },
				size = { type = "number", description = "rock: cluster size in studs." },
				seed = { type = "number", description = "rock: variation seed." },
				color = COLOR_SCHEMA,
			},
			required = { "kind" },
		},
		destructive = true,
		run = runAuthor,
	},
} :: { Descriptor }

return Mesh
```

- [ ] **Step 2: Wire into the registry**

In `src/Tools/init.luau`: add the require near the other tool requires (after `local EvaluateTool = require(script.Evaluate)`):

```lua
local MeshTool = require(script.Mesh)
```

And add the append loop after the EvaluateTool loop (after the block ending `for _, descriptor in EvaluateTool.descriptors ...`):

```lua
for _, descriptor in MeshTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

Also add `generate_mesh, author_mesh` to the registry comment list near the top (the line listing `... evaluate, learn, unlearn, import_animation.`) for accuracy.

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Mesh.luau src/Tools/init.luau
git commit -m "feat(tools): generate_mesh (Cube) + author_mesh (procedural pine/rock) + register

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Relay classification (no-drift)

**Files:** Modify `src/RelaySpec.luau`.

- [ ] **Step 1: Add both tools to `EXPECTED_RELAY`**

In `src/RelaySpec.luau`, the `EXPECTED_RELAY` list enumerates every DataModel/HTTP tool. Add `generate_mesh` and `author_mesh` to it (anywhere in the list; alongside the other create/destroy tools is natural). They are NOT added to `EXPECTED_LOCAL` and NOT to `Relay.LOCAL_TOOLS` — DataModel-writing tools relay by default, so `Relay.shouldRelayTool` already returns `true` for them. Adding them to `EXPECTED_RELAY` makes the "no drift" test (every registered tool is classified) pass and asserts they relay.

Example — extend the list:

```lua
	"create_instance",
	"destroy_instance",
	"place_relative",
	"generate_mesh",
	"author_mesh",
	"capture",
```

- [ ] **Step 2: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean. (RelaySpec's own assertions run in-Studio at Task 6 — expect `RelaySpec` green incl. the no-drift + "every EXPECTED_RELAY name is registered" cases now covering the two new tools.)

- [ ] **Step 3: Commit**

```bash
git add src/RelaySpec.luau
git commit -m "test(relay): classify generate_mesh + author_mesh as RELAY (no-drift)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: SystemPrompt strategy section

**Files:** Modify `src/SystemPrompt.luau`.

- [ ] **Step 1: Add a tool-index line**

In `src/SystemPrompt.luau`, near the other tool-index bullets (e.g. just after the `- use_rubric(category): ...` line), add:

```
- generate_mesh(prompt, name?, position?, height?) \ author_mesh(kind, ...): author CUSTOM MESHES — Cube text-to-3D for man-made objects, procedural pine/rock for organics — see "Building with custom meshes".
```

- [ ] **Step 2: Add the strategy section**

Add a new section (place it just after the "# Evaluating against the rubric (close the loop)" paragraph, before "# Priority learnings"):

```
# Building with custom meshes
Beyond Part primitives you can author CUSTOM MESHES. generate_mesh(prompt) generates a textured 3D mesh from text via Roblox's Cube model — use it for MAN-MADE objects (barrels, carts, crates, buildings, furniture, lamps, signs). Its ORGANIC single-meshes (trees, rocks, foliage) come out creature-like — NEVER use Cube for those; use author_mesh(kind) for clean procedural organics (kind='pine' or 'rock'). Compose real scenes from generate_mesh (man-made props) + author_mesh (organics) + Parts (structure/ground) + crafted lighting (Atmosphere, warm/cool key, restrained post). For a shape neither tool covers, build geometry yourself with AssetService:CreateEditableMesh + AssetService:CreateMeshPartAsync(Content.fromObject(em)) via run_luau, and save_skill a good builder so it is reusable. After building in a rubric category, evaluate then learn(category, <the durable mesh lesson>) so your mesh strategy sharpens over time.
```

- [ ] **Step 3: Static gate**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm`
Expected: `selene` 0/0; `rojo build` clean (the only risk is a broken `[[...]]` string — fix if rojo/selene errors).

- [ ] **Step 4: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "feat(prompt): 'Building with custom meshes' strategy (Cube=man-made, procedural=organic) + learn nudge

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Bridge dogfood — the acceptance gate

**Files:** none (live verification + HANDOFF).

> Gate to enter: Tasks 1–5 changed plugin code → run `.\build.ps1`, then **ask the USER to restart Studio**. The sidecar needs NO restart (no sidecar change). Verify by LOOKING at captures, never coordinates.

- [ ] **Step 1: Run the pure spec + RelaySpec via the bridge (no restart beyond the build one)**

Run:
```
& scripts/studio-agent.ps1 luau 'return "MeshFactory=" .. tostring(require(script.Parent.MeshFactorySpec).run()) .. " Relay=" .. tostring(require(script.Parent.RelaySpec).run())'
```
Expected: `MeshFactory=true Relay=true` (the boolean returns mean all cases passed; the in-Studio Output shows `[MeshFactorySpec] 5/5 passed` and the RelaySpec count). If `Relay` is false, the no-drift/registration case caught a miswire — fix and rebuild.

- [ ] **Step 2: `generate_mesh` a man-made prop — LOOK**

`& scripts/studio-agent.ps1 tool generate_mesh '{"prompt":"a wooden barrel","height":3,"name":"ProbeBarrel"}'` (give it a generous timeout — Cube yields; use a 200000ms PowerShell timeout). Then frame the camera on `ProbeBarrel` and capture; READ the PNG — expect a recognizable textured barrel. (If it errors with a rate limit, wait ~15s and retry.)

- [ ] **Step 3: `author_mesh` pine + rock — LOOK**

`& scripts/studio-agent.ps1 tool author_mesh '{"kind":"pine","position":{"x":8,"y":0,"z":0}}'` and `author_mesh '{"kind":"rock","position":{"x":14,"y":0,"z":0},"seed":4}'`. Frame + capture the two; READ the PNG — expect a clean low-poly pine (trunk + stacked cones) and a rock cluster, **no creature look**. This is the core gate (it proves the organics path fixes the Cube-creature problem through the formal tool).

- [ ] **Step 4: The agent uses the tools end-to-end**

`& scripts/studio-agent.ps1 prompt 'Build a tiny outdoor vignette: generate a wooden barrel and a market cart, author two pine trees and a rock, place them on a small plaza, and add warm/cool lighting.'` (200000ms timeout). Confirm from the tool log that the agent called `generate_mesh` + `author_mesh` (not Cube for the trees), then capture the result and READ it — it should compose into a small scene with clean organics. (This verifies the SystemPrompt strategy actually steers the agent.)

- [ ] **Step 5: Clean up + final commit**

Destroy the probe artifacts (`ProbeBarrel`, the pine/rock, any agent-built scene, and the leftover `Vignette`/`GenProps` from the earlier exploration if the user is done with them — ASK first). Leave the user's `Rig`/`UAL2_Standard` alone. Confirm `selene src` 0/0 and `init.server.luau` is clean (no temp require). Update `HANDOFF.md` with a START-HERE block (custom-mesh TOOLS shipped + bridge-verified; the Cube/procedural split; generate_mesh + author_mesh live; v2 = save_mesh persistence + more kinds + EditableImage). Commit:

```bash
git add HANDOFF.md
git commit -m "docs: custom-mesh tools shipped + bridge-verified (generate_mesh + author_mesh)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §3a generate_mesh → Task 3 (`runGenerate`) + Task 2 (`generateViaCube`); §3b author_mesh → Task 3 (`runAuthor`) + Task 2 (`buildPine`/`buildRock`) + Task 1 (`coneGeometry`/`rockClusterLayout`); §4 modules → Tasks 1–3; classification → Task 4; §5 strategy/learn → Task 5; §7 testing → Tasks 1 (spec) & 6 (dogfood). `save_mesh` correctly absent (deferred, §8).
- **Type/name consistency:** `coneGeometry`/`scaleFactorForHeight`/`rockClusterLayout` (pure, Task 1) are consumed by `buildMeshPart`/`buildPine`/`buildRock`/`groundModel` (Task 2) and the tools (Task 3) with identical names/signatures; `Geometry`/`RockPiece`/`PineParams`/`RockParams` types are defined where first used. Tool names `generate_mesh`/`author_mesh` match across Mesh.luau, init.luau, RelaySpec, SystemPrompt. `Content.fromObject(em)` + `GenerateModelAsync({TextPrompt=..},{PredefinedSchema="Body1"})` match the verified session patterns.
- **Cube/procedural split is enforced in THREE places** (tool descriptions, the generate_mesh result string, the SystemPrompt section) — the learned strategy is hard to miss.
