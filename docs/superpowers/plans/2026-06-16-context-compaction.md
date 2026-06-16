# Context-Window Auto-Compaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a long Studio Agent chat alive by auto-compacting history (summarize-and-replace + always-on image pruning) when it nears the model's context window, instead of dying with a "prompt is too long" error.

**Architecture:** Two mechanisms added around the existing `AgentLoop` tool loop. (1) `MessageUtil` holds pure message helpers (image stripping, token accounting, history-validity). (2) `Compactor` holds the policy: prune all-but-the-latest screenshot every iteration, and when the last request's prompt size crossed a threshold, replace older turns with one model-generated summary while keeping the recent tail verbatim and the history API-valid. The live DataModel remains the source of truth, so a lossy summary is safe.

**Tech Stack:** Luau (Roblox plugin, `--!strict`), rojo build, selene + stylua. Spec/tests are in-Studio self-test modules mirroring `src/SerializeSpec.luau`.

---

## Testing model (read first)

This repo cannot run Luau outside Studio. So:

- **Agent-runnable gates (run after every task):**
  ```powershell
  stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
  ```
  `selene` exits 1 on its one known `CreateDockWidgetPluginGui` deprecation warning — that is expected; "0 errors" is the pass condition. `rojo build` exit 0 = compiles.
- **Behavioral gate (run by the user in Studio):** the pure-logic modules are covered by `src/CompactorSpec.luau` (exports `M.run()` like `SerializeSpec`). To run it: temporarily add `require(script.CompactorSpec).run()` near the end of `src/init.server.luau`, `./build.ps1`, reopen Studio, read the Output window for `=== Summary: N/N passed ===`, then remove that line. The `CompactorSpec` cases use only plain tables/strings (no Roblox datatypes), so they fully validate prune + rebuild + validity logic.
- **Integration gate (`AgentLoop` wiring, not unit-testable without the network):** static gates above + an adversarial-review workflow (Task 8) + a user live long-chat test.

Commit after each task.

## File structure

- **Create `src/MessageUtil.luau`** — pure helpers: `stripImages`, `promptTokensFromUsage`, `isValidHistory`, `isToolResultTurn`, `hasToolUse`. No Roblox API beyond plain tables.
- **Create `src/Compactor.luau`** — policy: `collectImageSlots`, `pruneImagesKeepingLast`, `shouldCompact`, `chooseBoundary`, `rebuildWithSummary`, `isContextLengthError`, `compact`.
- **Create `src/CompactorSpec.luau`** — in-Studio self-test for `MessageUtil` + `Compactor` pure logic.
- **Modify `src/Conversation.luau`** — add `lastPromptTokens` field (reset on clear/load) + `replaceMessages` (in-place).
- **Modify `src/Config.luau`** — `contextWindow`, `compactThreshold`, `keepRecentMessages` (DEFAULTS + validation + getters).
- **Modify `src/Sessions.luau`** — use `MessageUtil.stripImages` instead of its local copy.
- **Modify `src/AgentLoop.luau`** — token tracking, per-iteration prune + proactive compact, reactive compact-and-retry, new `notice` emit.
- **Modify `src/UI/Widget.luau`** — render the `notice` event as a muted row.
- **Modify `src/SystemPrompt.luau`** — one line telling the agent old history may be summarized.

---

### Task 1: `MessageUtil` — pure message helpers + Sessions reuse

**Files:**
- Create: `src/MessageUtil.luau`
- Modify: `src/Sessions.luau:42-55` (replace local `stripImages` with the shared one)

- [ ] **Step 1: Create `src/MessageUtil.luau`**

