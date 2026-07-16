--!strict
-- Mesh tools: generate_mesh (Cube text-to-3D, MAN-MADE objects) + author_mesh (procedural pine/rock,
-- the organics Cube botches). Thin wrappers over MeshFactory: validate input, build, ground, place,
-- return a summary. Destructive (DataModel writes); RELAY (classified in RelaySpec). Parent-only.

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

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

-- Self-contained runtime that reconstructs LOCALLY-stored DRAFT mesh geometry at Play/ship time.
-- save_mesh serializes a session mesh into a `MeshData` StringValue child + a `SALocalMesh` tag AND
-- uploads it as a real owned asset (confirm_mesh finalizes once moderation clears). Until a part is
-- FINALIZED it is still draft-rendered, and a real Play/ship DataModel has NO plugin, so this server
-- Script (ServerScriptService.SAMeshRebuildRuntime) rebuilds drafts there. Finalized parts need NO
-- runtime — a real asset-backed MeshPart replicates natively (the old per-client
-- SAMeshRebuildClient LocalScript is RETIRED; ensureRebuildRuntime destroys stray copies). Mirrors
-- MeshFactory.decode/rebuildLocalMesh inline (it can't require the plugin at runtime) and heals
-- CLONED handles (Tool copied into a Backpack/Character) via DescendantAdded. ASCII-only. `CONTEXT`
-- is prepended per deployment by rebuildRuntimeSource.
local REBUILD_BODY = [==[
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

-- Returns (ok, err). Never throws; every failure carries an honest reason for the warn() below.
local function rebuildPart(mp)
	if rebuilt[mp] then
		return true, nil
	end
	local dataInst = mp:FindFirstChild("MeshData")
	if dataInst == nil or not dataInst:IsA("StringValue") then
		return false, "no MeshData StringValue child"
	end
	-- Large meshes overflow the 200k StringValue cap into numbered child chunks ("2","3",...).
	local chunks = { dataInst.Value }
	local ci = 2
	while true do
		local c = dataInst:FindFirstChild(tostring(ci))
		if c == nil or not c:IsA("StringValue") then
			break
		end
		chunks[#chunks + 1] = c.Value
		ci = ci + 1
	end
	local v, t = decode(table.concat(chunks))
	if v == nil or t == nil then
		return false, "MeshData did not decode"
	end
	local ok, err = pcall(function()
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
	if not ok then
		return false, tostring(err)
	end
	rebuilt[mp] = true
	return true, nil
end

local function isCandidate(inst)
	return inst:IsA("MeshPart") and inst:GetAttribute("SALocalMesh") == true
end

-- Initial full scan: one honest summary line + a loud warn per failure.
local okCount, failCount, candidates = 0, 0, 0
for _, d in game:GetDescendants() do
	if isCandidate(d) then
		candidates = candidates + 1
		local ok, err = rebuildPart(d)
		if ok then
			okCount = okCount + 1
		else
			failCount = failCount + 1
			warn("[SAMeshRebuild] " .. CONTEXT .. ": FAILED " .. d:GetFullName() .. " -- " .. tostring(err))
		end
	end
end
print(
	string.format("[SAMeshRebuild] %s: rebuilt %d, failed %d of %d candidates", CONTEXT, okCount, failCount, candidates)
)

-- Heal late arrivals (clones into Backpack/Character; client-side: parts that replicate after boot).
game.DescendantAdded:Connect(function(inst)
	if isCandidate(inst) then
		local ok, err = rebuildPart(inst)
		if not ok then
			warn("[SAMeshRebuild] " .. CONTEXT .. ": FAILED " .. inst:GetFullName() .. " -- " .. tostring(err))
		end
	end
end)
]==]

-- Wrap the body for a deployment context (only "server" is deployed now; the client copy is retired).
local function rebuildRuntimeSource(context: string): string
	return "-- SAMeshRebuild ("
		.. context
		.. ") -- auto-generated by save_mesh; do not hand-edit (save_mesh overwrites this).\n"
		.. "-- Rebuilds any MeshPart tagged SALocalMesh from its serialized MeshData child.\n"
		.. 'local CONTEXT = "'
		.. context
		.. '"\n'
		.. REBUILD_BODY
end

-- Deploy (idempotently) the SERVER rebuild runtime so LOCALLY-stored DRAFTS reconstruct in Play/ship
-- while their uploads await finalize. Replaces any prior copy; tagged StudioAgentGenerated so
-- game_pull excludes it. ALSO a heal point: destroys the RETIRED per-client SAMeshRebuildClient
-- LocalScript if a prior save deployed one (finalized asset-backed meshes replicate natively, so the
-- client rebuilder is no longer needed). Returns the deployed script full-names for the tool note.
local function ensureRebuildRuntime(): { string }
	local deployed: { string } = {}

	local sss = game:GetService("ServerScriptService")
	local existing = sss:FindFirstChild("SAMeshRebuildRuntime")
	if existing ~= nil then
		existing:Destroy()
	end
	local s = Instance.new("Script")
	s.Name = "SAMeshRebuildRuntime"
	s.Source = rebuildRuntimeSource("server")
	s:SetAttribute("StudioAgentGenerated", true) -- identity marker: game_pull excludes on this
	s.Parent = sss
	table.insert(deployed, s:GetFullName())

	-- Heal: remove the retired client rebuilder wherever an older save left it.
	local starterScripts = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
	if starterScripts ~= nil then
		local priorClient = starterScripts:FindFirstChild("SAMeshRebuildClient")
		if priorClient ~= nil then
			priorClient:Destroy()
		end
	end

	return deployed
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
	-- TWO-PHASE persistence. Phase A (recorded, undoable): keep/refresh the LOCAL draft (MeshData
	-- child + SALocalMesh tag — the part keeps rendering NOW regardless of moderation) and deploy the
	-- server rebuild runtime. A draft whose live session geometry went blank (place reopened without a
	-- rebuild) is MIGRATED — geometry rebuilt from MeshData — before upload. Phase B (AFTER the
	-- recording: CreateAssetAsync is a long web yield we will not hold a ChangeHistory recording
	-- across): REAL upload per part via MeshFactory.uploadMeshPart, which marks it pending-moderation
	-- via attributes only. confirm_mesh finalizes once the CDN truthfully serves the asset.
	local stored, failed, skipped = 0, 0, 0
	local failLines: { string } = {}
	local skipLines: { string } = {}
	local uploadable: { MeshPart } = {}
	local deployedScripts: { string } = {}
	local function doPersist()
		for _, mp in parts do
			-- Already uploaded (pending or awaiting finalize): NEVER re-upload (duplicate assets).
			local priorId = mp:GetAttribute(MeshFactory.ATTR_ASSET_ID)
			if type(priorId) == "number" then
				skipped += 1
				table.insert(
					skipLines,
					mp:GetFullName()
						.. " — already uploaded (rbxassetid://"
						.. tostring(priorId)
						.. "; confirm_mesh finalizes it)"
				)
				continue
			end
			if
				mp:GetAttribute(MeshFactory.LOCAL_TAG) == true
				and mp:FindFirstChild(MeshFactory.DATA_NAME) ~= nil
				and MeshFactory.liveFaceCount(mp) == 0
			then
				local okR, rerr = MeshFactory.rebuildLocalMesh(mp)
				if not okR then
					failed += 1
					table.insert(
						failLines,
						mp:GetFullName() .. " — migration rebuild failed: " .. tostring(rerr)
					)
					continue
				end
			end
			local result = MeshFactory.persistMeshPartLocal(mp)
			if result.stored then
				stored += 1
				table.insert(uploadable, mp)
			else
				failed += 1
				table.insert(
					failLines,
					mp:GetFullName() .. " — " .. tostring(result.err or "unknown error")
				)
			end
		end
		-- Deploy the Play/ship DRAFT rebuild runtime (server Script) so not-yet-finalized geometry
		-- reconstructs where the plugin does NOT run. Finalized parts replicate natively (no runtime).
		if stored > 0 then
			deployedScripts = ensureRebuildRuntime()
		end
	end
	-- ChangeHistory: GUARANTEED finish — the body is pcall-wrapped and the recording is finished in
	-- BOTH arms (a save_mesh error once left a recording wedged open and blocked add_keyframe).
	local persistErr: string? = nil
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("save_mesh")
		local okRun, runErr = pcall(doPersist)
		-- rid == nil (stale recording): proceeded UNRECORDED rather than wedge the pipeline.
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
		if not okRun then
			persistErr = tostring(runErr)
		end
	else
		local okRun, runErr = pcall(doPersist)
		if not okRun then
			persistErr = tostring(runErr)
		end
	end
	if persistErr ~= nil then
		return "save_mesh: internal error during local persist — " .. persistErr, true
	end
	-- Phase B: the real uploads (attribute-only DataModel writes; deliberately outside the recording).
	local uploaded = 0
	local uploadLines: { string } = {}
	for _, mp in uploadable do
		-- Asset naming: "SA_" .. <artifact/part name> (cleanup is manual dashboard work; names make it
		-- possible). A Handle inside a Model/Tool gets the artifact's name prefixed so the dashboard
		-- entry reads "SA_ProbeSword_Handle", not an anonymous "SA_Handle".
		local parent = mp.Parent
		local label = if parent ~= nil and (parent:IsA("Model") or parent:IsA("Tool"))
			then parent.Name .. "_" .. mp.Name
			else mp.Name
		local up = MeshFactory.uploadMeshPart(mp, label)
		if up.assetId == nil then
			table.insert(
				uploadLines,
				mp:GetFullName()
					.. " — upload FAILED: "
					.. tostring(up.err)
					.. " (local draft kept; re-run save_mesh to retry)"
			)
		else
			uploaded += 1
			local line = mp:GetFullName()
				.. " -> SA_"
				.. label
				.. " rbxassetid://"
				.. tostring(up.assetId)
			if up.imageId ~= nil then
				line = line .. " (+ texture rbxassetid://" .. tostring(up.imageId) .. ")"
			end
			if up.err ~= nil then
				line = line .. " — " .. tostring(up.err)
			end
			table.insert(uploadLines, line)
		end
	end
	local msg = string.format(
		"save_mesh: %d/%d mesh(es) drafted locally (MeshData in-place; renders now) and %d/%d uploaded "
			.. "as REAL owned assets — pending moderation; run confirm_mesh later to finalize each part "
			.. "onto its durable asset when the CDN serves it.",
		stored,
		#parts,
		uploaded,
		#uploadable
	)
	for _, line in uploadLines do
		msg = msg .. "\n  " .. line
	end
	if #deployedScripts > 0 then
		msg = msg
			.. "\nDeployed draft rebuild runtime: "
			.. table.concat(deployedScripts, " + ")
			.. " (the retired per-client SAMeshRebuildClient is removed if present)."
	end
	for _, line in skipLines do
		msg = msg .. "\n  SKIPPED " .. line
	end
	if failed > 0 then
		msg = msg .. string.format("\n%d FAILED:", failed)
		for _, line in failLines do
			msg = msg .. "\n  " .. line
		end
	end
	return msg, (stored == 0 and skipped == 0)
end

-- ---- confirm_mesh: the finalize half of the two-phase upload commit ----

local PROBE_BACKOFF = { 60, 300, 900 } -- delay in seconds AFTER the Nth probe; then the 30-min floor
local PROBE_FLOOR = 1800
local REVIEW_AFTER = 6 * 3600 -- still pending after this -> flag for user review (possibly rejected)
local MAX_PROBES_PER_PASS = 5 -- LOAD-BEARING: real fetch storms once pushed Studio into degraded mode

-- Seconds that must elapse since the LAST probe (or the upload, before any probe) before the next
-- probe. First probe is immediate; then 60s -> 5m -> 15m -> 30m floor.
local function backoffWindow(probeCount: number): number
	if probeCount <= 0 then
		return 0
	end
	return PROBE_BACKOFF[probeCount] or PROBE_FLOOR
end

-- Fetch-free moderation state from the sidecar's Open Cloud route. Returns
-- "Approved"|"Reviewing"|"Rejected"|"Unknown"|nil — nil means the route/key/sidecar is unavailable
-- (older sidecar, no key, HTTP off) and the caller must fall back to the engine-side probe.
local function fetchModerationState(sidecarBase: string?, assetId: number): string?
	if sidecarBase == nil then
		return nil
	end
	local ok, resp = pcall(function()
		return HttpService:RequestAsync({
			Url = sidecarBase .. "/opencloud/asset-status?assetId=" .. tostring(assetId),
			Method = "GET",
		})
	end)
	if not ok or resp == nil or not resp.Success then
		return nil
	end
	local okDecode, body = pcall(HttpService.JSONDecode, HttpService, resp.Body)
	if not okDecode or type(body) ~= "table" or type(body.state) ~= "string" then
		return nil
	end
	if body.state == "Unavailable" then
		return nil -- key/route present but unusable: fall back honestly
	end
	return body.state
end

-- Scan the same 5 roots the edit rescan covers for SAMeshAssetPending parts; gate at most 5 per pass
-- (oldest upload first, per-asset backoff). READINESS SOURCES, in order: (1) the sidecar's FETCH-FREE
-- Open Cloud moderation poll — Approved skips straight to finalize (whose own CreateMeshPartAsync
-- pcall is the real CDN test), Rejected flags immediately (definitive, unlike the 6h heuristic),
-- Reviewing waits WITHOUT spending an engine fetch; (2) fallback when the route/key is unavailable:
-- ContentProvider AssetFetchStatus — the engine probe that bypasses the session cache. NOTE: a
-- PreloadAsync Failure can be negative-cached by the Studio session even after approval — another
-- reason the Open Cloud source wins. No ChangeHistory recording: these are web yields we won't hold
-- a recording across (mirrors the edit-rescan rebuild, which is also unrecorded).
local function runConfirm(_input: any, context: any): (string, boolean)
	local sidecarBase: string? = nil
	if context ~= nil and context.config ~= nil then
		pcall(function()
			sidecarBase = context.config:getSidecarUrl()
		end)
	end
	local roots: { Instance } = {
		workspace,
		game:GetService("ServerStorage"),
		game:GetService("StarterPack"),
		game:GetService("ReplicatedStorage"),
		game:GetService("StarterPlayer"),
	}
	local pending: { MeshPart } = {}
	for _, root in roots do
		for _, d in root:GetDescendants() do
			if d:IsA("MeshPart") and d:GetAttribute(MeshFactory.ATTR_PENDING) == true then
				table.insert(pending, d)
			end
		end
	end
	if #pending == 0 then
		return "confirm_mesh: no pending mesh uploads found (nothing to finalize).", false
	end
	table.sort(pending, function(a: MeshPart, b: MeshPart): boolean
		return (tonumber(a:GetAttribute(MeshFactory.ATTR_UPLOADED_AT)) or 0)
			< (tonumber(b:GetAttribute(MeshFactory.ATTR_UPLOADED_AT)) or 0)
	end)
	local now = os.time()
	local lines: { string } = {}
	local probed, finalized = 0, 0
	for _, mp in pending do
		local assetId = mp:GetAttribute(MeshFactory.ATTR_ASSET_ID)
		local uploadedAt = tonumber(mp:GetAttribute(MeshFactory.ATTR_UPLOADED_AT)) or 0
		local probeCount = tonumber(mp:GetAttribute(MeshFactory.ATTR_PROBE_COUNT)) or 0
		local lastProbe = tonumber(mp:GetAttribute(MeshFactory.ATTR_LAST_PROBE)) or uploadedAt
		local age = now - uploadedAt
		if type(assetId) ~= "number" then
			table.insert(
				lines,
				"BROKEN " .. mp:GetFullName() .. " — pending but no SAMeshAssetId; re-run save_mesh"
			)
		elseif mp:GetAttribute(MeshFactory.ATTR_REVIEW_FLAG) == true then
			table.insert(
				lines,
				string.format(
					"REVIEW %s — rbxassetid://%d still unfetchable after %dh; flagged for user review "
						.. "(possibly rejected — check the Creator Dashboard)",
					mp:GetFullName(),
					assetId :: number,
					age // 3600
				)
			)
		elseif probed >= MAX_PROBES_PER_PASS then
			table.insert(
				lines,
				"CAPPED " .. mp:GetFullName() .. " — probe cap (5/pass) reached; re-run confirm_mesh"
			)
		elseif now - lastProbe < backoffWindow(probeCount) then
			table.insert(
				lines,
				string.format(
					"BACKOFF %s — next probe in %ds (probe %d was %ds ago)",
					mp:GetFullName(),
					backoffWindow(probeCount) - (now - lastProbe),
					probeCount,
					now - lastProbe
				)
			)
		else
			probed += 1
			mp:SetAttribute(MeshFactory.ATTR_PROBE_COUNT, probeCount + 1)
			mp:SetAttribute(MeshFactory.ATTR_LAST_PROBE, now)
			local moderation = fetchModerationState(sidecarBase, assetId :: number)
			local status: string
			if moderation == "Rejected" then
				mp:SetAttribute(MeshFactory.ATTR_REVIEW_FLAG, true)
				table.insert(
					lines,
					string.format(
						"REJECTED %s — rbxassetid://%d rejected by moderation (Open Cloud, definitive); "
							.. "flagged for user review — the mesh needs re-authoring + re-upload",
						mp:GetFullName(),
						assetId :: number
					)
				)
				continue
			elseif moderation == "Reviewing" then
				table.insert(
					lines,
					string.format(
						"PENDING %s — rbxassetid://%d moderation=Reviewing (Open Cloud, fetch-free; "
							.. "%dm since upload, probe %d; next probe after %ds)",
						mp:GetFullName(),
						assetId :: number,
						age // 60,
						probeCount + 1,
						backoffWindow(probeCount + 1)
					)
				)
				continue
			elseif moderation == "Approved" then
				-- Approved: skip the engine probe entirely — finalize's own CreateMeshPartAsync pcall
				-- is the truthful CDN test (PreloadAsync may negative-cache an earlier failure).
				status = "Success"
			else
				-- Unknown state or route unavailable: fall back to the engine-side truth probe.
				status = MeshFactory.probeAssetFetchStatus(assetId :: number)
			end
			if status == "Success" then
				local readySource = if moderation == "Approved"
					then "moderation=Approved (Open Cloud)"
					else "AssetFetchStatus=Success"
				local okF, ferr = MeshFactory.finalizeMeshPart(mp)
				if okF then
					finalized += 1
					table.insert(
						lines,
						string.format(
							"FINALIZED %s -> rbxassetid://%d (%s)",
							mp:GetFullName(),
							assetId :: number,
							readySource
						)
					)
				else
					table.insert(
						lines,
						string.format(
							"ERROR %s — %s but finalize failed: %s (left pending%s)",
							mp:GetFullName(),
							readySource,
							tostring(ferr),
							if moderation == "Approved" then " — CDN likely still propagating" else ""
						)
					)
				end
			elseif age > REVIEW_AFTER then
				mp:SetAttribute(MeshFactory.ATTR_REVIEW_FLAG, true)
				table.insert(
					lines,
					string.format(
						"REVIEW %s — AssetFetchStatus=%s after %.1fh pending; flagged for user review "
							.. "(possibly rejected — check the Creator Dashboard)",
						mp:GetFullName(),
						status,
						age / 3600
					)
				)
			else
				table.insert(
					lines,
					string.format(
						"PENDING %s — rbxassetid://%d AssetFetchStatus=%s (%dm since upload, probe %d; "
							.. "next probe after %ds)",
						mp:GetFullName(),
						assetId :: number,
						status,
						age // 60,
						probeCount + 1,
						backoffWindow(probeCount + 1)
					)
				)
			end
		end
	end
	local msg = string.format(
		"confirm_mesh: %d pending part(s); probed %d (cap %d/pass), finalized %d.",
		#pending,
		probed,
		MAX_PROBES_PER_PASS,
		finalized
	)
	for _, line in lines do
		msg = msg .. "\n  " .. line
	end
	return msg, false
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

-- import_mesh: a reference .glb (the TRELLIS/Blender conveyor output, parsed sidecar-side) ->
-- EditableMesh MeshPart, with optional painted-atlas apply. The COMMITTED version of the importer
-- that was session-scratch three times (residue rule: never re-derive it again).
local function runImport(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.file) ~= "string" or args.file == "" then
		return "import_mesh requires { file = '<name>.glb' (in assets/reference), atlas?, name?, position? }",
			true
	end
	local sidecarBase: string? = nil
	if context ~= nil and context.config ~= nil then
		pcall(function()
			sidecarBase = context.config:getSidecarUrl()
		end)
	end
	if sidecarBase == nil or sidecarBase == "" then
		return "import_mesh: sidecar URL unavailable (the vision sidecar must be connected)", true
	end
	local atlas: string? = if type(args.atlas) == "string" and args.atlas ~= "" then args.atlas else nil
	local ok, result = pcall(function(): MeshFactory.ImportResult
		return MeshFactory.importReferenceMesh(sidecarBase :: string, args.file :: string, atlas)
	end)
	if not ok then
		return "import_mesh: " .. tostring(result), true
	end
	local r = result :: MeshFactory.ImportResult
	local mp = r.part
	mp.Name = if type(args.name) == "string" and args.name ~= "" then args.name else "ImportedMesh"
	local position = resolvePosition(args)
	local grounded = CFrame.new(position + Vector3.new(0, mp.Size.Y / 2, 0))
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("import_mesh")
		mp.CFrame = grounded
		mp.Parent = workspace
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		mp.CFrame = grounded
		mp.Parent = workspace
	end
	return string.format(
		"import_mesh OK: '%s' from %s — %d verts / %d tris, uvs=%d normals=%d, DoubleSided, %s. "
			.. "Size %.2f x %.2f x %.2f at %s. NEXT: save_mesh + confirm_mesh (standing rule — "
			.. "session meshes blank out in Play).",
		mp.Name,
		r.source,
		r.vertices,
		r.faces,
		r.uvs,
		r.normals,
		if r.texApplied then "painted atlas APPLIED (session-backed)" else "no atlas (gray)",
		mp.Size.X,
		mp.Size.Y,
		mp.Size.Z,
		mp:GetFullName()
	),
		false
end

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
		name = "import_mesh",
		description = "IMPORT a reference .glb from assets/reference (the TRELLIS/Blender conveyor output) as "
			.. "a MeshPart via EditableMesh — geometry + smooth NORMALS + per-vertex UVs (no V-flip), "
			.. "DoubleSided by default (thin generated blades cull see-through from behind otherwise). "
			.. "atlas? applies a painted atlas (.png/.jpeg, or a .glb's embedded bake) as a live "
			.. "session-backed texture (EditableImage -> TextureContent). Serves the decoupled-texture "
			.. "conveyor: rig_weapon.py authors UVs, paint_atlas paints them, this tool lands both in "
			.. "Studio. ALWAYS follow with save_mesh + confirm_mesh (standing rule: session meshes blank "
			.. "out in Play). Inputs: file (required), atlas?, name?, position?.",
		inputSchema = {
			type = "object",
			properties = {
				file = {
					type = "string",
					description = "GLB filename in assets/reference, e.g. 'forge-falchion-clean.glb'.",
				},
				atlas = {
					type = "string",
					description = "Optional atlas filename in assets/reference (.png/.jpeg painted, or .glb embedded).",
				},
				name = { type = "string", description = "Name for the MeshPart (default 'ImportedMesh')." },
				position = POS_SCHEMA,
			},
			required = { "file" },
		},
		destructive = true,
		run = runImport,
	},
	{
		name = "save_mesh",
		description = "PERSIST the custom meshes in a build so they SURVIVE Play / save / ship (in-session "
			.. "generate_mesh/author_mesh geometry is edit-only and goes blank in a playtest until saved). "
			.. "TWO-PHASE: (1) drafts each session mesh LOCALLY in-place (a MeshData child + SALocalMesh tag "
			.. "— keeps rendering immediately; a deployed server SAMeshRebuildRuntime reconstructs drafts in "
			.. "Play, incl. cloned Tool Handles) and (2) UPLOADS the mesh + its generated texture as REAL "
			.. "creator-owned assets via CreateAssetAsync (named 'SA_<part name>'; needs the 'CreateAssetAsync "
			.. "Lua API' beta flag). Fresh uploads sit in MODERATION (often hours) — run confirm_mesh later to "
			.. "finalize ready parts onto their durable assets. Parts with an existing SAMeshAssetId are "
			.. "skipped (never re-uploaded); blank drafts from a reopened place are auto-migrated from "
			.. "MeshData before upload. Inputs: target (path to the Model/MeshPart; omit to use the "
			.. "selection). Run it on a FINISHED build, not every iteration.",
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
	{
		name = "confirm_mesh",
		description = "FINALIZE save_mesh uploads once moderation clears (phase 2 of the mesh persist). "
			.. "Scans workspace/ServerStorage/StarterPack/ReplicatedStorage/StarterPlayer for "
			.. "SAMeshAssetPending parts, gates at most 5 per call (oldest first; per-asset backoff "
			.. "60s -> 5m -> 15m -> 30m). READINESS: first the sidecar's FETCH-FREE Open Cloud moderation "
			.. "poll (Approved -> finalize now; Rejected -> flagged REJECTED, definitive; Reviewing -> wait, "
			.. "no engine fetch spent); fallback when the sidecar/key is unavailable: ContentProvider "
			.. "AssetFetchStatus (bypasses the session cache that fakes readiness). On ready it swaps each "
			.. "part onto its durable asset IN PLACE (ApplyMesh; welds/children/identity preserved), applies "
			.. "the uploaded texture, and clears the local draft. Everything else is reported honestly per "
			.. "part (PENDING/BACKOFF/CAPPED with the exact source+status); after 6h still pending a part is "
			.. "flagged SAMeshReviewFlag — check the Creator Dashboard. No inputs. Re-run periodically after "
			.. "save_mesh; the volume caps make repeat calls safe.",
		inputSchema = { type = "object", properties = {} },
		destructive = true,
		run = runConfirm,
	},
} :: { Descriptor }

return Mesh
