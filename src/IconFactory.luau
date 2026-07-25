--!strict
-- IconFactory: procedural GUI ICON authoring. PURE glyph generators turn a compact pixel-art bitmap into
-- a list of WHITE rectangle draw-ops on a TRANSPARENT canvas (no background fill) -> a white silhouette,
-- ideal for ImageColor3 recoloring into a unified icon family. Reuses TextureFactory.authorImage (rect
-- rasterizer on a fresh transparent EditableImage) + persistImage (CreateAssetAsync(Image)). Backs the
-- author_icon tool. Rect-only by design: it avoids any unverified DrawCircle/DrawLine assumption and reads
-- as clean pixel art. glyphToOps/buildGlyph/listKinds are PURE (unit-tested in IconFactorySpec); authorIcon
-- (= TextureFactory.authorImage) and applyIcon are impure + live-verified.

local IconFactory = {}

local TextureFactory = require(script.Parent.TextureFactory)

type DrawOp = TextureFactory.DrawOp

local TILE = 256 -- matches TextureFactory's canvas; each bitmap cell = TILE/cols px

-- Compact pixel-art glyphs (each a list of equal-length rows; '#' = filled, anything else = transparent).
-- 12x12, designed to read at small sizes as a coherent, single-weight family.
local GLYPHS: { [string]: { string } } = {
	coin = {
		"....####....",
		"..##....##..",
		".#..####..#.",
		"#..##..##..#",
		"#.##....##.#",
		"#.##....##.#",
		"#.##....##.#",
		"#.##....##.#",
		"#..##..##..#",
		".#..####..#.",
		"..##....##..",
		"....####....",
	},
	sword = {
		".....##.....",
		"....####....",
		"....####....",
		"....####....",
		"....####....",
		"....####....",
		"....####....",
		"..########..",
		"....####....",
		"....####....",
		"...##..##...",
		"..###..###..",
	},
	potion = {
		"....####....",
		"....#..#....",
		"....#..#....",
		"...######...",
		"..##....##..",
		".##......##.",
		"##........##",
		"##..####..##",
		"##.######.##",
		".##.####.##.",
		"..##....##..",
		"...######...",
	},
	shield = {
		"############",
		"##........##",
		"##........##",
		"##..####..##",
		"##.######.##",
		"##.######.##",
		"##.######.##",
		".##.####.##.",
		".##.####.##.",
		"..##..##....",
		"...####.....",
		"....##......",
	},
	heart = {
		".###....###.",
		"#####..#####",
		"############",
		"############",
		"############",
		"############",
		".##########.",
		".##########.",
		"..########..",
		"...######...",
		"....####....",
		".....##.....",
	},
	gear = {
		"...#....#...",
		"#..#....#..#",
		"############",
		".##.####.##.",
		".##.####.##.",
		"##...##...##",
		"##...##...##",
		".##.####.##.",
		".##.####.##.",
		"############",
		"#..#....#..#",
		"...#....#...",
	},
	star = {
		".....##.....",
		"....####....",
		"....####....",
		"############",
		".##########.",
		"..########..",
		"...####.....",
		"...######...",
		"..##..##....",
		".##....##...",
		"##......##..",
		"#........#..",
	},
	bolt = {
		".......###..",
		"......###...",
		".....###....",
		"....######..",
		"...#######..",
		"......###...",
		".....###....",
		"..######....",
		"..#####.....",
		"....###.....",
		"...###......",
		"..###.......",
	},
}

-- PURE: turn a glyph bitmap into white rectangle draw-ops on a transparent canvas (one rect per filled
-- cell; no background fill, so undrawn pixels stay transparent). Cell size = TILE/cols. Unknown kind -> {}.
function IconFactory.glyphToOps(kind: string): { DrawOp }
	local rows = GLYPHS[kind]
	if rows == nil then
		return {}
	end
	local nRows = #rows
	local nCols = #rows[1]
	if nRows == 0 or nCols == 0 then
		return {}
	end
	local cw = TILE / nCols
	local ch = TILE / nRows
	local white = Color3.new(1, 1, 1)
	local ops: { DrawOp } = {}
	for r = 1, nRows do
		local line = rows[r]
		for c = 1, nCols do
			if string.sub(line, c, c) == "#" then
				table.insert(ops, {
					pos = Vector2.new((c - 1) * cw, (r - 1) * ch),
					size = Vector2.new(cw, ch),
					color = white,
				})
			end
		end
	end
	return ops
end

-- PURE: the available icon kinds (sorted, for the tool's catalog + error messages).
function IconFactory.listKinds(): { string }
	local out: { string } = {}
	for k in GLYPHS do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- PURE: does a kind exist?
function IconFactory.hasKind(kind: any): boolean
	return type(kind) == "string" and GLYPHS[kind] ~= nil
end

-- PURE self-check: every glyph must be RECTANGULAR (all rows the same length) since glyphToOps keys the
-- column count off row 1 - a ragged row would be silently clipped. Returns "" if all OK, else the first
-- offending "kind row N: got L, want W".
function IconFactory.validateGlyphs(): string
	for kind, rows in GLYPHS do
		local w = #rows[1]
		for i, line in ipairs(rows) do
			if #line ~= w then
				return kind
					.. " row "
					.. tostring(i)
					.. ": got "
					.. tostring(#line)
					.. ", want "
					.. tostring(w)
			end
		end
	end
	return ""
end

-- ---- impure (live-verified) ----

-- Author a transparent white-silhouette EditableImage for `kind` (reuses TextureFactory's rect
-- rasterizer on a fresh, initially-transparent EditableImage). THROWS on failure (callers pcall).
function IconFactory.authorIcon(kind: string): EditableImage
	return TextureFactory.authorImage(IconFactory.glyphToOps(kind))
end

-- Apply a durable Image asset to an ImageLabel/ImageButton as a TINTED icon (ImageColor3 = tint recolors
-- the white silhouette, so a set of icons reads as one palette-driven family). Returns a mode string.
-- THROWS on failure (callers pcall).
function IconFactory.applyIcon(target: GuiObject, imageId: number, tint: Color3): string
	local label = target :: any
	label.Image = "rbxassetid://" .. tostring(imageId)
	label.ImageColor3 = tint
	label.BackgroundTransparency = 1
	label.ScaleType = Enum.ScaleType.Fit
	return "ImageColor3-tinted icon rbxassetid://" .. tostring(imageId)
end

return IconFactory
