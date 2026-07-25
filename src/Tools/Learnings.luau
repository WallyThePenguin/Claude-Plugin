--!strict
-- Learnings tools: learn + unlearn + recall_learnings. learn/unlearn wrap context.learnings (the
-- capped plugin-settings store that rides the always-on "# Priority learnings" preamble — a RECENCY
-- WINDOW) and MIRROR every change into the sidecar's git-versioned archive
-- (sidecar/store/learnings/<category>.json — UNBOUNDED; rotation out of the window no longer loses
-- a lesson). recall_learnings reads the full archive back. Archive IO is fail-open: when the
-- sidecar is down the local behavior is unchanged and the note says so honestly.
-- learn/unlearn are parent-only + LOCAL (plugin state); recall_learnings RELAYS (it is sidecar
-- HTTP, which is server-only during a client-view playtest).

local LearningsStore = require(script.Parent.Parent.Learnings)
local StoreClient = require(script.Parent.Parent.StoreClient)

local Learnings = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local RECALL_MAX = 100

local function store(context: any): any
	return if type(context) == "table" then context.learnings else nil
end

-- The archive document shape: { seq = <last issued archive id>, category = <true name>,
-- entries = { {id, localId, text, createdAt, retired?} } }.
local function loadArchive(config: any, slug: string): (any?, string?)
	local doc, err = StoreClient.get(config, "learnings", slug)
	if doc == nil and err == "not found" then
		return { seq = 0, entries = {} }, nil
	end
	if doc == nil then
		return nil, err
	end
	if type(doc.seq) ~= "number" then
		doc.seq = 0
	end
	if type(doc.entries) ~= "table" then
		doc.entries = {}
	end
	return doc, nil
end

-- Append to the archive; returns a short status fragment for the tool note.
local function archiveAppend(config: any, category: string, localId: number, text: string): string
	local slug = StoreClient.slug(category)
	if slug == nil then
		return "; archive skipped (category does not slug)"
	end
	local doc, err = loadArchive(config, slug)
	if doc == nil then
		return "; archive unavailable (" .. tostring(err) .. ") — kept locally only"
	end
	doc.seq += 1
	doc.category = category
	table.insert(doc.entries, {
		id = doc.seq,
		localId = localId,
		-- The exact LOCAL bucket key. Distinct local categories ('npc ai' vs 'npc_ai') SLUG to the
		-- same archive doc, and each bucket's localId sequence restarts at 1 — so retire must match
		-- on (bucket, localId), not localId alone, or it tombstones another bucket's entry.
		bucket = LearningsStore.normalizeCategory(category),
		text = text,
		createdAt = os.time(),
	})
	local ok, putErr = StoreClient.put(config, "learnings", slug, doc)
	if not ok then
		return "; archive write failed (" .. tostring(putErr) .. ") — kept locally only"
	end
	return "; archived (A#" .. tostring(doc.seq) .. ")"
end

-- Tombstone the NEWEST non-retired archive entry with this localId. Returns a status fragment.
local function archiveRetire(config: any, category: string, localId: number): string
	local slug = StoreClient.slug(category)
	if slug == nil then
		return ""
	end
	local doc, err = loadArchive(config, slug)
	if doc == nil then
		return "; archive unavailable (" .. tostring(err) .. ")"
	end
	local bucket = LearningsStore.normalizeCategory(category)
	local target: any = nil
	for _, e in ipairs(doc.entries) do
		if
			type(e) == "table"
			and e.localId == localId
			and e.retired ~= true
			-- Match the exact local bucket; a legacy entry with no bucket stamp still matches.
			and (e.bucket == nil or e.bucket == bucket)
		then
			target = e -- keep scanning: the NEWEST match wins (local ids recycle as the window rotates)
		end
	end
	if target == nil then
		return "; not in the archive"
	end
	target.retired = true
	local ok, putErr = StoreClient.put(config, "learnings", slug, doc)
	if not ok then
		return "; archive retire failed (" .. tostring(putErr) .. ")"
	end
	return "; retired from the archive (A#" .. tostring(target.id) .. ")"
end