```lua
--!strict
-- MessageUtil: pure helpers over Anthropic message arrays (no Roblox datatypes), shared by Sessions
-- (image stripping on save) and Compactor (token accounting, history-validity, pruning).
--
-- History invariants the loop relies on (the API 400s otherwise): the array starts on a `user` turn,
-- roles strictly alternate user/assistant, every assistant `tool_use` turn is followed by a `user`
-- turn whose content is a `tool_result` blocks array, and such a `tool_result` turn is always
-- preceded by its `tool_use` turn.

local MessageUtil = {}

-- True if `content` is a blocks ARRAY whose first block is a tool_result (a tool-result user turn).
function MessageUtil.isToolResultTurn(content: any): boolean
	return type(content) == "table"
		and type(content[1]) == "table"
		and content[1].type == "tool_result"
end

-- True if `content` is a blocks ARRAY containing at least one tool_use block (an assistant tool turn).
function MessageUtil.hasToolUse(content: any): boolean
	if type(content) ~= "table" then
		return false
	end
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "tool_use" then
			return true
		end
	end
	return false
end

-- Replace EVERY image block anywhere in `value` with a text placeholder. Non-mutating: returns a new
-- structure (the original is untouched). Used by Sessions (save) and Compactor (summary input).
function MessageUtil.stripImages(value: any, placeholder: string?): any
	local note = placeholder or "[screenshot omitted from saved history]"
	if type(value) ~= "table" then
		return value
	end
	if value.type == "image" then
		return { type = "text", text = note }
	end
	local out: { [any]: any } = {}
	for k, v in pairs(value) do
		out[k] = MessageUtil.stripImages(v, note)
	end
	return out
end

-- Sum the components of a Messages `usage` object that count against the context WINDOW (cached
-- components still occupy the window even though they cost less). Missing/absent -> 0.
function MessageUtil.promptTokensFromUsage(usage: any): number
	if type(usage) ~= "table" then
		return 0
	end
	local function n(x: any): number
		return if type(x) == "number" then x else 0
	end
	return n(usage.input_tokens)
		+ n(usage.cache_read_input_tokens)
		+ n(usage.cache_creation_input_tokens)
end

-- Check a history is Anthropic-API-valid. Returns (true) or (false, reason). An empty array is
-- treated as valid (no constraints to violate).
function MessageUtil.isValidHistory(messages: { any }): (boolean, string?)
	local n = #messages
	if n == 0 then
		return true
	end
	if type(messages[1]) ~= "table" or messages[1].role ~= "user" then
		return false, "history must start with a user turn"
	end
	for i = 1, n do
		local expected = if i % 2 == 1 then "user" else "assistant"
		if type(messages[i]) ~= "table" or messages[i].role ~= expected then
			return false, "roles must strictly alternate user/assistant starting with user (index " .. i .. ")"
		end
	end
	for i = 1, n do
		local msg = messages[i]
		if msg.role == "user" and MessageUtil.isToolResultTurn(msg.content) then
			local prev = messages[i - 1]
			if prev == nil or prev.role ~= "assistant" or not MessageUtil.hasToolUse(prev.content) then
				return false, "tool_result turn not preceded by an assistant tool_use turn (index " .. i .. ")"
			end
		end
		if msg.role == "assistant" and MessageUtil.hasToolUse(msg.content) then
			local nxt = messages[i + 1]
			if nxt == nil or nxt.role ~= "user" or not MessageUtil.isToolResultTurn(nxt.content) then
				return false, "assistant tool_use turn not followed by a tool_result user turn (index " .. i .. ")"
			end
		end
	end
	return true
end

return MessageUtil
```

- [ ] **Step 2: Point `Sessions` at the shared `stripImages`**

In `src/Sessions.luau`, add the require near the top (after the `HttpService` require, ~line 8):

```lua
local MessageUtil = require(script.Parent.MessageUtil)
```

Delete the local `stripImages` function (currently `src/Sessions.luau:42-55`):

```lua
-- Replace any image block anywhere in the messages with a text placeholder.
local function stripImages(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if value.type == "image" then
		return { type = "text", text = "[screenshot omitted from saved history]" }
	end
	local out: { [any]: any } = {}
	for k, v in pairs(value) do
		out[k] = stripImages(v)
	end
	return out
end
```

In `Sessions.save`, change the one call site from `stripImages(conversation.messages)` to:

```lua
		messages = MessageUtil.stripImages(conversation.messages),
```

(The default placeholder text is identical, so saved-session behavior is unchanged.)

- [ ] **Step 3: Static gates**

Run:
```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
Expected: stylua clean (exit 0), selene "0 errors", rojo build exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/MessageUtil.luau src/Sessions.luau
git commit -m "refactor: extract MessageUtil (stripImages, token accounting, history validity)"
```

---

### Task 2: `Config` knobs

**Files:**
- Modify: `src/Config.luau` (DEFAULTS ~line 13, validation ~line 100, getters ~line 190)

- [ ] **Step 1: Add the defaults**

In `src/Config.luau`, inside `DEFAULTS` (after `retryMaxDelay = 30.0,`), add:

```lua
	-- Context-window auto-compaction.
	contextWindow = 1000000, -- model window, tokens (claude-opus-4-8)
	compactThreshold = 0.8, -- compact when last prompt >= window * this (0 < x < 1)
	keepRecentMessages = 6, -- verbatim tail length kept when compacting
```

