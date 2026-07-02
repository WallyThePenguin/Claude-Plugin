--!strict
-- GameSyncTool: game_pull — bank the place's AUTHORED scripts into git-versioned files under
-- game/ via the sidecar (which owns filesystem + git and AUTO-COMMITS every pull). Pull-first
-- per the skeptic panel: this is the BANKING layer; edit_script stays the inner loop; game_push
-- is designed but deferred (see docs/superpowers/specs/2026-07-02-gamesync-factory-v1-design.md).
--
-- Guards (lessons already paid for): refuses during any playtest — an F5 run (IsRunning) OR our
-- own ExecutePlayModeAsync test, detected by the injected StudioAgentPlay* scripts, because the
-- edit DM reports IsEdit=true during those; refuses when game/ is git-dirty (sidecar-side);
-- excludes agent infrastructure by IDENTITY (name/subtree denylists + the StudioAgentGenerated
-- attribute) and REPORTS every exclusion; refuses on case-insensitive relpath collisions
-- (listing the twins) rather than silent last-wins; flags test symbols into the manifest.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local GameSync = require(script.Parent.Parent.GameSync)
local Path = require(script.Parent.Path)
local StoreClient = require(script.Parent.Parent.StoreClient)

local GameSyncTool = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local CONTAINERS = {
	"Workspace",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Lighting",
	"SoundService",
}

-- A playtest is active when an F5 run is live OR our own ExecutePlayModeAsync test's injected
-- scripts are present in the edit DM (IsEdit stays true during those — the RunService check
-- alone cannot see them).
local function playtestActive(): boolean
	if RunService:IsRunning() then
		return true
	end
	local sss = game:GetService("ServerScriptService")
	return sss:FindFirstChild("StudioAgentPlayServer") ~= nil
end

-- Walk ancestors: excluded when a denylisted subtree root sits AT ITS KNOWN top-level service
-- (identity = name + place: a user script merely NAMED "PlayerModule" elsewhere still banks),
-- the name itself is a generated-runtime name, or the StudioAgentGenerated attribute is set.
local function excluded(inst: Instance): (boolean, string?)
	if GameSync.NAME_DENYLIST[inst.Name] then
		return true, "generated runtime/launcher name"
	end
	if inst:GetAttribute("StudioAgentGenerated") == true then
		return true, "StudioAgentGenerated attribute"
	end
	-- Find the top-level service this instance lives under, then re-walk for denylisted roots.
	local top: Instance? = inst
	while top ~= nil and top.Parent ~= game do
		top = top.Parent
	end
	local topName = if top ~= nil then top.Name else ""
	local node: Instance? = inst
	while node ~= nil and node ~= game do
		local requiredService = GameSync.SUBTREE_DENYLIST[node.Name]
		if requiredService ~= nil then
			-- StarterPlayerScripts subtrees report their service as StarterPlayer.
			if topName == requiredService then
				return true, "inside the " .. node.Name .. " subtree"
			end
		end
		node = node.Parent
	end
	return false, nil
end

-- The instance path segments from the top-level service down to the script itself.
local function segmentsFor(inst: Instance): { string }
	local segs: { string } = {}
	local node: Instance? = inst
	while node ~= nil and node ~= game do
		table.insert(segs, 1, node.Name)
		node = node.Parent
	end
	return segs
end

local function readSource(container: LuaSourceContainer): string?
	local ok, source = pcall(function(): string
		return ScriptEditorService:GetEditorSource(container)
	end)
	if ok then
		return source
	end
	return nil
end

