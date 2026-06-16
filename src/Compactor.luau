--!strict
-- Compactor: keeps a long chat under the model's context window. Two mechanisms:
--   1) pruneImagesKeepingLast — drop every screenshot except the most recent from live context.
--   2) compact — when the last prompt crossed the threshold, replace older turns with one
--      model-generated summary, keeping a recent verbatim tail and the history API-valid.
-- The live DataModel is the source of truth, so a lossy summary is safe (the agent re-queries).
--
-- This file holds the PURE logic + the model-calling compact(); MessageUtil holds the shared helpers.

local MessageUtil = require(script.Parent.MessageUtil)

local Compactor = {}

local PRUNE_NOTE = "[earlier screenshot dropped to save context]"

local SUMMARY_SYSTEM = "You are compacting a long Roblox Studio build conversation so it can be "
	.. "continued under a smaller context budget. Produce a CONCISE but COMPLETE summary that lets "
	.. "the agent continue the task from your summary ALONE. Capture: (1) the user's ORIGINAL request "
	.. "and overall goal, INCLUDING every multi-step instruction and any OUTSTANDING / not-yet-done "
	.. "step — quote the user's wording for unfinished steps so none are lost; (2) what has been built "
	.. "or changed, with exact instance paths, and which steps are DONE vs STILL TODO; (3) key "
	.. "decisions and constraints; (4) the current state and the immediate next step. The live "
	.. "DataModel is the source of truth for exact values — record intent and paths, not every "
	.. "property. Output only the summary."

local SUMMARY_MAX_TOKENS = 4096
local SUMMARY_PREFIX = "[Summary of the earlier conversation, condensed to save context:]\n"
local TRUNCATE_FALLBACK = "[The earlier conversation was dropped to fit the context window. "
	.. "Re-query the DataModel (get_tree/get_properties) for exact current state before continuing.]"

-- Walk the history in document order and collect a {parent, key} slot for every image block. Images
-- live inside tool_result content arrays (capture's result) or directly in a blocks array.
local function collectFromBlocks(blocks: { any }, slots: { { parent: any, key: any } })
	for i, block in ipairs(blocks) do
		if type(block) == "table" then
			if block.type == "image" then
				table.insert(slots, { parent = blocks, key = i })
			elseif block.type == "tool_result" and type(block.content) == "table" then
				collectFromBlocks(block.content, slots)
			end
		end
	end
end

function Compactor.collectImageSlots(messages: { any }): { { parent: any, key: any } }
	local slots: { { parent: any, key: any } } = {}
	for _, msg in ipairs(messages) do
		if type(msg) == "table" and type(msg.content) == "table" then
			collectFromBlocks(msg.content, slots)
		end
	end
	return slots
end

-- Replace every image block EXCEPT the most recent with a text note (in place). Returns how many
-- were dropped. Re-running is cheap and idempotent once only one image remains.
function Compactor.pruneImagesKeepingLast(messages: { any }): number
	local slots = Compactor.collectImageSlots(messages)
	if #slots <= 1 then
		return 0
	end
	for i = 1, #slots - 1 do
		local slot = slots[i]
		slot.parent[slot.key] = { type = "text", text = PRUNE_NOTE }
	end
	return #slots - 1
end

-- True when the last request's prompt size crossed window * threshold.
function Compactor.shouldCompact(lastPromptTokens: number, config: any): boolean
	if type(lastPromptTokens) ~= "number" or lastPromptTokens <= 0 then
		return false
	end
	return lastPromptTokens >= config:getContextWindow() * config:getCompactThreshold()
end

-- Choose the split index `j`: target n - keep + 1, then walk BACK to the nearest assistant turn so
-- the kept tail starts on an assistant (which makes `[user(summary)] ++ tail` alternate correctly and
-- never splits a tool_use/tool_result pair). Returns j (>= 1). Caller treats j <= 2 as "no-op".
function Compactor.chooseBoundary(messages: { any }, keepRecentMessages: number): number
	local n = #messages
	local j = math.max(1, n - keepRecentMessages + 1)
	while j > 1 and not (type(messages[j]) == "table" and messages[j].role == "assistant") do
		j -= 1
	end
	return j
end

-- Build the compacted history: a single user `summary` turn followed by messages[j..n] verbatim.
function Compactor.rebuildWithSummary(messages: { any }, j: number, summaryText: string): { any }
	local out: { any } = { { role = "user", content = summaryText } }
	for i = j, #messages do
		table.insert(out, messages[i])
	end
	return out
end

-- Classify a context-length rejection (so the loop compacts-and-retries instead of aborting).
function Compactor.isContextLengthError(res: any): boolean
	if type(res) ~= "table" or res.kind ~= "http" then
		return false
	end
	local msg = string.lower(tostring(res.message))
	return string.find(msg, "prompt is too long", 1, true) ~= nil
		or string.find(msg, "too long", 1, true) ~= nil
		or string.find(msg, "maximum context", 1, true) ~= nil
		or string.find(msg, "exceeds", 1, true) ~= nil
end

-- Summarize older turns and replace them in place, keeping the recent tail verbatim. Returns
-- (true, mode) on success ("summarized" or "truncated"), or (false, reason) when there is nothing
-- worth compacting. NEVER throws and NEVER leaves the history API-invalid.
function Compactor.compact(anthropic: any, config: any, conversation: any): (boolean, string)
	local messages = conversation.messages
	local j = Compactor.chooseBoundary(messages, config:getKeepRecentMessages())
	if j <= 2 then
		return false, "nothing to compact"
	end

	-- older = messages[1 .. j-1]; a valid prefix (starts user, ends user). Strip images for the
	-- summary call (their textual observations are already in the transcript) and ask the model to
	-- summarize. older ends on a user turn, so the model's reply IS the summary (an assistant turn).
	local older: { any } = {}
	for i = 1, j - 1 do
		table.insert(older, messages[i])
	end

	local summaryText = TRUNCATE_FALLBACK
	local mode = "truncated"
	local ok, res = pcall(function()
		return anthropic:sendMessage({
			system = SUMMARY_SYSTEM,
			messages = MessageUtil.stripImages(older),
			maxTokens = SUMMARY_MAX_TOKENS,
		})
	end)
	if ok and type(res) == "table" and res.ok and type(res.data) == "table" then
		local parts: { string } = {}
		if type(res.data.content) == "table" then
			for _, block in ipairs(res.data.content) do
				if
					type(block) == "table"
					and block.type == "text"
					and type(block.text) == "string"
				then
					table.insert(parts, block.text)
				end
			end
		end
		local text = table.concat(parts, "")
		if text ~= "" then
			summaryText = SUMMARY_PREFIX .. text
			mode = "summarized"
		end
	end

	local rebuilt = Compactor.rebuildWithSummary(messages, j, summaryText)
	-- Never install an API-invalid history. If the kept tail wasn't strictly alternating going in
	-- (e.g. a stray pause_turn double-assistant upstream), refuse rather than ship a guaranteed 400.
	if not MessageUtil.isValidHistory(rebuilt) then
		return false, "rebuild would be API-invalid"
	end
	conversation:replaceMessages(rebuilt)
	-- The compacted prompt is much smaller; clear the stale measurement so we don't immediately
	-- re-trigger before the next real send measures the new size.
	conversation.lastPromptTokens = 0
	return true, mode
end

return Compactor