local function learn(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "learn is not available here (no learnings in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "learn requires { category = <string>, text = <string> }", true
	end
	if type(args.text) ~= "string" then
		return "learn requires { category = <string>, text = <string> }", true
	end
	local note, newId = s:add(args.category, args.text)
	if newId ~= nil then
		note ..= archiveAppend(context.config, args.category, newId, args.text)
	end
	return note, false
end

local function unlearn(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "unlearn is not available here (no learnings in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "unlearn requires { category = <string>, id = <number> }", true
	end
	local id = tonumber(args.id)
	if id == nil then
		return "unlearn requires { category = <string>, id = <number> }", true
	end
	local note = s:forget(args.category, args.id)
	-- Only tombstone when the local remove succeeded (the note pattern is stable).
	if string.find(note, "unlearned", 1, true) ~= nil then
		note ..= archiveRetire(context.config, args.category, id)
	end
	return note, false
end

local function recallLearnings(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" or args.category == "" then
		return "recall_learnings requires { category = <string>, query? = <string> }", true
	end
	local slug = StoreClient.slug(args.category)
	if slug == nil then
		return "recall_learnings: category does not slug to a store id", true
	end
	local doc, err = loadArchive(context.config, slug)
	if doc == nil then
		return "recall_learnings: " .. tostring(err), true
	end
	local query = if type(args.query) == "string" and args.query ~= ""
		then string.lower(args.query)
		else nil
	local live: { any } = {}
	for _, e in ipairs(doc.entries) do
		if type(e) == "table" and e.retired ~= true and type(e.text) == "string" then
			if query == nil or string.find(string.lower(e.text), query, 1, true) ~= nil then
				table.insert(live, e)
			end
		end
	end
	if #live == 0 then
		return "no archived learnings for '" .. args.category .. "'" .. (if query ~= nil
			then " matching the query"
			else "") .. " (the archive holds everything ever learned; the preamble shows only the recent window)",
			false
	end
	-- Oldest -> newest reads as accumulated experience; over the cap, keep the NEWEST.
	local from = math.max(1, #live - RECALL_MAX + 1)
	local lines: { string } = {}
	for i = from, #live do
		local e = live[i]
		table.insert(lines, "A#" .. tostring(e.id) .. " " .. tostring(e.text))
	end
	local header = tostring(#lines)
		.. " archived learning(s) for '"
		.. args.category
		.. "'"
		.. (
			if from > 1
				then " (newest " .. tostring(RECALL_MAX) .. " of " .. tostring(#live) .. ")"
				else ""
		)
	return header .. "\n" .. table.concat(lines, "\n"), false
end

Learnings.descriptors = {
	{
		name = "learn",
		description = "Record a DURABLE per-category LESSON to apply on every future build in that category "
			.. "(it rides your context automatically next time, marked high-priority). Use it AFTER evaluate "
			.. "catches a miss and you FIX it, or after user feedback: capture the confirmed correction so you "
			.. "never repeat it. category is the asset category (e.g. 'locomotion', matching the rubric). Keep "
			.. "each lesson to one concise, general sentence (a reusable rule, not this one build's detail). "
			.. "Lessons also land in an UNBOUNDED git-versioned archive — the always-on list is just the recent "
			.. "window; recall_learnings reaches everything. This is for QUALITY-LOOP lessons; use remember for "
			.. "this game's architecture or general prefs.",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "Asset category (e.g. 'locomotion'), matching the rubric category.",
				},
				text = {
					type = "string",
					description = "The confirmed lesson (one concise, reusable sentence).",
				},
			},
			required = { "category", "text" },
		},
		destructive = false,
		run = learn,
	},
	{
		name = "unlearn",
		description = "Remove a learning by its #id (shown in the '# Priority learnings' list) when it is now "
			.. "wrong or obsolete. Input: category + id. Also retires it from the archive.",
		inputSchema = {
			type = "object",
			properties = {
				category = { type = "string", description = "The category the learning is in." },
				id = { type = "number", description = "The #id of the learning to remove." },
			},
			required = { "category", "id" },
		},
		destructive = false,
		run = unlearn,
	},
	{
		name = "recall_learnings",
		description = "Read the FULL archive of every lesson ever learned for a category (the always-on "
			.. "'# Priority learnings' block shows only the recent window). Optional query = substring filter. "
			.. "Use it BEFORE building in a category you have history with, or when a preamble learning hints "
			.. "at older context. Archive ids (A#) are read-only history; unlearn works on the window's #ids.",
		inputSchema = {
			type = "object",
			properties = {
				category = { type = "string", description = "Asset category (e.g. 'gui')." },
				query = {
					type = "string",
					description = "Optional case-insensitive substring filter.",
				},
			},
			required = { "category" },
		},
		destructive = false,
		run = recallLearnings,
	},
} :: { Descriptor }

return Learnings
