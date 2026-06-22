# Prioritized Learnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-category, global, high-priority **learnings** the agent records (a `learn` tool) that ride the always-on preamble and that `evaluate` folds into its grade prompt — so a lesson learned once (e.g. "locomotion builds fail without runtime foot IK") is applied on every later build. (§17 gap #6 — the loop that LEARNS.)

**Architecture:** A new `src/Learnings.luau` mirrors `src/Memory.luau`'s pure+instance pattern but is keyed by **category** (the rubric categories) and **global**, persisted one `SetSetting` key per category plus an index key. `learn`/`unlearn` tools wrap it; `AgentLoop` injects a "# Priority learnings" preamble block (after the rubric catalog + memory) and threads `learnings` into the tool context; `evaluate` folds the graded category's learnings into its grade prompt.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — verify with `selene`/`stylua`/`rojo build` (static) + an in-Studio `LearningsSpec` + a bridge dogfood (`scripts/studio-agent.ps1`) after a Studio restart.

**Source of truth:** [`docs/superpowers/specs/2026-06-21-studio-agent-prioritized-learnings-design.md`](../specs/2026-06-21-studio-agent-prioritized-learnings-design.md).

---

## Reference facts (from the codebase — do not re-derive)

- **Mirror `src/Memory.luau`**: it has pure helpers (`trim`, `truncate`, `normalizeText`, `addTo`, `forgetFrom`, `normalizeEntry`, `renderBucket`) + an instance (`new(plugin)`, `loadBucket`, `add`, `forget`, `list`, `clear`, `promptBlock`) persisted via `plugin:SetSetting`/`GetSetting`, with corrupt-blob defense (finite positive-integer id). `Tools/Memory.luau` wraps it (`remember`/`forget`), parent-only.
- **Wiring analogs to mirror exactly:** `src/init.server.luau` builds `deps` (incl. `memory = Memory.new(plugin)`, `rubrics = RubricStore.new()`). `src/AgentLoop.luau` builds the leading preamble (folding `deps.memory:promptBlock()` and the rubric catalog) and a tool `context` (carrying `memory`, `rubrics`, `config`, `anthropic`, …). `src/Tools/init.luau` registers a module's `descriptors`. `src/Relay.luau` `LOCAL_TOOLS` + `src/RelaySpec.luau` `EXPECTED_LOCAL` classify plugin-state-only tools as LOCAL (`remember`, `forget`, `use_rubric`, `evaluate` are LOCAL).
- **Tool Descriptor:** `{name, description, inputSchema, destructive, run}`.

---

## File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/Learnings.luau` | **new** | Category-keyed global learnings store: pure helpers + instance + `promptBlock`/`forCategory`. |
| `src/LearningsSpec.luau` | **new** | In-Studio pure self-test. |
| `src/Tools/Learnings.luau` | **new** | `learn` + `unlearn` tools. |
| `src/Tools/init.luau` | mod | Register `learn`/`unlearn`. |
| `src/init.server.luau` | mod | `deps.learnings = Learnings.new(plugin)`. |
| `src/AgentLoop.luau` | mod | Preamble "# Priority learnings" block + tool-context thread. |
| `src/Tools/Evaluate.luau` | mod | Fold the graded category's learnings into the grade prompt. |
| `src/SystemPrompt.luau` | mod | "# Priority learnings" guidance section. |
| `src/Relay.luau` / `src/RelaySpec.luau` | mod | Classify `learn`/`unlearn` LOCAL. |

---

## Task 1: `Learnings.luau` + pure spec

**Files:**
- Create: `src/Learnings.luau`
- Create: `src/LearningsSpec.luau`

- [ ] **Step 1: Write `src/Learnings.luau`**

