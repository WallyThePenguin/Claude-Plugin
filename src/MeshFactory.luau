--!strict
-- MeshFactory: the custom-mesh engine. PURE helpers (coneGeometry, scaleFactorForHeight,
-- rockClusterLayout, classifyTexture) are unit-tested in MeshFactorySpec; the impure builders
-- (EditableMesh assembly, Cube generation, grounding, persistMeshPart) are live-verified. Backs
-- generate_mesh + author_mesh + save_mesh. See docs/superpowers/specs/2026-06-23-custom-mesh-tools-design.md
-- and docs/superpowers/specs/2026-06-23-cube-texture-persistence-design.md.

local MeshFactory = {}

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")

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

-- Classify a MeshPart's TextureContent for persistence by its SourceType NAME. "persist" = a
-- session-backed texture ("Opaque") to upload; "carry" = an already-durable texture ("Uri") to copy
-- across the swap; "none" = no texture ("None") or any unexpected value -> a safe skip. PURE (a
-- string->string map) -> unit-testable. Verified live: a Cube MeshPart's texture lives in
-- MeshPart.TextureContent with SourceType "Opaque" while session-backed (NOT a SurfaceAppearance, NOT
-- TextureID); a procedural author_mesh part has "None".
function MeshFactory.classifyTexture(sourceTypeName: string): string
	if sourceTypeName == "Opaque" then
		return "persist"
	elseif sourceTypeName == "Uri" then
		return "carry"
	end
	return "none"
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

-- ---- local mesh serialization (PURE encode/decode; extract/rebuild are impure below) ----
--
-- LOCAL STORAGE (no Roblox upload): a mesh's geometry is pure data — a flat vertex-position array
-- `v = {x,y,z, x,y,z, ...}` and a flat 0-based triangle-index array `t = {i,i,i, ...}`. We serialize
-- that into a StringValue in the place and rebuild the EditableMesh on load, so the mesh NEVER goes
-- through CreateAssetAsync (upload -> pending moderation -> CDN load-failure -> Studio instability).
-- Encode/decode are string<->table PURE (unit-tested round-trip in MeshFactorySpec).

export type MeshData = { v: { number }, t: { number } }

