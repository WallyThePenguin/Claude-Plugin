--!strict
-- MeshFactory: the custom-mesh engine. PURE geometry helpers (coneGeometry, scaleFactorForHeight,
-- rockClusterLayout) are unit-tested in MeshFactorySpec; the impure builders (EditableMesh assembly,
-- Cube generation, grounding) are added in Task 2 and are live-verified. Backs generate_mesh +
-- author_mesh. See docs/superpowers/specs/2026-06-23-custom-mesh-tools-design.md.

local MeshFactory = {}

local AssetService = game:GetService("AssetService")

export type Geometry = { vertices: { Vector3 }, triangles: { { number } } }

-- ---- pure ----

-- A cone: apex at (0,height,0); a base ring of `segments` verts at y=0, radius `radius`; a base center.
-- Vertex order: [1]=apex, [2]=baseCenter, [3..2+segments]=ring. Triangles index into that list: a side
-- fan (apex, ring[i], ring[i+1]) + a base cap (center, ring[i+1], ring[i]). This is the winding that
-- EditableMesh:AddTriangle renders SOLID / outward-visible (verified live — EditableMesh uses CW vertex
-- order for outward faces, so sides show from outside the cone and the base from below). Requires
-- segments >= 3 (a valid cone base; smaller values yield degenerate triangles). PURE (no DataModel).
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
			rot = Vector3.new(
				prand(seed, i * 2) * 30,
				prand(seed, i * 3) * 360,
				prand(seed, i * 5) * 25
			),
			color = greys[i],
		}
	end
	return pieces
end

-- ---- impure (live-verified) ----

-- Build a MeshPart from a Geometry via EditableMesh. Anchored + colored. (Content is a Luau global;
-- Content.fromObject wraps the EditableMesh — verified callable at PluginSecurity in edit.) THROWS on an
-- EditableMesh/CreateMeshPartAsync failure (quota/engine); callers must pcall — Tools.dispatch does.
function MeshFactory.buildMeshPart(
	geometry: Geometry,
	color: Color3,
	material: Enum.Material
): BasePart
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
	local tiers = if type(params.tiers) == "number"
		then math.clamp(params.tiers :: number, 1, 5)
		else 3
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
		local geo = MeshFactory.coneGeometry(
			(1 - frac * 0.55) * height * 0.34,
			span * (0.55 + 0.12 * (1 - frac)),
			9
		)
		local cone = MeshFactory.buildMeshPart(
			geo,
			color:Lerp(Color3.fromRGB(122, 170, 96), frac * 0.35),
			Enum.Material.Grass
		)
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
	local ok, result = pcall(function()
		local GenerationService = game:GetService("GenerationService")
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
	-- size.Y == 0 (a geometry-less model) degrades to placing the pivot at `position` — acceptable.
	local base = cf.Position - Vector3.new(0, size.Y / 2, 0)
	model:PivotTo(model:GetPivot() + (position - base))
end

return MeshFactory