```lua
--!strict
-- Learnings: per-CATEGORY, GLOBAL, high-priority quality-loop corrections the agent recalls automatically.
-- Distinct from Memory (this-game architecture / general global techniques): a learning is a confirmed lesson
-- for an asset CATEGORY (the rubric categories, e.g. "locomotion") -- "the grader fails builds without runtime
-- foot IK". The agent records via the learn tool AFTER evaluate catches a miss and it fixes it; learnings ride
-- the leading preamble as a "# Priority learnings (apply first)" block; evaluate folds the graded category's
-- learnings into its grade prompt. Persisted via plugin:SetSetting: one key per category
-- (StudioAgent_learnings_<category>) + an index key (the known category names) so promptBlock can enumerate
-- without scanning settings. Mirrors Memory's pure+instance split + corrupt-blob defense. DURABLE (writes go
-- straight to SetSetting; not rolled back with the conversation; the preamble carrying them is rebuilt per send
-- and is NOT in conversation.messages, so compaction never touches them).

local Learnings = {}
Learnings.__index = Learnings

export type Entry = { id: number, text: string, createdAt: number }

local MAX_PER_CATEGORY = 15
local MAX_TEXT = 280
local MAX_CATEGORIES = 24

Learnings.MAX_PER_CATEGORY = MAX_PER_CATEGORY
Learnings.MAX_TEXT = MAX_TEXT

local SETTING_PREFIX = "StudioAgent_"
local INDEX_KEY = SETTING_PREFIX .. "learnings_index"

export type Learnings = typeof(setmetatable(
	{} :: {
		_plugin: Plugin,
	},
	Learnings
))

-- ---- pure helpers (no self, no DataModel -- directly unit-testable) ----

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function truncate(s: string, maxChars: number): string
	local len = utf8.len(s)
	if len == nil then
		return string.sub(s, 1, maxChars)
	end
	if len <= maxChars then
		return s
	end
	local byteEnd = utf8.offset(s, maxChars + 1)
	if byteEnd == nil then
		return s
	end
	return string.sub(s, 1, byteEnd - 1)
end

-- Trim + UTF-8-safe truncate; nil if not a non-empty string.
function Learnings.normalizeText(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local t = trim(text)
	if t == "" then
		return nil
	end
	return truncate(t, MAX_TEXT)
end

-- Lowercase + trim a category; nil if empty/not a string. (Categories align with rubric.module names.)
function Learnings.normalizeCategory(name: any): string?
	if type(name) ~= "string" then
		return nil
	end
	local c = string.lower(trim(name))
	if c == "" then
		return nil
	end
	return c
end

-- Append a normalized entry (id = max existing + 1, createdAt = now). FIFO-drop oldest over MAX_PER_CATEGORY.
-- Returns (newEntries, note). Invalid text -> unchanged entries + an error note.
function Learnings.addTo(entries: { Entry }, text: any, now: number): ({ Entry }, string)
	local normalized = Learnings.normalizeText(text)
	if normalized == nil then
		return entries, "learn failed: text must be a non-empty string"
	end
	local maxId = 0
	for _, e in ipairs(entries) do
		if e.id > maxId then
			maxId = e.id
		end
	end
	local out: { Entry } = {}
	for _, e in ipairs(entries) do
		table.insert(out, e)
	end
	local newId = maxId + 1
	table.insert(out, { id = newId, text = normalized, createdAt = now })
	local dropped = 0
	while #out > MAX_PER_CATEGORY do
		table.remove(out, 1)
		dropped += 1
	end
	local note = "learned (#" .. tostring(newId) .. "); " .. tostring(#out) .. " stored"
	if dropped > 0 then
		note ..= "; dropped " .. tostring(dropped) .. " oldest (cap " .. tostring(MAX_PER_CATEGORY) .. ")"
	end
	return out, note
end

-- Remove the entry with the given id (coerced to a number). Returns (newEntries, removed).
function Learnings.forgetFrom(entries: { Entry }, id: any): ({ Entry }, boolean)
	local target = tonumber(id)
	local out: { Entry } = {}
	local removed = false
	for _, e in ipairs(entries) do
		if target ~= nil and e.id == target then
			removed = true
		else
			table.insert(out, e)
		end
	end
	return out, removed
end

-- Validate ONE raw stored item into an Entry, or nil. id must be a FINITE POSITIVE INTEGER (corrupt-blob defense).
function Learnings.normalizeEntry(raw: any): Entry?
	if type(raw) ~= "table" then
		return nil
	end
	local text = Learnings.normalizeText(raw.text)
	if text == nil then
		return nil
	end
	local id = raw.id
	if
		type(id) ~= "number"
		or id ~= id
		or id == math.huge
		or id == -math.huge
		or id <= 0
		or id ~= math.floor(id)
	then
		return nil
	end
	local createdAt = if type(raw.createdAt) == "number" then raw.createdAt else 0
	return { id = id, text = text, createdAt = createdAt }
end

-- Render one category's entries as "#<id> <text>" lines, or "(none)".
function Learnings.renderCategory(entries: { Entry }): string
	if #entries == 0 then
		return "(none)"
	end
	local lines: { string } = {}
	for _, e in ipairs(entries) do
		table.insert(lines, "#" .. tostring(e.id) .. " " .. e.text)
	end
	return table.concat(lines, "\n")
end

-- Normalize a raw index value into a clean, de-duped, capped list of category names.
function Learnings.normalizeIndex(raw: any): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(raw) == "table" then
		for _, n in ipairs(raw :: { any }) do
			local c = Learnings.normalizeCategory(n)
			if c ~= nil and not seen[c] then
				seen[c] = true
				table.insert(out, c)
				if #out >= MAX_CATEGORIES then
					break
				end
			end
		end
	end
	return out
end

-- ---- instance (live store) ----

function Learnings.new(plugin: Plugin): Learnings
	return setmetatable({ _plugin = plugin }, Learnings)
end

local function catKey(category: string): string
	return SETTING_PREFIX .. "learnings_" .. category
end

function Learnings.loadIndex(self: Learnings): { string }
	return Learnings.normalizeIndex(self._plugin:GetSetting(INDEX_KEY))
end

local function saveIndex(self: Learnings, names: { string })
	self._plugin:SetSetting(INDEX_KEY, Learnings.normalizeIndex(names))
end

-- Load one category's entries, re-normalizing defensively + capping to MAX_PER_CATEGORY (keep newest).
function Learnings.loadBucket(self: Learnings, category: string): { Entry }
	local raw = self._plugin:GetSetting(catKey(category))
	local out: { Entry } = {}
	if type(raw) == "table" then
		local seen: { [number]: boolean } = {}
		for _, e in ipairs(raw :: { any }) do
			local entry = Learnings.normalizeEntry(e)
			if entry ~= nil and not seen[entry.id] then
				seen[entry.id] = true
				table.insert(out, entry)
			end
		end
	end
	while #out > MAX_PER_CATEGORY do
		table.remove(out, 1)
	end
	return out
end

-- Add a learning under a category. Persists the bucket + ensures the category is in the index. Returns a note.
function Learnings.add(self: Learnings, category: any, text: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return "learn failed: category must be a non-empty string"
	end
	local entries = self:loadBucket(c)
	local updated, note = Learnings.addTo(entries, text, os.time())
	if #updated == #entries then
		-- nothing added (invalid text) -> don't touch storage/index
		return note .. " [" .. c .. "]"
	end
	self._plugin:SetSetting(catKey(c), updated)
	local index = self:loadIndex()
	local present = false
	for _, n in ipairs(index) do
		if n == c then
			present = true
			break
		end
	end
	if not present then
		table.insert(index, c)
		saveIndex(self, index)
	end
	return note .. " [" .. c .. "]"
end

-- Forget a learning by id under a category. Persists. Returns a confirmation.
function Learnings.forget(self: Learnings, category: any, id: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return "unlearn failed: category must be a non-empty string"
	end
	local entries = self:loadBucket(c)
	local updated, removed = Learnings.forgetFrom(entries, id)
	if not removed then
		return "no learning #" .. tostring(id) .. " in '" .. c .. "'"
	end
	self._plugin:SetSetting(catKey(c), updated)
	return "unlearned #" .. tostring(id) .. " [" .. c .. "]"
end

function Learnings.list(self: Learnings, category: any): { Entry }
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return {}
	end
	return self:loadBucket(c)
end

-- The category names that currently have at least one learning (index ∩ non-empty buckets).
function Learnings.categories(self: Learnings): { string }
	local out: { string } = {}
	for _, c in ipairs(self:loadIndex()) do
		if #self:loadBucket(c) > 0 then
			table.insert(out, c)
		end
	end
	return out
end

-- One category's rendered learnings (for evaluate's grade prompt). "" if none.
function Learnings.forCategory(self: Learnings, category: any): string
	local c = Learnings.normalizeCategory(category)
	if c == nil then
		return ""
	end
	local entries = self:loadBucket(c)
	if #entries == 0 then
		return ""
	end
	return Learnings.renderCategory(entries)
end

-- The always-on preamble block: ALL categories' learnings, grouped + capped. "" when none.
function Learnings.promptBlock(self: Learnings): string
	local cats = self:categories()
	if #cats == 0 then
		return ""
	end
	local parts: { string } = {
		"# Priority learnings (apply these first)",
		"Lessons you CONFIRMED in past builds, per asset category. When you build in one of these categories, "
			.. "apply its learnings FIRST -- they override your defaults. Use unlearn(category, id) to drop a "
			.. "stale one.",
	}
	for _, c in ipairs(cats) do
		table.insert(parts, "")
		table.insert(parts, "## " .. c)
		table.insert(parts, Learnings.renderCategory(self:loadBucket(c)))
	end
	return table.concat(parts, "\n")
end

return Learnings
```

