--!strict
-- Mesh tools: generate_mesh (Cube text-to-3D, MAN-MADE objects) + author_mesh (procedural pine/rock,
-- the organics Cube botches). Thin wrappers over MeshFactory: validate input, build, ground, place,
-- return a summary. Destructive (DataModel writes); RELAY (classified in RelaySpec). Parent-only.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local MeshFactory = require(script.Parent.Parent.MeshFactory)
local Path = require(script.Parent.Path)

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
		return Color3.fromRGB(
			math.clamp(math.round(c.r), 0, 255),
			math.clamp(math.round(c.g), 0, 255),
			math.clamp(math.round(c.b), 0, 255)
		)
	end
	return nil
end

-- Ground the (already-built, unparented) model, then parent it under an undoable ChangeHistory
-- recording in edit mode — so an agent-placed mesh is Ctrl-Z-undoable like the other create tools.
-- The yielding build happens BEFORE this, so no yield occurs inside the recording.
local function placeRecorded(model: Model, position: Vector3, height: number?, label: string)
	MeshFactory.groundModel(model, position, height)
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording(label)
		model.Parent = workspace
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		model.Parent = workspace
	end
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
	placeRecorded(
		model,
		resolvePosition(args),
		if type(args.height) == "number" then args.height else nil,
		"generate_mesh"
	)
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
	local ok, result = pcall(function(): Model
		if kind == "pine" then
			return MeshFactory.buildPine({
				height = args.height,
				tiers = args.tiers,
				color = parseColor(args.color),
			})
		end
		return MeshFactory.buildRock({
			size = args.size,
			seed = args.seed,
			color = parseColor(args.color),
		})
	end)
	if not ok then
		return "author_mesh: mesh build failed — " .. tostring(result), true
	end
	local model = result :: Model
	if type(args.name) == "string" and args.name ~= "" then
		model.Name = args.name
	end
	placeRecorded(model, resolvePosition(args), nil, "author_mesh")
	return "author_mesh OK: '" .. model.Name .. "' (" .. kind .. ") at " .. model:GetFullName(),
		false
end

-- Collect MeshParts under a root whose geometry is session-backed (MeshId == "" -> Cube/EditableMesh,
-- not a durable asset yet). De-dups via `seen`.
local function collectSessionMeshParts(
	root: Instance,
	acc: { MeshPart },
	seen: { [Instance]: boolean }
)
	local function consider(inst: Instance)
		if inst:IsA("MeshPart") and (inst :: MeshPart).MeshId == "" and not seen[inst] then
			seen[inst] = true
			table.insert(acc, inst :: MeshPart)
		end
	end
	consider(root)
	for _, dd in root:GetDescendants() do
		consider(dd)
	end
end

