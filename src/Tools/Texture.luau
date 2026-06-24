--!strict
-- paint_texture: author a curated procedural surface texture via EditableImage and apply it durably to a
-- PART (a tiling Texture on all faces). Persists at paint time (CreateAssetAsync Image) so it survives
-- Play. PARTS ONLY (MeshParts rejected — a procedural pattern smears on arbitrary mesh UVs; texture meshes
-- via generate_mesh). Destructive (DataModel + AssetService); RELAY. Parent-only.

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

-- Resolve the target Part: an explicit path, else the first paintable Part in the selection. MeshParts
-- are REJECTED — a procedural tiling texture maps to a mesh's arbitrary UVs and smears (verified: a tile
-- grid looked awful on a Cube barrel). paint_texture is for Parts (tiling Textures); meshes get their
-- look from generate_mesh or a persisted Cube texture.
local MESH_MSG = "paint_texture targets a Part, not a mesh — a MeshPart's UVs can't tile a procedural "
	.. "texture (it smears). For a mesh, use generate_mesh (Cube) or persist its Cube texture via save_mesh."

local function resolveTarget(args: any): (BasePart?, string?)
	if type(args.target) == "string" and args.target ~= "" then
		local inst, perr = Path.resolve(args.target)
		if inst == nil then
			return nil,
				"target '" .. tostring(args.target) .. "' did not resolve" .. (if perr ~= nil
					then " — " .. perr
					else "")
		end
		if inst:IsA("MeshPart") then
			return nil, MESH_MSG
		end
		if not inst:IsA("BasePart") then
			return nil, "target must be a Part (got " .. inst.ClassName .. ")"
		end
		return inst :: BasePart, nil
	end
	for _, s in Selection:Get() do
		if s:IsA("BasePart") and not s:IsA("MeshPart") then
			return s :: BasePart, nil
		end
	end
	return nil,
		"no Part target: pass a path to a Part or select one (paint_texture is for Parts, not meshes)"
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
	local ops =
		TextureFactory.buildPattern(kind, parseColor(args.primary), parseColor(args.secondary))
	local okA, imgOrErr = pcall(TextureFactory.authorImage, ops)
	if not okA then
		return "paint_texture: authoring failed — " .. tostring(imgOrErr), true
	end
	local em = imgOrErr :: EditableImage
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
		description = "PAINT a custom procedural SURFACE TEXTURE onto a PART so it looks CRAFTED (beyond flat "
			.. "built-in materials), with no Cube or external assets. kind='bricks'|'planks'|'tiles'|'checker'|"
			.. "'noise'. It authors the texture, uploads it to a durable owned Image asset, and applies it as a "
			.. "TILING Texture on the Part's faces (reads as a real material) so it SURVIVES PLAY immediately. "
			.. "FOR PARTS ONLY — not meshes: a MeshPart's UVs can't tile a procedural texture (it smears), so "
			.. "for a mesh use generate_mesh (Cube) instead. Great for walls, floors, props, trims. Inputs: kind "
			.. "(required), target? (path to a Part; else the selection — must be a Part, not a mesh), scale? "
			.. "(studs-per-tile, default 4), primary?/secondary? ({r,g,b} 0-255; per-kind defaults). Needs the "
			.. "'CreateAssetAsync Lua API' beta flag; ~30 paints/min. Re-painting a Part replaces its texture.",
		inputSchema = {
			type = "object",
			properties = {
				kind = {
					type = "string",
					description = "'bricks'|'planks'|'tiles'|'checker'|'noise'.",
				},
				target = {
					type = "string",
					description = "Path to a Part (not a mesh); omit to use the selection.",
				},
				scale = {
					type = "number",
					description = "Studs per tile (default 4) — controls the texture density on the Part.",
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