- [ ] **Step 2: Write `src/LearningsSpec.luau`**

```lua
--!strict
-- LearningsSpec: in-Studio self-test for the PURE Learnings logic (no DataModel). Run via temporarily adding
-- `require(script.LearningsSpec).run()` to init.server.luau.

local Learnings = require(script.Parent.Learnings)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeCategory lowercases/trims and rejects empty", function()
		if Learnings.normalizeCategory("  Locomotion ") ~= "locomotion" then
			return false, "lower/trim failed"
		end
		if Learnings.normalizeCategory("") ~= nil or Learnings.normalizeCategory(5) ~= nil then
			return false, "empty/non-string not rejected"
		end
		return true
	end)

	add("addTo appends with incrementing id and FIFO-caps at MAX_PER_CATEGORY", function()
		local entries: { Learnings.Entry } = {}
		for i = 1, Learnings.MAX_PER_CATEGORY + 3 do
			entries = (Learnings.addTo(entries, "lesson " .. i, 100 + i))
		end
		if #entries ~= Learnings.MAX_PER_CATEGORY then
			return false, "cap failed: " .. tostring(#entries)
		end
		-- oldest dropped: first remaining is "lesson 4" (1..3 dropped), id continues upward
		if entries[1].text ~= "lesson 4" then
			return false, "FIFO drop wrong: " .. entries[1].text
		end
		if entries[#entries].id ~= Learnings.MAX_PER_CATEGORY + 3 then
			return false, "id scheme wrong: " .. tostring(entries[#entries].id)
		end
		return true
	end)

	add("addTo rejects empty text (entries unchanged)", function()
		local entries: { Learnings.Entry } = { { id = 1, text = "x", createdAt = 0 } }
		local out, note = Learnings.addTo(entries, "   ", 1)
		if #out ~= 1 or string.find(note, "non-empty", 1, true) == nil then
			return false, "empty text not rejected"
		end
		return true
	end)

	add("forgetFrom removes the matching id", function()
		local entries: { Learnings.Entry } =
			{ { id = 1, text = "a", createdAt = 0 }, { id = 2, text = "b", createdAt = 0 } }
		local out, removed = Learnings.forgetFrom(entries, 1)
		if not removed or #out ~= 1 or out[1].id ~= 2 then
			return false, "forget wrong"
		end
		return true
	end)

	add("normalizeEntry rejects a corrupt id", function()
		if Learnings.normalizeEntry({ id = -1, text = "x" }) ~= nil then
			return false, "negative id accepted"
		end
		if Learnings.normalizeEntry({ id = 1.5, text = "x" }) ~= nil then
			return false, "float id accepted"
		end
		if Learnings.normalizeEntry({ id = 2, text = "ok" }) == nil then
			return false, "valid entry rejected"
		end
		return true
	end)

	add("normalizeIndex de-dups + normalizes category names", function()
		local idx = Learnings.normalizeIndex({ "Locomotion", "locomotion", "  vfx ", "" })
		if #idx ~= 2 or idx[1] ~= "locomotion" or idx[2] ~= "vfx" then
			return false, "index normalize wrong: " .. table.concat(idx, ",")
		end
		return true
	end)

	add("renderCategory formats #id lines / (none)", function()
		if Learnings.renderCategory({}) ~= "(none)" then
			return false, "(none) wrong"
		end
		local r = Learnings.renderCategory({ { id = 3, text = "foo", createdAt = 0 } })
		if r ~= "#3 foo" then
			return false, "render wrong: " .. r
		end
		return true
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[LearningsSpec] PASS " .. c.name)
		else
			warn("[LearningsSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[LearningsSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static-verify** — `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done` (selene 0/0; build OK).

- [ ] **Step 4: Commit**

```bash
git add src/Learnings.luau src/LearningsSpec.luau
git commit -m "feat: Learnings store — per-category global quality-loop corrections (mirror Memory) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Tools/Learnings.luau` + register

