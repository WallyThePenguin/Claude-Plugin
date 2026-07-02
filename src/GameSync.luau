--!strict
-- GameSync: bank the place's AUTHORED scripts as git-versioned files under game/ (path-C v1,
-- pull-first per the skeptic panel — the BANKING layer; edit_script remains the inner loop).
-- Pure helpers here are spec-tested (GameSyncSpec); the impure pull lives in Tools/GameSyncTool.
--
-- Layout: game/src/<Service>/<ancestor…>/<Name>.<kind>.luau (real Rojo convention — the full
-- ancestor chain as directories). The MANIFEST is the source of truth for the file->instance
-- mapping (filenames are sanitized for Windows and may diverge from instance names).

local GameSync = {}

-- Scripts/subtrees that are agent infrastructure or Roblox default forks — never game code.
-- Exclusion is by IDENTITY (names + the StudioAgentGenerated attribute), NOT header-sniffing:
-- two generated-header formats already coexist (thin launchers vs legacy full stamps).
GameSync.NAME_DENYLIST = {
	ItemBehaviorRuntime = true,
	ItemAnimRuntime = true,
	ItemHitClient = true,
	ItemHitServer = true,
	NpcAI = true,
	StudioAgentPlayServer = true,
	StudioAgentPlayClient = true,
}
-- Subtree roots excluded only at their KNOWN location (value = the required top-level service):
-- a game-authored module the user happens to name "PlayerModule" elsewhere must still bank.
GameSync.SUBTREE_DENYLIST = {
	StudioAgentRuntime = "ReplicatedStorage",
	PlayerModule = "StarterPlayer",
	PlayerScriptsLoader = "StarterPlayer",
	RbxCharacterSounds = "StarterPlayer",
}

-- Reserved test namespace + legacy test symbols: flagged in the manifest (the factory gate is
-- where they BLOCK; the pull records honestly).
local TEST_PATTERNS = { "StudioAgentTest_%w+", "TestAutoKill" }

local WINDOWS_RESERVED = {
	con = true, prn = true, aux = true, nul = true,
	com1 = true, com2 = true, com3 = true, com4 = true, com5 = true,
	com6 = true, com7 = true, com8 = true, com9 = true,
	lpt1 = true, lpt2 = true, lpt3 = true, lpt4 = true, lpt5 = true,
	lpt6 = true, lpt7 = true, lpt8 = true, lpt9 = true,
}

-- ".server.luau" | ".client.luau" | ".luau" per the Rojo convention.
function GameSync.kindSuffix(className: string): string
	if className == "Script" then
		return ".server.luau"
	end
	if className == "LocalScript" then
		return ".client.luau"
	end
	return ".luau"
end

-- Sanitize ONE path segment for Windows: strip illegal/control chars, trailing dots/spaces,
-- prefix reserved device names, never empty. Returns (segment, changed).
function GameSync.sanitizeSegment(name: string): (string, boolean)
	local s = string.gsub(name, '[<>:"/\\|%?%*%c]', "_")
	s = string.gsub(s, "[%. ]+$", "")
	local changed = s ~= name
	if s == "" then
		return "unnamed", true
	end
	local base = string.lower((string.gsub(s, "%..*$", "")))
	if WINDOWS_RESERVED[base] then
		return "rbx_" .. s, true
	end
	return s, changed
end

-- Build the repo-relative file path for a script: segments = the instance path from the service
-- down to (and including) the script's own name. Returns (relpath, anyChanged).
function GameSync.relpathFor(segments: { string }, className: string): (string, boolean)
	local parts: { string } = { "src" }
	local anyChanged = false
	for i, seg in segments do
		local clean, changed = GameSync.sanitizeSegment(seg)
		anyChanged = anyChanged or changed
		if i == #segments then
			table.insert(parts, clean .. GameSync.kindSuffix(className))
		else
			table.insert(parts, clean)
		end
	end
	return table.concat(parts, "/"), anyChanged
end

-- The relpath PREFIX a scoped pull covers: "src/<sanitized segments>/". The sidecar merges the
-- manifest outside this prefix and prunes orphans only inside it.
function GameSync.scopePrefix(segments: { string }): string
	local parts: { string } = { "src" }
	for _, seg in segments do
		table.insert(parts, (GameSync.sanitizeSegment(seg)))
	end
	return table.concat(parts, "/") .. "/"
end

-- Deterministic content hash (djb2, hex) — the manifest baseHash game_push will guard on.
function GameSync.hashSource(source: string): string
	local h = 5381
	for i = 1, #source do
		h = (h * 33 + string.byte(source, i)) % 4294967296
	end
	return string.format("%08x", h)
end

-- Distinct test symbols present in a source ({} when clean).
function GameSync.findTestSymbols(source: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, pat in TEST_PATTERNS do
		for m in string.gmatch(source, pat) do
			if not seen[m] then
				seen[m] = true
				table.insert(out, m)
			end
		end
	end
	table.sort(out)
	return out
end

-- Case-insensitive collision detection over proposed relpaths (NTFS is case-insensitive while
-- Roblox names are case-sensitive; two siblings may also share a name outright). Returns the
-- list of colliding groups ({} when clean) — the pull REFUSES with the twins listed rather than
-- silently last-wins.
function GameSync.findCollisions(relpaths: { string }): { { string } }
	local byLower: { [string]: { string } } = {}
	for _, p in relpaths do
		local key = string.lower(p)
		if byLower[key] == nil then
			byLower[key] = {}
		end
		table.insert(byLower[key], p)
	end
	local out: { { string } } = {}
	for _, group in byLower do
		if #group > 1 then
			table.insert(out, group)
		end
	end
	return out
end

return GameSync