- [ ] **Step 2: Add validation**

In `Config.set`, add these branches (e.g. right after the `retryMaxDelay` branch, before the final `self._plugin:SetSetting`):

```lua
	elseif key == "contextWindow" then
		if type(value) ~= "number" or value ~= value or value < 1000 then
			return false, "contextWindow must be a number >= 1000"
		end
		value = math.floor(value)
	elseif key == "compactThreshold" then
		if type(value) ~= "number" or value ~= value or value <= 0 or value >= 1 then
			return false, "compactThreshold must be a number in (0, 1)"
		end
	elseif key == "keepRecentMessages" then
		if type(value) ~= "number" or value ~= value or value < 2 then
			return false, "keepRecentMessages must be a number >= 2"
		end
		value = math.floor(value)
```

- [ ] **Step 3: Add getters**

Near the other convenience getters (after `getMaxIterations`), add:

```lua
function Config.getContextWindow(self: Config): number
	return self:get("contextWindow") :: number
end

function Config.getCompactThreshold(self: Config): number
	return self:get("compactThreshold") :: number
end

function Config.getKeepRecentMessages(self: Config): number
	return self:get("keepRecentMessages") :: number
end
```

- [ ] **Step 4: Static gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Config.luau
git commit -m "feat: config knobs for context-window auto-compaction"
```

---

### Task 3: `Conversation` — token memory + in-place replace

**Files:**
- Modify: `src/Conversation.luau`

- [ ] **Step 1: Add the field to the type + constructor**

Change the type block:

```lua
export type Conversation = typeof(setmetatable(
	{} :: {
		messages: { any },
		title: string,
		lastPromptTokens: number,
	},
	Conversation
))
```

Change `Conversation.new`:

```lua
function Conversation.new(): Conversation
	return setmetatable({ messages = {}, title = "", lastPromptTokens = 0 }, Conversation)
end
```

- [ ] **Step 2: Reset the token memory on clear/load**

In `Conversation.clear`, add `self.lastPromptTokens = 0`:

```lua
function Conversation.clear(self: Conversation)
	table.clear(self.messages)
	self.title = ""
	self.lastPromptTokens = 0
end
```

In `Conversation.load`, add `self.lastPromptTokens = 0`:

```lua
function Conversation.load(self: Conversation, title: string, messages: { any })
	self.title = title
	self.messages = messages
	self.lastPromptTokens = 0