**Files:**
- Create: `src/Tools/Learnings.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Learnings.luau`**

```lua
--!strict
-- Learnings tools: learn + unlearn. Thin wrappers over context.learnings (the per-category global quality
-- store). Parent-only: NOT in the subagent allowlist, and a child context carries no learnings, so they no-op
-- gracefully for a child. Non-destructive (no DataModel writes).

local Learnings = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function store(context: any): any
	return if type(context) == "table" then context.learnings else nil
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
	return s:add(args.category, args.text), false
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
	if tonumber(args.id) == nil then
		return "unlearn requires { category = <string>, id = <number> }", true
	end
	return s:forget(args.category, args.id), false
end

Learnings.descriptors = {
	{
		name = "learn",
		description = "Record a DURABLE per-category LESSON to apply on every future build in that category "
			.. "(it rides your context automatically next time, marked high-priority). Use it AFTER evaluate "
			.. "catches a miss and you FIX it, or after user feedback: capture the confirmed correction so you "
			.. "never repeat it. category is the asset category (e.g. 'locomotion', matching the rubric). Keep "
			.. "each lesson to one concise, general sentence (a reusable rule, not this one build's detail). "
			.. "This is for QUALITY-LOOP lessons; use remember for this game's architecture or general prefs.",
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
			.. "wrong or obsolete. Input: category + id.",
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
} :: { Descriptor }

return Learnings
```

