--!strict
-- TextureFactory: the procedural-texture engine. PURE pattern generators (checkerPattern, bricksPattern,
-- planksPattern, tilesPattern, noisePattern) + buildPattern return a tileable list of {pos,size,color}
-- draw-ops and are unit-tested in TextureFactorySpec; the impure authorImage/persistImage/applyTexture
-- (EditableImage authoring, CreateAssetAsync(Image) upload, Texture/TextureContent apply) are added in
-- Task 2 and are live-verified. Backs paint_texture. See
-- docs/superpowers/specs/2026-06-23-procedural-textures-design.md.

local TextureFactory = {}

local AssetService = game:GetService("AssetService")

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
	local ops: { DrawOp } =
		{ { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = a } }
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
	local ops: { DrawOp } =
		{ { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = mortar } }
	local rowH = tile / rows
	local brickW = rowH * 2 -- classic ~2:1 brick (wider than tall); running-bond wrap below is width-agnostic
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
	local ops: { DrawOp } =
		{ { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = seam } }
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
	local ops: { DrawOp } =
		{ { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = grout } }
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
	local ops: { DrawOp } =
		{ { pos = Vector2.new(0, 0), size = Vector2.new(tile, tile), color = base } }
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

-- ---- impure (live-verified) ----

-- Author a TILE x TILE EditableImage by drawing each op as an opaque rectangle. THROWS on an
-- EditableImage/draw failure (callers pcall). (CreateEditableImage + DrawRectangle verified at
-- PluginSecurity in edit this session.)
function TextureFactory.authorImage(ops: { DrawOp }): EditableImage
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(TILE, TILE) })
	local over = Enum.ImageCombineType.Overwrite
	for _, op in ops do
		-- Clamp each rect to the drawable [0, TILE] canvas. DrawRectangle ERRORS on a negative position,
		-- on a rect extending past the canvas, and on a zero/negative extent (all verified live). The pure
		-- generators express intent in continuous coords (e.g. a running-bond brick starts at -brickW for
		-- the wrap); the rasterizer clips that to the canvas as the visible partial.
		local x0 = math.max(0, op.pos.X)
		local y0 = math.max(0, op.pos.Y)
		local x1 = math.min(TILE, op.pos.X + op.size.X)
		local y1 = math.min(TILE, op.pos.Y + op.size.Y)
		if x1 > x0 and y1 > y0 then
			img:DrawRectangle(Vector2.new(x0, y0), Vector2.new(x1 - x0, y1 - y0), op.color, 0, over)
		end
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

-- Apply a durable Image asset to `target` (a PART) as a tiling Texture on all six faces — clearing prior
-- Texture children first so a re-paint REPLACES rather than stacks. A Texture tiles by StudsPerTile so it
-- reads as a material. MeshParts are REJECTED upstream (in the tool's resolveTarget): a procedural pattern
-- maps to a mesh's arbitrary UVs and smears (verified live — a tile grid looked awful on a Cube barrel),
-- and a Texture's StudsPerTile tiling only applies to Part faces. Returns a mode descriptor. THROWS on
-- failure (callers pcall).
function TextureFactory.applyTexture(target: BasePart, imageId: number, scale: number): string
	local content = Content.fromUri("rbxassetid://" .. tostring(imageId))
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

return TextureFactory