end
```

- [ ] **Step 3: Add in-place `replaceMessages`**

Add after `truncate`:

```lua
-- Replace the message list IN PLACE (clear + refill the same table) so existing references to
-- `conversation.messages` (e.g. the running loop's local) stay valid after a compaction.
function Conversation.replaceMessages(self: Conversation, new: { any })
	table.clear(self.messages)
	for _, m in ipairs(new) do
		table.insert(self.messages, m)
	end
end
```

- [ ] **Step 4: Static gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/Conversation.luau
git commit -m "feat: Conversation tracks lastPromptTokens + in-place replaceMessages"
```

---

### Task 4: `Compactor` — pure logic (prune, boundary, rebuild, classify)

This task adds everything in `Compactor` EXCEPT the model-calling `compact` (Task 5), so the pure logic can be tested first.

**Files:**
- Create: `src/Compactor.luau`

- [ ] **Step 1: Create `src/Compactor.luau` (pure functions only)**

```lua
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

return Compactor
```

- [ ] **Step 2: Create `src/CompactorSpec.luau` (in-Studio self-test)**

```lua
--!strict
-- CompactorSpec: in-Studio self-test for the PURE compaction logic (MessageUtil + Compactor). Run
-- via: temporarily add `require(script.CompactorSpec).run()` to init.server.luau, build, reopen
-- Studio, read Output. Cases use only plain tables/strings (no Roblox datatypes).

local MessageUtil = require(script.Parent.MessageUtil)
local Compactor = require(script.Parent.Compactor)

local M = {}

-- Build a synthetic VALID history of `pairs` tool exchanges after the opening user text turn:
--   user(text), [assistant(tool_use), user(tool_result)] * pairs
-- Always ends on a user(tool_result) turn (like the loop at a Send). withImageAt: list of exchange
-- indices (1-based) whose tool_result carries an image block.
local function buildHistory(pairsCount: number, withImageAt: { number }?): { any }
	local imageSet: { [number]: boolean } = {}
	for _, idx in ipairs(withImageAt or {}) do
		imageSet[idx] = true
	end
	local m: { any } = { { role = "user", content = "build a thing" } }
	for k = 1, pairsCount do
		table.insert(m, {
			role = "assistant",
			content = { { type = "tool_use", id = "t" .. k, name = "get_tree", input = {} } },
		})
		local resultContent: any
		if imageSet[k] then
			resultContent = { { type = "image", source = { type = "base64", media_type = "image/png", data = "AAAA" } } }
		else
			resultContent = "ok " .. k
		end
		table.insert(m, {
			role = "user",
			content = { { type = "tool_result", tool_use_id = "t" .. k, content = resultContent, is_error = false } },
		})
	end
	return m
end

type Case = { name: string, fn: () -> (boolean, string?) }

local function countImages(messages: { any }): number
	return #Compactor.collectImageSlots(messages)
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("buildHistory is itself valid", function()
		local ok, reason = MessageUtil.isValidHistory(buildHistory(3))
		return ok, reason
	end)

	add("isValidHistory rejects starting on assistant", function()
		local bad = { { role = "assistant", content = "x" }, { role = "user", content = "y" } }
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("isValidHistory rejects non-alternating", function()
		local bad = { { role = "user", content = "a" }, { role = "user", content = "b" } }
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("isValidHistory rejects dangling tool_result", function()
		local bad = {
			{ role = "user", content = "a" },
			{ role = "assistant", content = "plain text, no tool_use" },
			{ role = "user", content = { { type = "tool_result", tool_use_id = "z", content = "x" } } },
		}
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("promptTokensFromUsage sums components", function()
		local got = MessageUtil.promptTokensFromUsage({
			input_tokens = 10,
			cache_read_input_tokens = 5,
			cache_creation_input_tokens = 2,
		})
		return got == 17, "got " .. tostring(got)
	end)

	add("promptTokensFromUsage tolerates missing fields", function()
		return MessageUtil.promptTokensFromUsage({ input_tokens = 4 }) == 4
			and MessageUtil.promptTokensFromUsage(nil) == 0
	end)

	add("pruneImagesKeepingLast keeps exactly the last image", function()
		local m = buildHistory(4, { 1, 2, 4 })
		local dropped = Compactor.pruneImagesKeepingLast(m)
		if dropped ~= 2 then
			return false, "dropped " .. tostring(dropped) .. " expected 2"
		end
		if countImages(m) ~= 1 then
			return false, "images left " .. tostring(countImages(m))
		end
		local ok, reason = MessageUtil.isValidHistory(m)
		return ok, reason
	end)

	add("pruneImagesKeepingLast is a no-op at 0 or 1 image", function()
		local m0 = buildHistory(3)
		local m1 = buildHistory(3, { 2 })
		return Compactor.pruneImagesKeepingLast(m0) == 0
			and Compactor.pruneImagesKeepingLast(m1) == 0
			and countImages(m1) == 1
	end)

	add("chooseBoundary lands on an assistant turn", function()
		local m = buildHistory(10) -- length 21, ends on user
		local j = Compactor.chooseBoundary(m, 6)
		return m[j] ~= nil and m[j].role == "assistant", "j=" .. tostring(j)
	end)

	add("compacted history is API-valid and starts with the summary", function()
		local m = buildHistory(10)
		local j = Compactor.chooseBoundary(m, 6)
		local rebuilt = Compactor.rebuildWithSummary(m, j, "[summary] goal: build a thing")
		if rebuilt[1].role ~= "user" or type(rebuilt[1].content) ~= "string" then
			return false, "first turn is not the user summary"
		end
		if rebuilt[#rebuilt].role ~= "user" then
			return false, "must end on a user turn"
		end
		local ok, reason = MessageUtil.isValidHistory(rebuilt)
		return ok, reason
	end)

	add("isContextLengthError matches a prompt-too-long 400", function()
		local hit = Compactor.isContextLengthError({ kind = "http", status = 400, message = "prompt is too long: 1.2M tokens" })
		local miss = Compactor.isContextLengthError({ kind = "http", status = 429, message = "overloaded" })
		return hit == true and miss == false
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== CompactorSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print("=== Summary: " .. tostring(passed) .. "/" .. tostring(total) .. " passed, " .. tostring(failed) .. " failed ===")
	return { passed = failed == 0, total = total, failed = failed }
end

return M
```

- [ ] **Step 3: Static gates**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
Expected: stylua clean, selene "0 errors", rojo build exit 0.

- [ ] **Step 4: Run the spec in Studio (user)**

Temporarily append to `src/init.server.luau` just before the final `print(...)`:
```lua
require(script.CompactorSpec).run()
```
Then `./build.ps1`, reopen Studio, and read Output. Expected: `=== Summary: 11/11 passed, 0 failed ===`. Remove the temporary line afterward and rebuild.

- [ ] **Step 5: Commit**

```bash
git add src/Compactor.luau src/CompactorSpec.luau
git commit -m "feat: Compactor pure logic (prune, boundary, rebuild, classify) + CompactorSpec"
```

---

### Task 5: `Compactor.compact` — the summarize-and-replace model call

**Files:**
- Modify: `src/Compactor.luau` (add `compact` + summary prompt)

- [ ] **Step 1: Add the summary system prompt + `compact`**

Add near the top of `src/Compactor.luau` (after `PRUNE_NOTE`):

```lua
local SUMMARY_SYSTEM = "You are compacting a long Roblox Studio build conversation so it can be "
	.. "continued under a smaller context budget. Read the conversation and produce a CONCISE but "
	.. "COMPLETE summary capturing: (1) the user's goal; (2) what has been built or changed, with "
	.. "exact instance paths; (3) key decisions and constraints; (4) the current state; (5) the "
	.. "immediate next step. The live DataModel is the source of truth for exact values — record "
	.. "intent and paths, not every property. Output only the summary."

local SUMMARY_MAX_TOKENS = 4096
local SUMMARY_PREFIX = "[Summary of the earlier conversation, condensed to save context:]\n"
local TRUNCATE_FALLBACK = "[The earlier conversation was dropped to fit the context window. "
	.. "Re-query the DataModel (get_tree/get_properties) for exact current state before continuing.]"
```

Add `compact` before `return Compactor`:

```lua
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
	local ok, res = pcall(function()
		return anthropic:sendMessage({
			system = SUMMARY_SYSTEM,
			messages = MessageUtil.stripImages(older),
			maxTokens = SUMMARY_MAX_TOKENS,
		})
	end)
	local mode = "truncated"
	if ok and type(res) == "table" and res.ok and type(res.data) == "table" then
		local parts: { string } = {}
		if type(res.data.content) == "table" then
			for _, block in ipairs(res.data.content) do
				if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
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
	conversation:replaceMessages(rebuilt)
	-- The compacted prompt is much smaller; clear the stale measurement so we don't immediately
	-- re-trigger before the next real send measures the new size.
	conversation.lastPromptTokens = 0
	return true, mode
end
```

- [ ] **Step 2: Static gates**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```

- [ ] **Step 3: Commit**

```bash
git add src/Compactor.luau
git commit -m "feat: Compactor.compact summarize-and-replace (with truncation fallback)"
```

---

### Task 6: `AgentLoop` integration

**Files:**
- Modify: `src/AgentLoop.luau`

- [ ] **Step 1: Require the new modules**

At the top (after `local Tools = require(script.Parent.Tools)`):

```lua
local Compactor = require(script.Parent.Compactor)
local MessageUtil = require(script.Parent.MessageUtil)
```

- [ ] **Step 2: Prune + proactive compaction at the top of each iteration**

In `runLoop`, the loop body currently begins:

```lua
	for i = 1, maxIter do
		if cancelled() then
			conversation:truncate(snapshot)
			emit("done", { stop = "cancelled" })
			return
		end
		emit("iteration", { n = i, max = maxIter })

		local res = sendWithRetry(
```

Replace from `emit("iteration", ...)` down through the send + error handling. New body:

```lua
		emit("iteration", { n = i, max = maxIter })

		-- Always-on: keep only the most recent screenshot in live context.
		Compactor.pruneImagesKeepingLast(messages)
		-- Proactive: if the last prompt crossed the threshold, compact before sending.
		if Compactor.shouldCompact(conversation.lastPromptTokens, config) then
			emit("status", "compacting context…")
			local didCompact = Compactor.compact(anthropic, config, conversation)
			if didCompact then
				emit("notice", "[compacted earlier history to free context]")
			end
		end

		-- Send, with a one-shot reactive compaction if we still overflow the window.
		local res
		local compactedReactively = false
		while true do
			res = sendWithRetry(
				anthropic,
				config,
				{ messages = messages, tools = tools, system = systemPrompt },
				emit,
				cancelled
			)
			if res.ok then
				break
			end
			if Compactor.isContextLengthError(res) and not compactedReactively then
				compactedReactively = true
				emit("status", "context full — compacting and retrying…")
				local didCompact = Compactor.compact(anthropic, config, conversation)
				if didCompact then
					emit("notice", "[compacted earlier history to free context]")
				else
					abort(res.kind, res.message)
					return
				end
			else
				abort(res.kind, res.message)
				return
			end
		end
```

Notes for the implementer: `compact` mutates `conversation.messages` IN PLACE (`replaceMessages`), so the existing `local messages = conversation.messages` reference stays valid — do NOT re-bind it. Leave the code AFTER this block (the `local data = res.data` validity check onward) unchanged.

- [ ] **Step 3: Record the prompt size after a successful send**

Immediately after the `data` validity check:

```lua
		local data = res.data
		if type(data) ~= "table" or type(data.content) ~= "table" then
			abort("protocol", "response had no content array")
			return
		end
		conversation.lastPromptTokens = MessageUtil.promptTokensFromUsage(data.usage)
```

- [ ] **Step 4: Static gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/AgentLoop.luau
git commit -m "feat: wire auto-compaction into the agent loop (prune + proactive + reactive)"
```

---

### Task 7: UI notice + system-prompt note

**Files:**
- Modify: `src/UI/Widget.luau` (the `onEvent` handler)
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Render the `notice` event as a muted row**

In `src/UI/Widget.luau`, in the `onEvent` handler, add a branch (e.g. after the `status` branch):

```lua
						elseif event == "notice" then
							addRow(MUTED, tostring(data))
```

- [ ] **Step 2: Tell the agent its history may be summarized**

In `src/SystemPrompt.luau`, add to the `# Working rules` list (near the end of `BASE`):

```lua
- For very long sessions your earlier turns may be automatically summarized to fit the context window. Don't rely on remembering every detail verbatim — re-query the DataModel (get_tree / get_properties / search) for exact current state when it matters.
```

- [ ] **Step 3: Static gates + commit**

```powershell
stylua src ; stylua --check src ; selene src ; rojo build default.project.json -o StudioAgent.rbxm
```
```bash
git add src/UI/Widget.luau src/SystemPrompt.luau
git commit -m "feat: surface compaction notice in the panel + prompt note"
```

---

### Task 8: Verification

- [ ] **Step 1: Full static gates + install**

```powershell
stylua --check src ; selene src ; ./build.ps1
```
Expected: stylua clean, selene "0 errors", installed to the Plugins folder.

- [ ] **Step 2: Re-run `CompactorSpec` in Studio (user)**

Temporarily wire `require(script.CompactorSpec).run()` in `init.server.luau`, build, reopen Studio, confirm `=== Summary: 11/11 passed, 0 failed ===`, then remove it.

- [ ] **Step 3: Adversarial review workflow**

Run a `Workflow` reviewing the diff for: history-invariant correctness after compaction (alternation, tool pairing, ends on user), the in-place `messages` reference staying valid after `compact`, token accounting, reactive-retry bounding (exactly one compaction per send, no infinite loop), and the image-prune walker's document ordering. Fix any confirmed findings.

- [ ] **Step 4: Live test (user)**

Run a long vision chat (repeated build→capture→adjust). Lower `compactThreshold` temporarily (e.g. set `StudioAgent_compactThreshold` to a small value, or shrink `contextWindow`) to force an early compaction, and confirm: the panel shows `[compacted earlier history to free context]`, the chat continues correctly afterward, and no "prompt is too long" error occurs.

- [ ] **Step 5: Update HANDOFF + memory**

Mark context-compaction done in `HANDOFF.md` and the `studio-agent-status` memory; note subagents (feature #2) is next.

---

## Self-review notes

- **Spec coverage:** image pruning (Task 4/6), token accounting (Task 1/6), proactive trigger (Task 6), reactive trigger (Task 6), rebuild invariants (Task 4 + CompactorSpec), summary call + truncation fallback (Task 5), config knobs (Task 2), UX notice (Task 7), CompactorSpec test (Task 4), Sessions reuse (Task 1) — all mapped.
- **Type consistency:** `lastPromptTokens` (Conversation field) used in Task 5/6; `replaceMessages` (Task 3) called in Task 5; `getContextWindow`/`getCompactThreshold`/`getKeepRecentMessages` (Task 2) used in Task 4/5; `promptTokensFromUsage`/`stripImages`/`isValidHistory` (Task 1) used in Task 4/5/6 and the spec — names match across tasks.
- **In-place mutation invariant:** `compact` must use `conversation:replaceMessages` (not `conversation.messages = …`) so the loop's `local messages` stays valid — called out in Task 6 Step 2.
```