- [ ] **Step 2: Register in `src/Tools/init.luau`** — add `local LearningsTool = require(script.Learnings)` near the other tool requires (e.g. after `MemoryTool`), and the descriptors loop:
```lua
for _, descriptor in LearningsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```
Append `learn, unlearn.` to the header comment's tool list.

- [ ] **Step 3: Static-verify** — `stylua src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Learnings.luau src/Tools/init.luau
git commit -m "feat: learn/unlearn tools over the Learnings store" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Wire into init.server + AgentLoop (deps + preamble + tool context)

**Files:**
- Modify: `src/init.server.luau`
- Modify: `src/AgentLoop.luau`

- [ ] **Step 1: `init.server.luau`** — `require` `Learnings` (mirror the `Memory`/`RubricStore` requires) and add `learnings = Learnings.new(plugin),` to the `deps` table (right after `memory = Memory.new(plugin),`).

- [ ] **Step 2: `AgentLoop.luau` — preamble** — find where the leading preamble is composed (the function that concatenates `SystemPrompt` + `deps.memory:promptBlock()` + the rubric catalog block; grep for `:promptBlock()` and `catalogBlock`). Add the learnings block **after** the rubric catalog block (so it reads as the most specific guidance), guarded like the others (only append when non-empty):
```lua
	local learningsBlock = if deps.learnings ~= nil then deps.learnings:promptBlock() else ""
	-- ... append learningsBlock to the preamble parts when learningsBlock ~= "" (mirror how the memory /
	-- rubric-catalog blocks are conditionally appended).
