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

return MeshFactory
