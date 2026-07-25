--!strict
-- author_icon: author a curated procedural GUI ICON (a white pixel-art silhouette) via EditableImage,
-- persist it to a durable owned Image asset (survives Play), and optionally apply it to an ImageLabel/
-- ImageButton with an ImageColor3 tint (so a set reads as one palette-driven, recolorable icon family).
-- Returns the asset id either way. Destructive (DataModel + AssetService); RELAY; parent-only.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local IconFactory = require(script.Parent.Parent.IconFactory)
local TextureFactory = require(script.Parent.Parent.TextureFactory)
local Path = require(script.Parent.Path)

local Icon = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local ICON_CLASSES: { [string]: boolean } = { ImageLabel = true, ImageButton = true }

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

-- Resolve the optional apply target: an explicit path to an ImageLabel/ImageButton, else the first one in
-- the selection. NO target is fine (nil, nil) -> the tool just authors + returns the id. A bad EXPLICIT
-- path is an error (nil, msg).
local function resolveTarget(args: any): (GuiObject?, string?)
	if type(args.target) == "string" and args.target ~= "" then
		local inst, perr = Path.resolve(args.target)
		if inst == nil then
			return nil,
				"target '" .. tostring(args.target) .. "' did not resolve" .. (if perr ~= nil
					then " — " .. perr
					else "")
		end
		if not ICON_CLASSES[inst.ClassName] then
			return nil, "target must be an ImageLabel or ImageButton (got " .. inst.ClassName .. ")"
		end
		return inst :: GuiObject, nil
	end
	for _, s in Selection:Get() do
		if ICON_CLASSES[s.ClassName] then
			return s :: GuiObject, nil
		end
	end
	return nil, nil
end

local function runIcon(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local kind = args.kind
	if not IconFactory.hasKind(kind) then
		return "author_icon requires { kind = one of: " .. table.concat(
			IconFactory.listKinds(),
			"|"
		) .. " , target?, tint?, name? }",
			true
	end
	local target, terr = resolveTarget(args)
	if terr ~= nil then
		return "author_icon: " .. tostring(terr), true
	end
	local tint = parseColor(args.tint) or Color3.new(1, 1, 1)
	-- author + upload (yields) BEFORE any ChangeHistory recording
	local okA, imgOrErr = pcall(IconFactory.authorIcon, kind :: string)
	if not okA then
		return "author_icon: authoring failed — " .. tostring(imgOrErr), true
	end
	local em = imgOrErr :: EditableImage
	local nameArg = if type(args.name) == "string" and args.name ~= ""
		then args.name
		else "icon_" .. kind
	local imageId, perr = TextureFactory.persistImage(em, nameArg)
	if imageId == nil then
		return "author_icon: " .. tostring(perr), true
	end
	local applied =
		"(not applied — apply the returned id to an ImageLabel/ImageButton.Image + set ImageColor3)"
	if target ~= nil then
		local okApply, mode = pcall(function()
			if RunService:IsEdit() then
				local rid = ChangeHistoryService:TryBeginRecording("author_icon")
				local m = IconFactory.applyIcon(target :: GuiObject, imageId :: number, tint)
				if rid ~= nil then
					ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
				end
				return m
			end
			return IconFactory.applyIcon(target :: GuiObject, imageId :: number, tint)
		end)
		if not okApply then
			return "author_icon: apply failed — " .. tostring(mode), true
		end
		applied = tostring(mode) .. " on " .. (target :: GuiObject):GetFullName()
	end
	return string.format(
		"author_icon OK: '%s' -> rbxassetid://%d (white silhouette; recolor a set with ImageColor3 for a "
			.. "unified family). %s. Persisted — survives Play.",
		kind :: string,
		imageId :: number,
		applied
	),
		false
end

Icon.descriptors = {
	{
		name = "author_icon",
		description = "Author a custom GUI ICON (a clean white pixel-art SILHOUETTE) via EditableImage, upload "
			.. "it to a durable owned Image asset (survives Play), and optionally apply it to an ImageLabel/"
			.. "ImageButton tinted by ImageColor3. This is how you escape default-square GUI primitives and "
			.. "build a UNIFIED, palette-recolorable icon family (give each icon the same author_icon style and "
			.. "recolor via the tint). kinds: coin, sword, shield, potion, heart, gear, star, bolt. Inputs: kind "
			.. "(required), target? (path to an ImageLabel/ImageButton; else the selection — omit to just get the "
			.. "id back), tint? ({r,g,b} 0-255; default white), name?. Needs the 'CreateAssetAsync Lua API' beta "
			.. "flag. Use it for currency/item/stat icons, button glyphs, rarity markers.",
		inputSchema = {
			type = "object",
			properties = {
				kind = {
					type = "string",
					description = "coin|sword|shield|potion|heart|gear|star|bolt.",
				},
				target = {
					type = "string",
					description = "Path to an ImageLabel/ImageButton to apply it to; omit to just return the id.",
				},
				tint = {
					type = "object",
					description = "ImageColor3 tint {r,g,b} 0-255 recoloring the white silhouette (default white).",
					properties = {
						r = { type = "number" },
						g = { type = "number" },
						b = { type = "number" },
					},
				},
				name = { type = "string", description = "Asset name (default 'icon_<kind>')." },
			},
			required = { "kind" },
		},
		destructive = true,
		run = runIcon,
	},
} :: { Descriptor }

return Icon
