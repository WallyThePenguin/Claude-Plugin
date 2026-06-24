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
	if
		type(p) == "table"
		and type(p.x) == "number"
		and type(p.y) == "number"
		and type(p.z) == "number"
	then
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
	if
		type(c) == "table"
		and type(c.r) == "number"
		and type(c.g) == "number"
		and type(c.b) == "number"
	then
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
	return "author_mesh OK: '" .. model.Name .. "' (" .. kind .. ") at " .. model:GetFullName(),
		false
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
				prompt = {
					type = "string",
					description = "What to generate, e.g. 'a wooden barrel'.",
				},
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