```
Mirror EXACTLY the existing conditional-append pattern used for `memory:promptBlock()` (same place, same `~= ""` guard, ordered after the rubric catalog).

- [ ] **Step 3: `AgentLoop.luau` — tool context** — find where the tool `context` table is built (it carries `memory`, `rubrics`, `config`, `anthropic`, …; grep for `rubrics =` / `memory =` in the context construction, threaded through `send`→`runLoop`→`toolContext`). Add `learnings = deps.learnings,` alongside `memory`/`rubrics` so `learn`/`unlearn` and `evaluate` reach it. (If `deps` is threaded as a whole, ensure `learnings` is present in the `deps` passed in — Step 1 covers that — and that the toolContext explicitly forwards it like `memory`.)

- [ ] **Step 4: Static-verify** — `stylua src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 5: Commit**

```bash
git add src/init.server.luau src/AgentLoop.luau
git commit -m "feat: thread learnings into deps + the leading preamble + the tool context" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `Evaluate.luau` — fold the category's learnings into the grade prompt

**Files:**
- Modify: `src/Tools/Evaluate.luau`

- [ ] **Step 1: Add the learnings block to the grade content** — in `runEvaluate` (after `local structural = gatherStructural(subject)` and before building `content`), gather the category's learnings and append a section:
```lua
	local learningsStore = if type(context) == "table" then context.learnings else nil
	local learned = if learningsStore ~= nil then (learningsStore :: any):forCategory(args.category) else ""
```
Then append to the `content` string (after the structural section):
```lua
		.. (if learned ~= ""
			then "\n\n=== ESTABLISHED LEARNINGS for this category (confirmed corrections to weight) ===\n"
				.. learned
			else "")
```
(So the grader is aware of the team's confirmed corrections for the category.) Do not change anything else.

- [ ] **Step 2: Static-verify** — `stylua src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 3: Commit**