-- Self-contained SERVER runtime that reconstructs LOCALLY-stored mesh geometry at Play/ship time.
-- save_mesh serializes a session mesh into a `MeshData` StringValue child + a `SALocalMesh` tag (no
-- upload). The plugin rebuilds those in EDIT (Main.run), but a real Play/ship DataModel has NO plugin,
-- so without this script the geometry stays blank (a Tool Handle renders as a bare floating marker).
-- This mirrors MeshFactory.decode/rebuildLocalMesh inline (it can't require the plugin at runtime) and
-- also heals CLONED handles (Tool copied into a Backpack/Character) via DescendantAdded. ASCII-only.
local REBUILD_RUNTIME_SOURCE = [==[
-- SAMeshRebuildRuntime (auto-generated by save_mesh) -- SERVER-side rebuild of LOCALLY-stored meshes.
-- Reconstructs any MeshPart tagged SALocalMesh from its serialized MeshData child, so custom meshes
-- survive Play/ship without an uploaded asset. Do not hand-edit; save_mesh overwrites this.
local AssetService = game:GetService("AssetService")

local function parseNums(s)
	local out = {}
	if s == "" then
		return out
	end
	for tok in string.gmatch(s, "[^,]+") do
		local n = tonumber(tok)
		if n == nil then
			return nil
		end
		out[#out + 1] = n
	end
	return out
end

local function decode(str)
	if type(str) ~= "string" then
		return nil, nil
	end
	local vs, ts = string.match(str, "^v:(.-);t:(.*)$")
	if vs == nil then
		return nil, nil
	end
	local v = parseNums(vs)
	local t = parseNums(ts)
	if v == nil or t == nil then
		return nil, nil
	end
	return v, t
end

local rebuilt = {}

local function rebuildPart(mp)
	if rebuilt[mp] then
		return
	end
	local dataInst = mp:FindFirstChild("MeshData")
	if dataInst == nil or not dataInst:IsA("StringValue") then
		return
	end
	local v, t = decode(dataInst.Value)
	if v == nil or t == nil then
		return
	end
	local ok = pcall(function()
		local em = AssetService:CreateEditableMesh()
		local idx = {}
		for i = 1, #v, 3 do
			idx[(i - 1) // 3] = em:AddVertex(Vector3.new(v[i], v[i + 1], v[i + 2]))
		end
		for i = 1, #t, 3 do
			em:AddTriangle(idx[t[i]], idx[t[i + 1]], idx[t[i + 2]])
		end
		local fresh = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		mp:ApplyMesh(fresh)
		fresh:Destroy()
	end)
	if ok then
		rebuilt[mp] = true
	end
end

local function consider(inst)
	if inst:IsA("MeshPart") and inst:GetAttribute("SALocalMesh") == true then
		rebuildPart(inst)
	end
end

for _, d in game:GetDescendants() do
	consider(d)
end
game.DescendantAdded:Connect(consider)
]==]

-- Deploy (idempotently) the server rebuild runtime into ServerScriptService so LOCALLY-stored meshes
-- reconstruct in Play/ship. Replaces any prior copy; tagged so game_pull excludes it.
local function ensureRebuildRuntime()
	local sss = game:GetService("ServerScriptService")
	local existing = sss:FindFirstChild("SAMeshRebuildRuntime")
	if existing ~= nil then
		existing:Destroy()
	end
	local s = Instance.new("Script")
	s.Name = "SAMeshRebuildRuntime"
	s.Source = REBUILD_RUNTIME_SOURCE
	s:SetAttribute("StudioAgentGenerated", true) -- identity marker: game_pull excludes on this
	s.Parent = sss
end

local function runSave(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local roots: { Instance } = {}
	if type(args.target) == "string" and args.target ~= "" then
		local inst, perr = Path.resolve(args.target)
		if inst == nil then
			return "save_mesh: target '" .. tostring(args.target) .. "' did not resolve" .. (if perr
					~= nil
				then " — " .. perr
				else ""),
				true
		end
		table.insert(roots, inst)
	else
		for _, s in Selection:Get() do
			table.insert(roots, s)
		end
	end
	if #roots == 0 then
		return "save_mesh requires a target path or a selection (got neither).", true
	end
	local parts: { MeshPart } = {}
	local seen: { [Instance]: boolean } = {}
	for _, r in roots do
		collectSessionMeshParts(r, parts, seen)
	end
	if #parts == 0 then
		return "save_mesh: no session-backed custom meshes found (already durable, or only Parts present).",
			false
	end
	-- LOCAL persistence: serialize each mesh's geometry into the place (NO CreateAssetAsync upload).
	-- Uploading is what caused the pending-moderation CDN load-failures that destabilized Studio; this
	-- stores geometry as a MeshData child + a SALocalMesh tag, and the plugin/runtime rebuilds it on load.
	local stored, failed = 0, 0
	local firstErr: string? = nil
	local function doPersist()
		for _, mp in parts do
			local result = MeshFactory.persistMeshPartLocal(mp)
			if result.stored then
				stored += 1
			else
				failed += 1
				if firstErr == nil then
					firstErr = result.err
				end
			end
		end
		-- Deploy the Play/ship rebuild runtime so the stored geometry reconstructs where the plugin
		-- does NOT run (a real playtest / shipped game). Without it a saved Handle is blank in Play.
		if stored > 0 then
			ensureRebuildRuntime()
		end
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("save_mesh")
		doPersist()
		-- rid == nil (stale recording): proceed UNRECORDED rather than wedge the pipeline.
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doPersist()
	end
	local msg = string.format(
		"save_mesh: %d/%d mesh(es) stored LOCALLY (geometry serialized in-place; NO upload — survives "
			.. "save/reopen AND Play/ship via ServerScriptService.SAMeshRebuildRuntime, no moderation/CDN "
			.. "dependency).",
		stored,
		#parts
	)
	if failed > 0 then
		msg = msg .. string.format(" — %d FAILED (%s)", failed, tostring(firstErr))
	end
	return msg, (stored == 0)
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
			.. "(a stylized low-poly pine tree) or 'rock' (a low-poly boulder cluster). Inputs: kind "
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
	{
		name = "save_mesh",
		description = "PERSIST the custom meshes in a build to durable, creator-OWNED assets so they SURVIVE "
			.. "PLAY / save / ship (in-session generate_mesh/author_mesh geometry is edit-only and goes blank "
			.. "in a playtest until saved). Serializes each session mesh's geometry in-place (a MeshData child "
			.. "+ a SALocalMesh tag, NO upload) and deploys a server SAMeshRebuildRuntime that reconstructs it "
			.. "in Play/ship (incl. cloned Tool Handles). Inputs: target (path to the Model/MeshPart; omit to "
			.. "use the selection). Run it on a FINISHED build, not every iteration.",
		inputSchema = {
			type = "object",
			properties = {
				target = {
					type = "string",
					description = "Path to the Model/MeshPart to persist; omit to use the selection.",
				},
			},
		},
		destructive = true,
		run = runSave,
	},
} :: { Descriptor }

return Mesh