-- Encode geometry to a compact "v:<floats>;t:<ints>" string (tostring/tonumber round-trips exactly).
function MeshFactory.encodeMeshData(data: MeshData): string
	local vp: { string } = {}
	for _, n in data.v do
		vp[#vp + 1] = tostring(n)
	end
	local tp: { string } = {}
	for _, n in data.t do
		tp[#tp + 1] = tostring(n)
	end
	return "v:" .. table.concat(vp, ",") .. ";t:" .. table.concat(tp, ",")
end

local function parseNums(s: string): { number }?
	local out: { number } = {}
	if s == "" then
		return out
	end
	for tok in string.gmatch(s, "[^,]+") do
		local n = tonumber(tok)
		if n == nil then
			return nil -- malformed token -> whole decode fails cleanly (nil, never a throw)
		end
		out[#out + 1] = n
	end
	return out
end

-- Inverse of encodeMeshData. Returns nil (never throws) on any malformed input.
function MeshFactory.decodeMeshData(str: string): MeshData?
	if type(str) ~= "string" then
		return nil
	end
	local vs, ts = string.match(str, "^v:(.-);t:(.*)$")
	if vs == nil then
		return nil
	end
	local v = parseNums(vs)
	local t = parseNums(ts :: string)
	if v == nil or t == nil then
		return nil
	end
	return { v = v, t = t }
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

export type ImportResult = {
	part: MeshPart,
	vertices: number,
	faces: number,
	uvs: number,
	normals: number,
	texApplied: boolean,
	source: string,
}

-- Import a reference .glb (assets/reference, parsed sidecar-side by meshio) as a MeshPart via
-- EditableMesh: geometry + per-vertex NORMALS when present (smooth shading — flat-shaded imports
-- read "rocky") + per-vertex UVs when present (NO V-flip — glTF top-down passes 1:1 against a
-- top-down-written EditableImage; proven both ways on the DivineRapier). atlasFile optionally
-- applies a painted atlas (.png/.jpeg, or a .glb's embedded atlas) via the binary /assets/texture
-- route as a session-backed TextureContent (SourceType "Object" — renders live in edit; save_mesh
-- makes it durable). DoubleSided=true is the import DEFAULT: thin generated blades cull
-- see-through from behind otherwise. THROWS on transport/engine failure; callers must pcall —
-- Tools.dispatch does.
function MeshFactory.importReferenceMesh(
	sidecarBase: string,
	file: string,
	atlasFile: string?
): ImportResult
	local resp = HttpService:RequestAsync({
		Url = sidecarBase .. "/assets/mesh?textured=1&file=" .. HttpService:UrlEncode(file),
		Method = "GET",
	})
	if not resp.Success then
		error(
			string.format(
				"mesh route HTTP %d: %s",
				resp.StatusCode,
				string.sub(resp.Body or "", 1, 200)
			)
		)
	end
	local data: any = HttpService:JSONDecode(resp.Body)
	local verts = data.vertices :: { { number } }
	local faces = data.faces :: { { number } }
	local em = AssetService:CreateEditableMesh()
	local vids: { number } = table.create(#verts)
	for i, v in verts do
		vids[i] = em:AddVertex(Vector3.new(v[1], v[2], v[3]))
	end
	local nids: { number }? = nil
	if type(data.normals) == "table" and #data.normals == #verts then
		local ids: { number } = table.create(#verts)
		for i, n in data.normals :: { { number } } do
			ids[i] = em:AddNormal(Vector3.new(n[1], n[2], n[3]))
		end
		nids = ids
	end
	local uvids: { number }? = nil
	if type(data.uvs) == "table" and #data.uvs == #verts then
		local ids: { number } = table.create(#verts)
		for i, u in data.uvs :: { { number } } do
			ids[i] = em:AddUV(Vector2.new(u[1], u[2]))
		end
		uvids = ids
	end
	for _, f in faces do
		local fid = em:AddTriangle(vids[f[1]], vids[f[2]], vids[f[3]])
		if nids ~= nil then
			em:SetFaceNormals(fid, { nids[f[1]], nids[f[2]], nids[f[3]] })
		end
		if uvids ~= nil then
			em:SetFaceUVs(fid, { uvids[f[1]], uvids[f[2]], uvids[f[3]] })
		end
	end
	local mp = AssetService:CreateMeshPartAsync(Content.fromObject(em))
	mp.Anchored = true
	mp.DoubleSided = true
	local texApplied = false
	if atlasFile ~= nil and atlasFile ~= "" then
		local tex = HttpService:RequestAsync({
			Url = sidecarBase .. "/assets/texture?max=1024&file=" .. HttpService:UrlEncode(
				atlasFile
			),
			Method = "GET",
		})
		if not tex.Success then
			error(string.format("texture route HTTP %d", tex.StatusCode))
		end
		local xsize = tex.Headers["x-size"] or tex.Headers["X-Size"]
		local w, h = string.match(tostring(xsize), "^(%d+),(%d+)$")
		if w == nil or h == nil then
			error("texture route: missing/bad X-Size header (" .. tostring(xsize) .. ")")
		end
		local wn, hn = tonumber(w) :: number, tonumber(h) :: number
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(wn, hn) })
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(wn, hn), buffer.fromstring(tex.Body))
		mp.TextureContent = Content.fromObject(img)
		texApplied = true
	end
	return {
		part = mp,
		vertices = #verts,
		faces = #faces,
		uvs = if uvids ~= nil then #uvids else 0,
		normals = if nids ~= nil then #nids else 0,
		texApplied = texApplied,
		source = tostring(data.source),
	}
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
	local model = result :: Model
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	return model, nil
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

export type TextureResult = { imageId: number?, err: string? }
export type PersistResult = {
	meshAssetId: number?,
	swapped: boolean,
	err: string?,
	texture: TextureResult?,
}

-- Persist a session-backed MeshPart (Cube/EditableMesh geometry; MeshId=="") to a durable creator-OWNED
-- Mesh asset and SWAP the in-scene part for one loaded from that asset, so it survives Play/save/ship.
-- ALSO persists the part's generated TEXTURE: a Cube mesh's texture lives in MeshPart.TextureContent
-- (SourceType "Opaque" while session-backed); the swapped durable part starts textureless, so we extract
-- an EditableImage from the ORIGINAL part, upload it via CreateAssetAsync(Image), and set the durable
-- part's WRITABLE TextureContent to the new owned Image asset (verified live). Returns a PersistResult:
-- swapped=true means the in-scene part IS now durable; a non-nil meshAssetId with swapped=false means the
-- mesh uploaded but a fresh-asset load failed (pending moderation) so the part was NOT replaced yet (and
-- the texture is deferred to the next run). `texture` is nil when the part had no texture; otherwise it
-- carries imageId (success) or err (the geometry still persisted; only the texture step failed).
-- MeshContent/MeshId are not writable, so we REPLACE the part; TextureContent IS writable, so the texture
-- needs no swap. Needs the "CreateAssetAsync Lua API" Studio beta flag.
function MeshFactory.persistMeshPart(mp: MeshPart, name: string): PersistResult
	local em: EditableMesh? = nil
	local okEx = pcall(function()
		em = AssetService:CreateEditableMeshAsync(mp.MeshContent)
	end)
	if not okEx or em == nil then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "could not extract geometry from the MeshPart",
			texture = nil,
		}
	end
	-- Classify the texture from the LIVE original part, before any swap/destroy.
	local texClass = MeshFactory.classifyTexture(mp.TextureContent.SourceType.Name)
	-- Verified beta shape: CreateAssetAsync returns (Enum.CreateAssetResult, assetId:number).
	local okSave, result, assetId = pcall(function()
		return AssetService:CreateAssetAsync(em, Enum.AssetType.Mesh, { Name = name })
	end)
	if not okSave then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "CreateAssetAsync failed (is the 'CreateAssetAsync Lua API' beta flag on?): "
				.. tostring(result),
			texture = nil,
		}
	end
	if result ~= Enum.CreateAssetResult.Success or type(assetId) ~= "number" then
		return {
			meshAssetId = nil,
			swapped = false,
			err = "upload not successful (result=" .. tostring(result) .. ")",
			texture = nil,
		}
	end
	local id = assetId :: number
	local durable: MeshPart? = nil
	local okLoad = pcall(function()
		durable = AssetService:CreateMeshPartAsync(Content.fromUri("rbxassetid://" .. tostring(id)))
	end)
	if not okLoad or durable == nil then
		-- Mesh uploaded but not yet loadable (pending moderation): no durable part to texture; defer both.
		return { meshAssetId = id, swapped = false, err = nil, texture = nil }
	end
	local d = durable :: MeshPart
	d.CFrame = mp.CFrame
	d.Size = mp.Size
	d.Color = mp.Color
	d.Material = mp.Material
	d.Transparency = mp.Transparency
	d.Reflectance = mp.Reflectance
	d.CastShadow = mp.CastShadow
	d.CanCollide = mp.CanCollide
	d.Anchored = mp.Anchored
	d.Name = mp.Name
	-- Texture step: reattach the generated texture onto the durable part. Reads the ORIGINAL mp (alive
	-- until the destroy below). Whole step is pcall-wrapped -> a failure degrades to geometry-only.
	local texture: TextureResult? = nil
	if texClass == "persist" then
		local okTex, texErr = pcall(function()
			local imgEm = AssetService:CreateEditableImageAsync(mp.TextureContent)
			local tResult, imageId = AssetService:CreateAssetAsync(
				imgEm,
				Enum.AssetType.Image,
				{ Name = name .. "_tex" }
			)
			if tResult ~= Enum.CreateAssetResult.Success or type(imageId) ~= "number" then
				error("image upload not successful (result=" .. tostring(tResult) .. ")")
			end
			d.TextureContent = Content.fromUri("rbxassetid://" .. tostring(imageId))
			texture = { imageId = imageId :: number }
		end)
		if not okTex then
			texture = { err = "texture persist failed: " .. tostring(texErr) }
		end
	elseif texClass == "carry" then
		-- Already-durable texture: copy the reference across the swap (no upload). The result encodes
		-- four states unambiguously: {imageId=N}=uploaded, {err=...}=failed, {}=carried (durable no-op),
		-- texture=nil=no texture.
		local okCarry = pcall(function()
			d.TextureContent = mp.TextureContent
		end)
		if okCarry then
			texture = {}
		else
			texture = { err = "texture carry failed" }
		end
	end
	for _, ch in mp:GetChildren() do
		ch.Parent = d
	end
	d.Parent = mp.Parent
	mp:Destroy()
	return { meshAssetId = id, swapped = true, err = nil, texture = texture }
end

-- ---- local mesh storage (impure: reads/rebuilds EditableMesh; NO upload) ----

MeshFactory.LOCAL_TAG = "SALocalMesh" -- attribute marking a part whose geometry is stored locally
MeshFactory.DATA_NAME = "MeshData" -- StringValue child holding the encoded geometry
MeshFactory.DATA_CHUNK = 150000 -- chars per StringValue (engine hard-caps Value at 200k); overflow -> numbered child chunks

-- Read a live EditableMesh's geometry into a serializable MeshData (0-based triangle indices).
-- Read APIs live-verified 2026-07-05: GetVertices/GetPosition + GetFaces/GetFaceVertices.
function MeshFactory.extractGeometry(em: EditableMesh): MeshData
	local vids = em:GetVertices()
	local idToIdx: { [number]: number } = {}
	local vflat: { number } = {}
	for i, vid in vids do
		idToIdx[vid] = i - 1 -- 0-based
		local p = em:GetPosition(vid)
		vflat[#vflat + 1] = p.X
		vflat[#vflat + 1] = p.Y
		vflat[#vflat + 1] = p.Z
	end
	local tflat: { number } = {}
	for _, fid in em:GetFaces() do
		local fv = em:GetFaceVertices(fid)
		tflat[#tflat + 1] = idToIdx[fv[1]]
		tflat[#tflat + 1] = idToIdx[fv[2]]
		tflat[#tflat + 1] = idToIdx[fv[3]]
	end
	return { v = vflat, t = tflat }
end

export type LocalPersistResult = { stored: boolean, dataChars: number, err: string? }

-- Persist a session-backed MeshPart's geometry LOCALLY (no CreateAssetAsync). Extracts the geometry,
-- encodes it into a `MeshData` StringValue child, and tags the part `SALocalMesh=true`. The part stays
-- session-backed (renders live now); rebuildLocalMesh restores it after a save/reopen/play blanks it.
function MeshFactory.persistMeshPartLocal(mp: MeshPart): LocalPersistResult
	local okEx, em = pcall(function()
		return AssetService:CreateEditableMeshAsync(mp.MeshContent)
	end)
	if not okEx or em == nil then
		return {
			stored = false,
			dataChars = 0,
			err = "could not extract EditableMesh: " .. tostring(em),
		}
	end
	local okData, encoded = pcall(function()
		return MeshFactory.encodeMeshData(MeshFactory.extractGeometry(em :: EditableMesh))
	end)
	if not okData or type(encoded) ~= "string" then
		return {
			stored = false,
			dataChars = 0,
			err = "extract/encode failed: " .. tostring(encoded),
		}
	end
	local existing = mp:FindFirstChild(MeshFactory.DATA_NAME)
	if existing then
		existing:Destroy()
	end
	-- StringValue.Value hard-caps at 200k chars (live-caught 2026-07-11: a Cube crate encoded to
	-- 423,748 chars and the assignment THREW). Chunk: first DATA_CHUNK chars live in the MeshData
	-- value itself; the rest overflow into numbered child StringValues ("2", "3", ...) that every
	-- reader (rebuildLocalMesh + the play/ship rebuild runtime) concatenates back in order.
	local enc = encoded :: string
	local sv = Instance.new("StringValue")
	sv.Name = MeshFactory.DATA_NAME
	sv.Value = string.sub(enc, 1, MeshFactory.DATA_CHUNK)
	local pos = MeshFactory.DATA_CHUNK + 1
	local chunkN = 2
	while pos <= #enc do
		local chunk = Instance.new("StringValue")
		chunk.Name = tostring(chunkN)
		chunk.Value = string.sub(enc, pos, pos + MeshFactory.DATA_CHUNK - 1)
		chunk.Parent = sv
		pos += MeshFactory.DATA_CHUNK
		chunkN += 1
	end
	sv.Parent = mp
	mp:SetAttribute(MeshFactory.LOCAL_TAG, true)
	return { stored = true, dataChars = #enc, err = nil }
end

-- Reassemble the full encoded string from the MeshData StringValue plus its numbered overflow chunks.
function MeshFactory.readMeshDataValue(dataInst: StringValue): string
	local parts = { dataInst.Value }
	local n = 2
	while true do
		local c = dataInst:FindFirstChild(tostring(n))
		if c == nil or not c:IsA("StringValue") then
			break
		end
		parts[#parts + 1] = c.Value
		n += 1
	end
	return table.concat(parts)
end

-- Rebuild a locally-stored mesh's geometry from its `MeshData` child and apply it back onto the part.
-- Used on load (edit: plugin bootstrap; play/ship: runtime module) after session geometry goes blank.
function MeshFactory.rebuildLocalMesh(mp: MeshPart): (boolean, string?)
	local dataInst = mp:FindFirstChild(MeshFactory.DATA_NAME)
	if dataInst == nil or not dataInst:IsA("StringValue") then
		return false, "no MeshData child"
	end
	local data = MeshFactory.decodeMeshData(MeshFactory.readMeshDataValue(dataInst))
	if data == nil then
		return false, "MeshData did not decode"
	end
	local okBuild, err = pcall(function()
		local em = AssetService:CreateEditableMesh()
		local idx: { [number]: number } = {}
		for i = 1, #data.v, 3 do
			idx[(i - 1) // 3] = em:AddVertex(Vector3.new(data.v[i], data.v[i + 1], data.v[i + 2]))
		end
		for i = 1, #data.t, 3 do
			em:AddTriangle(idx[data.t[i]], idx[data.t[i + 1]], idx[data.t[i + 2]])
		end
		-- Apply the rebuilt geometry ONTO the existing part IN PLACE (no swap — preserves the
		-- instance, so welds / Tool.Handle references survive). MeshContent isn't writable and
		-- MeshPart:ApplyMesh takes a MeshPart, so build a throwaway part from the geometry, apply it,
		-- then destroy it (live-verified 2026-07-05).
		local fresh = AssetService:CreateMeshPartAsync(Content.fromObject(em))
		mp:ApplyMesh(fresh)
		fresh:Destroy()
	end)
	if not okBuild then
		return false, "rebuild failed: " .. tostring(err)
	end
	return true, nil
end

-- ---- asset upload lifecycle (impure; two-phase commit) ----
--
-- REAL uploads, done safely. Phase 1 (uploadMeshPart, at save_mesh time): upload the geometry (+
-- generated texture) via CreateAssetAsync and mark the part PENDING via attributes — the local draft
-- (MeshData child + SALocalMesh tag + live session render) stays untouched, so nothing goes blank.
-- Phase 2 (finalizeMeshPart, from confirm_mesh, ONLY after a TRUTHFUL readiness probe returns
-- AssetFetchStatus.Success): swap the part onto the durable asset IN PLACE and clear the draft.
-- Why two-phase: a fresh asset passes an immediate CreateMeshPartAsync load from the SESSION CACHE
-- (false positive) then fails real CDN fetches while moderation is pending — swapping immediately is
-- what once pushed Studio into degraded mode (docs/superpowers/specs/2026-07-05-local-mesh-storage-design.md).

MeshFactory.ATTR_ASSET_ID = "SAMeshAssetId" -- number: the uploaded Mesh asset id (kept as provenance)
MeshFactory.ATTR_TEXTURE_ID = "SATextureAssetId" -- number?: the uploaded Image asset id
MeshFactory.ATTR_PENDING = "SAMeshAssetPending" -- true while uploaded-but-not-finalized
MeshFactory.ATTR_UPLOADED_AT = "SAMeshUploadedAt" -- os.time() of the upload
MeshFactory.ATTR_PROBE_COUNT = "SAMeshProbeCount" -- readiness probes run so far (drives backoff)
MeshFactory.ATTR_LAST_PROBE = "SAMeshLastProbe" -- os.time() of the last readiness probe
MeshFactory.ATTR_REVIEW_FLAG = "SAMeshReviewFlag" -- true after 6h still-pending (possibly rejected)

export type UploadResult = { assetId: number?, imageId: number?, err: string? }

-- Count the part's LIVE session-mesh faces (0 on any failure/no geometry). Used to detect drafts
-- whose session geometry went blank (reopen without a rebuild) so save_mesh can migrate them.
function MeshFactory.liveFaceCount(mp: MeshPart): number
	local count = 0
	pcall(function()
		local em = AssetService:CreateEditableMeshAsync(mp.MeshContent)
		count = #em:GetFaces()
	end)
	return count
end

-- Phase 1: upload a session-backed MeshPart's geometry (+ generated texture) to owned assets and mark
-- the part PENDING. NO part mutation beyond attributes — the local draft keeps rendering. Fresh-handle
-- rule: re-extract via CreateEditableMeshAsync(mp.MeshContent), NEVER upload a live handle (the
-- recorded handle-consumption bug, factory/tooling-issues.json). Uploads from MeshContent (keeps
-- UVs/normals), not the lossy MeshData string. assetId=nil means the upload FAILED (err says why,
-- including the CreateAssetResult enum); assetId set with a non-nil err means the MESH uploaded but
-- the texture step failed (geometry-only pending). Needs the "CreateAssetAsync Lua API" beta flag.
function MeshFactory.uploadMeshPart(mp: MeshPart, name: string?): UploadResult
	local assetName = "SA_"
		.. (if type(name) == "string" and name ~= "" then name :: string else mp.Name)
	local okEx, em = pcall(function()
		return AssetService:CreateEditableMeshAsync(mp.MeshContent)
	end)
	if not okEx or em == nil then
		return { err = "could not re-extract EditableMesh from MeshContent: " .. tostring(em) }
	end
	local okSave, result, assetId = pcall(function()
		return AssetService:CreateAssetAsync(em, Enum.AssetType.Mesh, { Name = assetName })
	end)
	if not okSave then
		return {
			err = "CreateAssetAsync failed (is the 'CreateAssetAsync Lua API' beta flag on?): "
				.. tostring(result),
		}
	end
	if result ~= Enum.CreateAssetResult.Success or type(assetId) ~= "number" then
		return { err = "mesh upload not successful (result=" .. tostring(result) .. ")" }
	end
	-- Texture: a session-backed generated texture (SourceType "Opaque"/"Object") is uploaded as an
	-- owned Image asset; finalize sets TextureID from it. Probed + uploaded under pcall — a texture
	-- failure degrades to geometry-only (honest note), never loses the mesh upload.
	local imageId: number? = nil
	local texErr: string? = nil
	local srcName = "None"
	pcall(function()
		srcName = mp.TextureContent.SourceType.Name
	end)
	if srcName == "Opaque" or srcName == "Object" then
		local okTex, terr = pcall(function()
			local imgEm = AssetService:CreateEditableImageAsync(mp.TextureContent)
			local tResult, tid = AssetService:CreateAssetAsync(
				imgEm,
				Enum.AssetType.Image,
				{ Name = assetName .. "_tex" }
			)
			if tResult ~= Enum.CreateAssetResult.Success or type(tid) ~= "number" then
				error("image upload not successful (result=" .. tostring(tResult) .. ")")
			end
			imageId = tid :: number
		end)
		if not okTex then
			texErr = "texture upload failed (mesh still uploaded): " .. tostring(terr)
		end
	end
	mp:SetAttribute(MeshFactory.ATTR_ASSET_ID, assetId)
	mp:SetAttribute(MeshFactory.ATTR_TEXTURE_ID, imageId)
	mp:SetAttribute(MeshFactory.ATTR_PENDING, true)
	mp:SetAttribute(MeshFactory.ATTR_UPLOADED_AT, os.time())
	mp:SetAttribute(MeshFactory.ATTR_PROBE_COUNT, 0)
	return { assetId = assetId :: number, imageId = imageId, err = texErr }
end

-- TRUTHFUL readiness probe: ContentProvider:PreloadAsync reads the real CDN (it bypasses the session
-- cache that makes fresh uploads look loadable). Returns the AssetFetchStatus NAME ("Success" /
-- "Failure" / "TimedOut" / "Loading") or "Error: ..." if the call itself threw. Callers own the
-- volume caps (<=5 probes per pass + per-asset backoff — repeated real fetch failures are what
-- degraded Studio before).
function MeshFactory.probeAssetFetchStatus(assetId: number): string
	local ContentProvider = game:GetService("ContentProvider")
	local status = "Unknown"
	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(
			{ "rbxassetid://" .. tostring(assetId) },
			function(_contentId: string, fetchStatus: Enum.AssetFetchStatus)
				status = fetchStatus.Name
			end
		)
	end)
	if not ok then
		return "Error: " .. tostring(err)
	end
	return status
end

-- Phase 2: swap a PENDING part onto its durable uploaded asset IN PLACE. Call ONLY after
-- probeAssetFetchStatus returned "Success". Loads a temp part from the asset, ApplyMesh's it onto the
-- existing part (preserves welds/children/identity — MeshId/MeshContent are not directly writable),
-- sets TextureID from the uploaded image, then clears the local-draft state (MeshData child +
-- SALocalMesh + pending flag). Keeps SAMeshAssetId as provenance. Returns (true) or (false, err) —
-- on error the part stays PENDING (drafts keep rendering; confirm_mesh retries later).
function MeshFactory.finalizeMeshPart(mp: MeshPart): (boolean, string?)
	local assetId = mp:GetAttribute(MeshFactory.ATTR_ASSET_ID)
	if type(assetId) ~= "number" then
		return false, "no " .. MeshFactory.ATTR_ASSET_ID .. " attribute"
	end
	local okLoad, temp = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromAssetId(assetId :: number))
	end)
	if not okLoad or temp == nil then
		return false, "CreateMeshPartAsync failed (left pending): " .. tostring(temp)
	end
	local tempPart = temp :: MeshPart
	local okApply, applyErr = pcall(function()
		mp:ApplyMesh(tempPart)
	end)
	tempPart:Destroy()
	if not okApply then
		return false, "ApplyMesh failed (left pending): " .. tostring(applyErr)
	end
	local imageId = mp:GetAttribute(MeshFactory.ATTR_TEXTURE_ID)
	if type(imageId) == "number" then
		pcall(function()
			mp.TextureID = "rbxassetid://" .. tostring(imageId)
		end)
	end
	local dataInst = mp:FindFirstChild(MeshFactory.DATA_NAME)
	if dataInst ~= nil then
		dataInst:Destroy()
	end
	mp:SetAttribute(MeshFactory.LOCAL_TAG, nil)
	mp:SetAttribute(MeshFactory.ATTR_PENDING, false)
	print(
		"[SAMeshUpload] finalized " .. mp:GetFullName() .. " -> rbxassetid://" .. tostring(assetId)
	)
	return true, nil
end

-- Rebuild every locally-stored mesh under `root` (or the whole DataModel). Returns (rebuilt, failed).
function MeshFactory.rebuildAllLocal(root: Instance?): (number, number)
	local scope = root or game
	local rebuilt, failed = 0, 0
	for _, d in scope:GetDescendants() do
		if d:IsA("MeshPart") and d:GetAttribute(MeshFactory.LOCAL_TAG) == true then
			local ok = MeshFactory.rebuildLocalMesh(d)
			if ok then
				rebuilt += 1
			else
				failed += 1
			end
		end
	end
	return rebuilt, failed
end

return MeshFactory