```bash
git add src/Tools/Evaluate.luau
git commit -m "feat: evaluate folds the category's learnings into the grade prompt" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: SystemPrompt — Priority learnings section

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add the section** — immediately AFTER the "# Evaluating against the rubric (close the loop)" paragraph (added in the Evaluate slice), insert:
```
# Priority learnings (don't repeat mistakes)
Your context may include a "# Priority learnings (apply these first)" block — lessons you CONFIRMED in past builds, per asset category. When you build in one of those categories, apply its learnings FIRST; they override your defaults. After evaluate catches a miss in a rubric category and you FIX it (or after the user corrects you), call learn(category, <the durable, reusable lesson>) so you never repeat it — keep it one general sentence (a rule, not this build's specifics). Use unlearn(category, id) to drop a stale one. This is distinct from remember: learn is for per-category QUALITY-LOOP rules; remember is for this game's architecture and your general techniques/preferences.
```

- [ ] **Step 2: Static-verify** — `stylua src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 3: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "docs(prompt): Priority learnings section (record + apply per-category lessons)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Relay — classify `learn`/`unlearn` LOCAL

**Files:**
- Modify: `src/Relay.luau`
- Modify: `src/RelaySpec.luau`

- [ ] **Step 1: `Relay.luau`** — add `learn = true,` and `unlearn = true,` to `LOCAL_TOOLS` (alongside `remember`/`forget`/`use_rubric`/`evaluate`).

- [ ] **Step 2: `RelaySpec.luau`** — add `"learn",` and `"unlearn",` to `EXPECTED_LOCAL` (so the no-drift self-test stays green — it asserts every registered tool is classified).

- [ ] **Step 3: Static-verify** — `stylua src ; selene src ; rojo build … ; echo done`.

- [ ] **Step 4: Commit**

```bash
git add src/Relay.luau src/RelaySpec.luau
git commit -m "feat(relay): classify learn/unlearn as LOCAL (need the learnings dep, like remember)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full verify + bridge dogfood + HANDOFF

**Files:** `src/init.server.luau` (temporary spec require, reverted in Step 6); `HANDOFF.md`.

- [ ] **Step 1: Temporarily wire the spec** — in `src/init.server.luau`, add near the end:
```lua
require(script.LearningsSpec).run()
require(script.RelaySpec).run()
```

- [ ] **Step 2: Build + install + restart** — `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`; then the **USER restarts Studio** ("Restart to update") on a fresh Baseplate (the sidecar + bridge + tunnel are already running).

- [ ] **Step 3: Confirm specs + bridge** — `& scripts/studio-agent.ps1 logs` → expect `[LearningsSpec] 7/7 passed` and `RelaySpec ... N/N passed` and `dev bridge active`. (Invoke the CLI as `& scripts/studio-agent.ps1 …` from the PowerShell tool — a nested `powershell -File …` strips inner double-quotes.)

- [ ] **Step 4: Dogfood the learn → preamble → evaluate-folds-in → unlearn loop:**
```bash
& scripts/studio-agent.ps1 tool learn '{"category":"locomotion","text":"Owned velocity-driven blend + runtime foot IK are required; the grader fails builds without them."}'
& scripts/studio-agent.ps1 tool learn '{"category":"locomotion","text":"Add an additive aim layer at Action priority so the gait keeps running while aiming."}'
# Confirm they ride the preamble: read the rendered block directly:
& scripts/studio-agent.ps1 luau 'local L = nil for _,d in game:GetDescendants() do end return "use the panel/agent to confirm"'   # OR drive a prompt and confirm the agent cites the learnings
& scripts/studio-agent.ps1 tool evaluate '{"category":"locomotion","design":"one forward clip swapped by WalkSpeed, no IK, no aim"}'   # the grade prompt now includes the ESTABLISHED LEARNINGS section
& scripts/studio-agent.ps1 tool unlearn '{"category":"locomotion","id":1}'
```
Confirm: `learn` returns "learned (#1)…[locomotion]"; the two learnings appear in the always-on preamble (drive a `prompt` like "what priority learnings do you have?" and confirm the agent lists them — the cleanest end-to-end check, since the preamble isn't directly dumpable via a tool); `evaluate` still returns a structured report (and, ideally, references the established learnings); `unlearn` removes #1. (A direct preamble dump isn't exposed; the `prompt` path is the real verification that the block reaches the model.)

- [ ] **Step 5: (Recommended) adversarial review** — a code-review Workflow / subagents over `Learnings.luau` + the wiring (refute-biased); fix confirmed findings, re-verify.

- [ ] **Step 6: Revert the temporary spec require** — remove the two `require(...).run()` lines from `src/init.server.luau`; rebuild (`stylua ; selene ; rojo build`).

- [ ] **Step 7: Update HANDOFF.md + commit** — add a dated block: prioritized Learnings (§17 #6) shipped + bridge-verified (per-category global learn/unlearn; rides the preamble; evaluate folds them in). Commit.

```bash
git add HANDOFF.md src/init.server.luau
git commit -m "docs: prioritized Learnings shipped + bridge-verified; revert spec auto-run" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** dedicated `Learnings` store (pure+instance, category-keyed, global, capped, index) → Task 1; `learn`/`unlearn` tools → Task 2; deps + preamble + tool-context wiring → Task 3; evaluate folds learnings in → Task 4; SystemPrompt guidance → Task 5; LOCAL classification → Task 6; testing (pure spec + dogfood + adversarial review) → Tasks 1 + 7. All spec sections covered.
- **Placeholder scan:** the new files are complete code; Task 3's AgentLoop edits are described by mirroring the EXISTING `memory:promptBlock()` / tool-context pattern (the executor greps the two spots) rather than guessed line numbers — concrete and unambiguous, not a TBD.
- **Type/name consistency:** `Learnings.add/forget/list/categories/forCategory/promptBlock/loadBucket/loadIndex` + pure `normalizeText/normalizeCategory/addTo/forgetFrom/normalizeEntry/normalizeIndex/renderCategory` (Task 1) are called by `Tools/Learnings` (Task 2: `add`/`forget`), `AgentLoop` (Task 3: `promptBlock`), and `Evaluate` (Task 4: `forCategory`); the `learn`/`unlearn` tool names match across Tasks 2, 5, 6. `deps.learnings` (Task 1/3) ↔ `context.learnings` (Tasks 2, 4).
- **Encode safety:** no new tool has an empty `input_schema.properties` (both `learn`/`unlearn` have properties); the `encodeBody` sentinel is not involved.
```