local function runPull(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if playtestActive() then
		return "game_pull: refused — a playtest is active, so sources could come from the wrong "
			.. "DataModel state. Stop the test first.", true
	end

	-- Roots: an explicit path (a SCOPED pull — the sidecar merges the manifest outside the
	-- scope and prunes orphans only inside it) or the standard containers (a FULL pull).
	local roots: { Instance } = {}
	local scope: string? = nil
	if type(args.root) == "string" and args.root ~= "" then
		local inst, err = Path.resolve(args.root)
		if inst == nil then
			return "game_pull: " .. tostring(err), true
		end
		roots = { inst }
		scope = GameSync.scopePrefix(segmentsFor(inst))
	else
		for _, name in CONTAINERS do
			local ok, service = pcall(function(): Instance
				return game:GetService(name)
			end)
			if ok and service ~= nil then
				table.insert(roots, service)
			end
		end
	end

	-- Collect + partition.
	local files: { [string]: string } = {}
	local manifest: { [string]: any } = {}
	local relpaths: { string } = {}
	local excludedNames: { string } = {}
	local flagged: { string } = {}
	local unreadable: { string } = {}
	local pulled = 0
	local seen: { [Instance]: boolean } = {}
	for _, root in roots do
		local candidates: { Instance } = root:GetDescendants()
		if root:IsA("LuaSourceContainer") then
			table.insert(candidates, 1, root)
		end
		for _, inst in candidates do
			if not inst:IsA("LuaSourceContainer") or seen[inst] then
				continue
			end
			seen[inst] = true
			local skip, reason = excluded(inst)
			if skip then
				table.insert(excludedNames, inst.Name .. " (" .. tostring(reason) .. ")")
				continue
			end
			local source = readSource(inst :: LuaSourceContainer)
			if source == nil then
				table.insert(unreadable, inst:GetFullName())
				continue
			end
			local segs = segmentsFor(inst)
			local relpath = GameSync.relpathFor(segs, inst.ClassName)
			local entry: { [string]: any } = {
				instancePath = "game." .. inst:GetFullName(),
				className = inst.ClassName,
				baseHash = GameSync.hashSource(source),
			}
			if inst:IsA("BaseScript") then
				entry.enabled = inst.Enabled
			end
			if inst:IsA("Script") then
				entry.runContext = inst.RunContext.Name
			end
			local syms = GameSync.findTestSymbols(source)
			if #syms > 0 then
				entry.testSymbols = syms
				table.insert(flagged, inst.Name .. " [" .. table.concat(syms, ",") .. "]")
			end
			files[relpath] = source
			manifest[relpath] = entry
			table.insert(relpaths, relpath)
			pulled += 1
		end
	end

	if pulled == 0 then
		return "game_pull: no authored scripts found (excluded "
			.. tostring(#excludedNames)
			.. " infrastructure/default scripts)", false
	end

	local collisions = GameSync.findCollisions(relpaths)
	if #collisions > 0 then
		local lines: { string } = {}
		for _, group in collisions do
			table.insert(lines, table.concat(group, "  <->  "))
		end
		return "game_pull: refused — case-insensitive filename collisions (rename one of each "
			.. "pair):\n" .. table.concat(lines, "\n"), true
	end

	-- Ship to the sidecar (it refuses when game/ is git-dirty, and auto-commits).
	local message = if type(args.message) == "string" and args.message ~= ""
		then args.message
		else "chore(game): pull " .. tostring(pulled) .. " script(s) from the place"
	local body: { [string]: any } = { files = files, manifest = manifest, message = message }
	if scope ~= nil then
		body.scope = scope
	end
	local okReq, res = pcall(function()
		return HttpService:RequestAsync({
			Url = context.config:getSidecarUrl() .. "/game/write",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
	if not okReq then
		return "game_pull: sidecar unreachable (" .. tostring(res) .. ")", true
	end
	local r = res :: any
	local okDec, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not r.Success then
		local why = if okDec and type(payload) == "table" then tostring((payload :: any).error) else r.Body
		return "game_pull: " .. tostring(why), true
	end

	local commit = if okDec and type(payload) == "table" then (payload :: any).commit else nil
	local removedList = if okDec and type(payload) == "table" then (payload :: any).removed else nil
	local out = "game_pull OK: banked "
		.. tostring(pulled)
		.. " script(s) into game/ "
		.. (if commit ~= nil then "(git commit " .. tostring(commit) .. ")" else "(no changes vs the last pull)")
	if type(removedList) == "table" and #removedList > 0 then
		out ..= "\npruned "
			.. tostring(#removedList)
			.. " orphaned file(s) (renamed/deleted in Studio): "
			.. table.concat(removedList, ", ")
	end
	if #excludedNames > 0 then
		out ..= "\nexcluded infrastructure/defaults ("
			.. tostring(#excludedNames)
			.. "): "
			.. table.concat(excludedNames, ", ")
	end
	if #flagged > 0 then
		out ..= "\nTEST SYMBOLS flagged (recorded in the manifest; the factory gate blocks on these): "
			.. table.concat(flagged, "; ")
	end
	if #unreadable > 0 then
		out ..= "\nunreadable (skipped): " .. table.concat(unreadable, ", ")
	end
	return out, false
end

-- Compile-check a source with loadstring WITHOUT executing it (edit_script's gate, local copy).
local function compileCheck(source: string): (boolean, string?)
	if loadstring == nil then
		return true, nil -- unavailable (playtest) — push already refuses during playtests
	end
	local okCall, chunk, compileErr = pcall(function()
		return loadstring(source, "=game_push")
	end)
	if not okCall then
		return true, nil
	end
	if chunk == nil then
		return false, tostring(compileErr)
	end
	return true, nil
end

-- game_push: banked files -> live place, guarded by the manifest baseHash (see GameSync.pushDecision).
local function runPush(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if playtestActive() then
		return "game_push: refused — a playtest is active. Stop the test first.", true
	end
	local forceSet: { [string]: boolean } = {}
	if type(args.force) == "table" then
		for _, rel in ipairs(args.force :: { any }) do
			if type(rel) == "string" then
				forceSet[rel] = true
			end
		end
	end
	local prefix = if type(args.path) == "string" and args.path ~= "" then args.path else nil

	-- Fetch the banked files + manifest from the sidecar.
	local okReq, res = pcall(function()
		return HttpService:RequestAsync({
			Url = context.config:getSidecarUrl() .. "/game/read",
			Method = "GET",
		})
	end)
	if not okReq then
		return "game_push: sidecar unreachable (" .. tostring(res) .. ")", true
	end
	local r = res :: any
	if not r.Success then
		return "game_push: sidecar HTTP " .. tostring(r.StatusCode), true
	end
	local okDec, payload = pcall(function()
		return HttpService:JSONDecode(r.Body)
	end)
	if not okDec or type(payload) ~= "table" then
		return "game_push: bad /game/read response", true
	end
	local files = (payload :: any).files
	local manifest = (payload :: any).manifest
	if type(files) ~= "table" or type(manifest) ~= "table" then
		return "game_push: bad /game/read response (no files/manifest)", true
	end

	-- Deterministic order.
	local relpaths: { string } = {}
	for rel in pairs(manifest :: { [string]: any }) do
		if type(rel) == "string" and files[rel] ~= nil and (prefix == nil or string.sub(rel, 1, #prefix) == prefix) then
			table.insert(relpaths, rel)
		end
	end
	table.sort(relpaths)
	if #relpaths == 0 then
		return "game_push: nothing to push"
			.. (if prefix ~= nil then " under '" .. prefix .. "'" else " (run game_pull first)"), false
	end

	local lines: { string } = {}
	local counts = { current = 0, update = 0, create = 0, diverged = 0, forced = 0, blocked = 0 }
	local rid = ChangeHistoryService:TryBeginRecording("game_push")
	if rid == nil and RunService:IsEdit() then
		return "game_push: could not begin a change recording", true
	end
	local anyWrite = false
	for _, rel in relpaths do
		local entry = (manifest :: any)[rel]
		local fileSource = files[rel] :: string
		local instPath = tostring(entry.instancePath)
		local inst = Path.resolve(instPath)
		local liveSource: string? = nil
		if inst ~= nil and inst:IsA("LuaSourceContainer") then
			local okRead, src = pcall(function(): string
				return ScriptEditorService:GetEditorSource(inst :: LuaSourceContainer)
			end)
			liveSource = if okRead then src else nil
		end
		local decision = GameSync.pushDecision(
			fileSource,
			liveSource,
			if type(entry.baseHash) == "string" then entry.baseHash else nil,
			forceSet[rel] == true
		)
		if decision == "current" then
			counts.current += 1
		elseif decision == "diverged" then
			counts.diverged += 1
			table.insert(
				lines,
				"DIVERGED (Studio edited since the pull; not overwritten): "
					.. rel
					.. " — pass force=[\"" .. rel .. "\"] to overwrite (the displaced live source gets staged first), or game_pull to re-bank"
			)
		else
			local okCompile, cerr = compileCheck(fileSource)
			if not okCompile then
				counts.blocked += 1
				table.insert(lines, "SYNTAX (not applied): " .. rel .. " — " .. tostring(cerr))
				continue
			end
			if decision == "create" then
				-- Push-create only when the PARENT exists (the world is DataModel-owned).
				local lastDot = string.find(string.reverse(instPath), ".", 1, true)
				local parentPath = if lastDot ~= nil then string.sub(instPath, 1, #instPath - lastDot) else nil
				local childName = if lastDot ~= nil then string.sub(instPath, #instPath - lastDot + 2) else instPath
				local parent = if parentPath ~= nil then Path.resolve(parentPath) else nil
				if parent == nil then
					counts.blocked += 1
					table.insert(
						lines,
						"PARENT MISSING (world instances are not pushed — build it first): " .. rel
					)
					continue
				end
				local className = tostring(entry.className)
				local okNew, newInst = pcall(function(): Instance
					return Instance.new(className)
				end)
				if not okNew then
					counts.blocked += 1
					table.insert(lines, "BAD CLASS " .. className .. ": " .. rel)
					continue
				end
				local created = newInst :: Instance
				created.Name = childName;
				(created :: any).Source = fileSource
				if created:IsA("BaseScript") and entry.enabled ~= nil then
					created.Enabled = entry.enabled == true
				end
				created.Parent = parent
				counts.create += 1
				anyWrite = true
				table.insert(lines, "created: " .. rel .. " -> " .. instPath)
			else
				if decision == "forced" then
					-- Stage the displaced live source FIRST: nothing destroyed without a copy.
					local slug = StoreClient.slug("displaced-" .. rel) or "displaced"
					local okStage = StoreClient.put(context.config, "staging", slug, {
						displacedFrom = instPath,
						relpath = rel,
						source = liveSource,
						at = os.time(),
					})
					if not okStage then
						counts.blocked += 1
						table.insert(
							lines,
							"FORCE BLOCKED (could not stage the displaced live source): " .. rel
						)
						continue
					end
					counts.forced += 1
					table.insert(lines, "FORCED (displaced source staged as staging/" .. slug .. "): " .. rel)
				else
					counts.update += 1
				end
				local okWrite, werr = pcall(function()
					ScriptEditorService:UpdateSourceAsync(
						inst :: LuaSourceContainer,
						function(_old: string): string
							return fileSource
						end
					)
				end)
				if not okWrite then
					counts.blocked += 1
					table.insert(lines, "WRITE FAILED: " .. rel .. " — " .. tostring(werr))
				else
					anyWrite = true
					if decision == "update" then
						table.insert(lines, "updated: " .. rel)
					end
				end
			end
		end
	end
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if anyWrite
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	local out = string.format(
		"game_push: %d updated, %d created, %d current, %d DIVERGED (skipped), %d forced, %d blocked",
		counts.update,
		counts.create,
		counts.current,
		counts.diverged,
		counts.forced,
		counts.blocked
	)
	if #lines > 0 then
		out ..= "\n" .. table.concat(lines, "\n")
	end
	if counts.update + counts.create + counts.forced > 0 then
		out ..= "\nNOTE: run game_pull after verifying, so the manifest baseHash re-banks this state."
	end
	return out, counts.blocked > 0
end

GameSyncTool.descriptors = {
	{
		name = "game_pull",
		description = "BANK the place's authored scripts into git-versioned files under game/ (the "
			.. "sidecar auto-commits — every pull is a recoverable git state). Excludes agent "
			.. "infrastructure (StudioAgentRuntime, generated launchers, Roblox default forks) and "
			.. "reports the exclusions; flags test symbols; refuses during a playtest, on filename "
			.. "collisions, or when game/ has uncommitted changes. Use it after building/refining "
			.. "game code so the work is versioned; edit_script remains the day-to-day editing tool.",
		inputSchema = {
			type = "object",
			properties = {
				root = {
					type = "string",
					description = "Pull only under this path (e.g. game.ServerScriptService). Omit for all containers.",
				},
				message = { type = "string", description = "Git commit message for this pull." },
			},
		},
		destructive = false,
		run = runPull,
	},
	{
		name = "game_push",
		description = "PUSH the banked game/ files back into the live place. Per-script guard: a "
			.. "script Studio has edited since the last pull is DIVERGED and refused (pass its relpath "
			.. "in force=[…] to overwrite — the displaced live source is staged first, nothing is "
			.. "destroyed without a copy). Creates missing scripts only when their PARENT exists (the "
			.. "world stays DataModel-owned). Every write is compile-checked and undoable. Run "
			.. "game_pull afterward to re-bank the manifest.",
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Only push relpaths under this prefix (e.g. src/ServerScriptService).",
				},
				force = {
					type = "array",
					items = { type = "string" },
					description = "Exact relpaths allowed to overwrite DIVERGED live scripts.",
				},
			},
		},
		destructive = true,
		run = runPush,
	},
} :: { Descriptor }

return GameSyncTool
