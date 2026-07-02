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

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local GameSync = require(script.Parent.Parent.GameSync)
local Path = require(script.Parent.Path)

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
} :: { Descriptor }

return GameSyncTool
