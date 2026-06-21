# Evaluate Tool (Slice E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `evaluate` tool that grades a built locomotion system against the delivered Locomotion rubric and returns a structured, per-criterion report (tier + cited evidence + concrete fix) the agent uses to refine — closing the capture→evaluate→refine loop.

**Architecture:** A pure `EvaluateReport` module (build the forced grade tool, validate the model's structured output, render the report) + a structured-output path in `Anthropic.luau` (force a single `submit_grade` tool via `tool_choice`, fall back to prose-parse) + the `evaluate` tool that gathers evidence (DataModel structural dump + the agent's design claim) and orchestrates resolve→gather→grade→report. The judge weights verifiable structural evidence over unverified claims.

**Tech Stack:** Luau (`--!strict`), Roblox Studio plugin. **No local Luau execution** — verification is `selene`/`stylua`/`rojo build` (static) + a **bridge dogfood** (`scripts/studio-agent.ps1`) after a Studio restart, plus an in-Studio `EvaluateReportSpec`.

**Source of truth:** [`docs/superpowers/specs/2026-06-21-studio-agent-evaluate-tool-design.md`](../specs/2026-06-21-studio-agent-evaluate-tool-design.md).

---

## Reference facts (from the codebase — do not re-derive)

- `RubricCatalog` (`src/RubricCatalog.luau`) exports types `Rubric = {module, version, system_module, criteria: {Criterion}}` and `Criterion = {id, order_index, tier, statement, above_generic_rationale, grading{pass,partial,fail}, evidence_required, concrete_fix, exemplar_refs}`; helpers `findByCategory(rubrics, category) -> Rubric?` and `render(rubric) -> string`.
- `RubricStore` (`context.rubrics`) has `:all() -> {Rubric}`.
- `Anthropic` (`context.anthropic`): `sendMessage(opts: SendOpts) -> Result`. `SendOpts = {messages, model?, maxTokens?, system?, tools?}`. `Result = {ok, data, kind?, status?, message?}`; on success `data.content` is the block array (a `tool_use` block carries `.input`).
- `Path.resolve(path) -> (Instance?, string?)` (`src/Tools/Path.luau`).
- A tool Descriptor: `{name, description, inputSchema, destructive, run}`; registered by appending its module's `descriptors` in `src/Tools/init.luau`.
- Killer-system criteria contain the literal `KILLER SYSTEM` in their `statement`.

---

## File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/EvaluateReport.luau` | **new** | Pure: `buildGradeTool`, `validateGrades`, `renderReport` + helpers. |
| `src/EvaluateReportSpec.luau` | **new** | In-Studio self-test for the pure report logic. |
| `src/Anthropic.luau` | mod | `toolChoice` in `SendOpts`/`sendMessage`; `requestStructured(opts)` (forced tool + text fallback). |
| `src/Tools/Evaluate.luau` | **new** | The `evaluate` tool: evidence dump + grade orchestration + JSON-from-text fallback. |
| `src/Tools/init.luau` | mod | Register `evaluate`. |
| `src/SystemPrompt.luau` | mod | "# Evaluating against the rubric" section. |
| `src/Relay.luau` / `src/RelaySpec.luau` | mod | Classify `evaluate` LOCAL. |

---

## Task 1: `EvaluateReport.luau` (pure) + spec

**Files:**
- Create: `src/EvaluateReport.luau`
- Create: `src/EvaluateReportSpec.luau`

- [ ] **Step 1: Write `src/EvaluateReport.luau`**

```lua
--!strict
-- EvaluateReport: PURE helpers for the Evaluate tool (no DataModel, no services — directly unit-testable).
-- buildGradeTool turns a Rubric into the forced `submit_grade` tool (schema = one grade per criterion);
-- validateGrades coerces the model's structured output to the rubric's criteria (missing -> "ungraded");
-- renderReport turns validated grades into a readable, fails-first report citing each criterion's concrete_fix.

local RubricCatalog = require(script.Parent.RubricCatalog)

type Rubric = RubricCatalog.Rubric

local EvaluateReport = {}

export type Grade = { id: string, tier: string, towardFull: boolean, evidence: string, gap: string }
export type Validated = { grades: { Grade }, summary: string }

local ALLOWED_TIER: { [string]: boolean } = { fail = true, partial = true, pass = true }
local TIER_GLYPH: { [string]: string } =
	{ pass = "PASS", partial = "PARTIAL", fail = "FAIL", ungraded = "?" }
-- fails first, then partial, then ungraded, then pass
local TIER_RANK: { [string]: number } = { fail = 0, partial = 1, ungraded = 2, pass = 3 }

-- The forced grading tool: the model MUST call submit_grade with one entry per criterion id.
function EvaluateReport.buildGradeTool(rubric: Rubric): { [string]: any }
	local ids: { string } = {}
	for _, c in ipairs(rubric.criteria) do
		table.insert(ids, c.id)
	end
	return {
		name = "submit_grade",
		description = "Submit the per-criterion grade for this rubric. Provide EXACTLY one entry per "
			.. "criterion id; tier is fail|partial|pass; cite the specific evidence; set towardFull only "
			.. "when the exceptional/ceiling extras are also met.",
		input_schema = {
			type = "object",
			properties = {
				grades = {
					type = "array",
					description = "One grade per rubric criterion.",
					items = {
						type = "object",
						properties = {
							id = { type = "string", enum = ids, description = "The rubric criterion id." },
							tier = {
								type = "string",
								enum = { "fail", "partial", "pass" },
								description = "fail | partial | pass against the criterion's Pass definition.",
							},
							towardFull = {
								type = "boolean",
								description = "True if the exceptional/ceiling extras are also met.",
							},
							evidence = {
								type = "string",
								description = "The specific structural/design/visual evidence justifying the tier.",
							},
							gap = {
								type = "string",
								description = "What is missing to reach pass / full marks ('' if pass+towardFull).",
							},
						},
						required = { "id", "tier", "evidence" },
					},
				},
				summary = { type = "string", description = "A 1-2 sentence overall read." },
			},
			required = { "grades", "summary" },
		},
	}
end

-- Coerce the model's raw structured output to one Grade per rubric criterion (in rubric order). Total.
function EvaluateReport.validateGrades(raw: any, rubric: Rubric): Validated
	local byId: { [string]: Grade } = {}
	if type(raw) == "table" and type(raw.grades) == "table" then
		for _, g in ipairs(raw.grades :: { any }) do
			if type(g) == "table" and type(g.id) == "string" then
				local tier = if type(g.tier) == "string" and ALLOWED_TIER[g.tier] then g.tier else "ungraded"
				byId[g.id] = {
					id = g.id,
					tier = tier,
					towardFull = g.towardFull == true,
					evidence = if type(g.evidence) == "string" then g.evidence else "",
					gap = if type(g.gap) == "string" then g.gap else "",
				}
			end
		end
	end
	local out: { Grade } = {}
	for _, c in ipairs(rubric.criteria) do
		out[#out + 1] = byId[c.id]
			or { id = c.id, tier = "ungraded", towardFull = false, evidence = "", gap = "" }
	end
	local summary = if type(raw) == "table" and type(raw.summary) == "string" then raw.summary else ""
	return { grades = out, summary = summary }
end

-- Render a fails-first report citing each criterion's concrete_fix (the rubric owns the fix).
function EvaluateReport.renderReport(rubric: Rubric, validated: Validated): string
	local critById: { [string]: RubricCatalog.Criterion } = {}
	for _, c in ipairs(rubric.criteria) do
		critById[c.id] = c
	end
	local counts: { [string]: number } = { pass = 0, partial = 0, fail = 0, ungraded = 0 }
	for _, g in ipairs(validated.grades) do
		counts[g.tier] = (counts[g.tier] or 0) + 1
	end
	local total = #validated.grades
	local lines: { string } = {
		string.format(
			"Evaluation: %s (v%s) — %d/%d pass, %d partial, %d fail%s",
			rubric.module,
			rubric.version,
			counts.pass,
			total,
			counts.partial,
			counts.fail,
			if counts.ungraded > 0 then string.format(", %d ungraded", counts.ungraded) else ""
		),
	}
	if validated.summary ~= "" then
		table.insert(lines, validated.summary)
	end
	-- killer-systems one-liner
	local gradeById: { [string]: Grade } = {}
	for _, g in ipairs(validated.grades) do
		gradeById[g.id] = g
	end
	local killers: { string } = {}
	for _, c in ipairs(rubric.criteria) do
		if string.find(c.statement, "KILLER SYSTEM", 1, true) ~= nil then
			local g = gradeById[c.id]
			table.insert(killers, c.id .. "=" .. TIER_GLYPH[if g then g.tier else "ungraded"])
		end
	end
	if #killers > 0 then
		table.insert(lines, "Killer systems: " .. table.concat(killers, ", "))
	end
	-- fails-first detail
	local order: { Grade } = {}
	for _, g in ipairs(validated.grades) do
		table.insert(order, g)
	end
	table.sort(order, function(a, b)
		return (TIER_RANK[a.tier] or 2) < (TIER_RANK[b.tier] or 2)
	end)
	for _, g in ipairs(order) do
		local c = critById[g.id]
		table.insert(lines, "")
		table.insert(lines, string.format("[%s] %s", TIER_GLYPH[g.tier] or "?", g.id))
		if g.evidence ~= "" then
			table.insert(lines, "  evidence: " .. g.evidence)
		end
		if g.tier ~= "pass" or not g.towardFull then
			if g.gap ~= "" then
				table.insert(lines, "  gap: " .. g.gap)
			end
			if c ~= nil and c.concrete_fix ~= "" then
				table.insert(lines, "  fix: " .. c.concrete_fix)
			end
		end
	end
	return table.concat(lines, "\n")
end

return EvaluateReport
```

- [ ] **Step 2: Write `src/EvaluateReportSpec.luau`**

```lua
--!strict
-- EvaluateReportSpec: in-Studio self-test for the PURE EvaluateReport logic. Run via temporarily adding
-- `require(script.EvaluateReportSpec).run()` to init.server.luau.

local EvaluateReport = require(script.Parent.EvaluateReport)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

-- A tiny synthetic rubric (2 criteria; one is a KILLER SYSTEM) for the pure tests.
local RUBRIC = {
	module = "test",
	version = "1",
	system_module = "test",
	criteria = {
		{
			id = "c-base",
			order_index = 1,
			tier = "baseline",
			statement = "A baseline thing.",
			above_generic_rationale = "",
			grading = { pass = "p", partial = "pa", fail = "f" },
			evidence_required = "",
			concrete_fix = "do the base fix",
			exemplar_refs = {},
		},
		{
			id = "c-killer",
			order_index = 2,
			tier = "good",
			statement = "KILLER SYSTEM — a big one.",
			above_generic_rationale = "",
			grading = { pass = "p", partial = "pa", fail = "f" },
			evidence_required = "",
			concrete_fix = "do the killer fix",
			exemplar_refs = {},
		},
	},
}

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("buildGradeTool exposes the criterion ids as the id enum", function()
		local tool = EvaluateReport.buildGradeTool(RUBRIC :: any)
		if tool.name ~= "submit_grade" then
			return false, "wrong tool name"
		end
		local idEnum = tool.input_schema.properties.grades.items.properties.id.enum
		if type(idEnum) ~= "table" or idEnum[1] ~= "c-base" or idEnum[2] ~= "c-killer" then
			return false, "id enum missing the criterion ids"
		end
		return true
	end)

	add("validateGrades fills missing criteria as ungraded and clamps bad tiers", function()
		local raw = { grades = { { id = "c-base", tier = "bogus", evidence = "e" } }, summary = "s" }
		local v = EvaluateReport.validateGrades(raw, RUBRIC :: any)
		if #v.grades ~= 2 then
			return false, "expected 2 grades, got " .. tostring(#v.grades)
		end
		if v.grades[1].id ~= "c-base" or v.grades[1].tier ~= "ungraded" then
			return false, "bad tier not clamped to ungraded"
		end
		if v.grades[2].id ~= "c-killer" or v.grades[2].tier ~= "ungraded" then
			return false, "missing criterion not filled as ungraded"
		end
		if v.summary ~= "s" then
			return false, "summary lost"
		end
		return true
	end)

	add("renderReport shows counts, killer status, fails-first, and the concrete fix", function()
		local raw = {
			grades = {
				{ id = "c-base", tier = "pass", towardFull = true, evidence = "ok", gap = "" },
				{ id = "c-killer", tier = "fail", towardFull = false, evidence = "absent", gap = "missing X" },
			},
			summary = "overall",
		}
		local v = EvaluateReport.validateGrades(raw, RUBRIC :: any)
		local text = EvaluateReport.renderReport(RUBRIC :: any, v)
		if string.find(text, "1/2 pass, 0 partial, 1 fail", 1, true) == nil then
			return false, "counts line wrong: " .. text
		end
		if string.find(text, "Killer systems: c-killer=FAIL", 1, true) == nil then
			return false, "killer status missing"
		end
		-- the FAIL must appear before the PASS (fails-first)
		local failPos = string.find(text, "%[FAIL%] c%-killer")
		local passPos = string.find(text, "%[PASS%] c%-base")
		if failPos == nil or passPos == nil or failPos >= passPos then
			return false, "not fails-first"
		end
		if string.find(text, "do the killer fix", 1, true) == nil then
			return false, "concrete fix not shown for the fail"
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
			print("[EvaluateReportSpec] PASS " .. c.name)
		else
			warn("[EvaluateReportSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[EvaluateReportSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
```

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: `stylua` clean, selene `0 errors, 0 warnings`, rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/EvaluateReport.luau src/EvaluateReportSpec.luau
git commit -m "feat: EvaluateReport — grade tool schema + validate + render (pure) + spec" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Anthropic.requestStructured` (forced tool_choice + text fallback)

**Files:**
- Modify: `src/Anthropic.luau`

- [ ] **Step 1: Add `toolChoice` to `SendOpts`** — replace the `SendOpts` type (lines ~23-29) with:

```lua
export type SendOpts = {
	messages: { any },
	model: string?,
	maxTokens: number?,
	system: string?,
	tools: { any }?,
	toolChoice: any?,
}
```

- [ ] **Step 2: Pass `tool_choice` in `sendMessage`** — in `Anthropic.sendMessage`, after the `if opts.tools ~= nil then body.tools = opts.tools end` block, add:

```lua
	if opts.toolChoice ~= nil then
		body.tool_choice = opts.toolChoice
	end
```

- [ ] **Step 3: Add `requestStructured`** — insert immediately AFTER the `collectText` local function (after line ~205, before `Anthropic.ping`):

```lua
export type StructuredOpts = { messages: { any }, tool: { [string]: any }, maxTokens: number? }

-- Force a single tool call (structured output). Sends tools={tool} + tool_choice={type="tool",name}.
-- Returns (input, rawText, result):
--   input   = the forced tool's `input` table if the model called it (the structured result), else nil;
--   rawText = the assistant's text (for the caller's JSON-from-text fallback) when no tool_use came back
--             (e.g. a proxy that ignores tool_choice);
--   result  = the underlying Result (for error handling when ok=false).
function Anthropic.requestStructured(self: Anthropic, opts: StructuredOpts): (any?, string?, Result)
	local res = self:sendMessage({
		messages = opts.messages,
		maxTokens = opts.maxTokens,
		tools = { opts.tool },
		toolChoice = { type = "tool", name = opts.tool.name },
	})
	if not res.ok then
		return nil, nil, res
	end
	local data = res.data
	if type(data) == "table" and type(data.content) == "table" then
		for _, block in ipairs(data.content) do
			if
				type(block) == "table"
				and block.type == "tool_use"
				and type(block.input) == "table"
			then
				return block.input, nil, res
			end
		end
	end
	return nil, collectText(data), res
end
```

- [ ] **Step 4: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/Anthropic.luau
git commit -m "feat: Anthropic.requestStructured (forced tool_choice structured output + text fallback)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `Tools/Evaluate.luau` + register

**Files:**
- Create: `src/Tools/Evaluate.luau`
- Modify: `src/Tools/init.luau`

- [ ] **Step 1: Write `src/Tools/Evaluate.luau`**

```lua
--!strict
-- Evaluate tool: grade a built locomotion SYSTEM against a delivered rubric and return a structured,
-- per-criterion report (tier + cited evidence + concrete fix) to refine against. Gathers evidence
-- (DataModel structural dump + the agent's design claim), forces a schema-conformant grade via
-- Anthropic.requestStructured (prose-parse fallback), then renders. Parent-only + LOCAL (needs
-- context.rubrics + context.anthropic, like use_rubric); non-destructive; edit / Server-view.

local Selection = game:GetService("Selection")
local StarterPlayer = game:GetService("StarterPlayer")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local RubricCatalog = require(script.Parent.Parent.RubricCatalog)
local EvaluateReport = require(script.Parent.Parent.EvaluateReport)
local Path = require(script.Parent.Path)

local Evaluate = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local MAX_SCRIPT_CHARS = 2500 -- per-script source cap
local MAX_TOTAL_EVIDENCE = 14000 -- total source-bytes budget across all scripts
local CLASSES_OF_INTEREST: { [string]: boolean } = {
	Humanoid = true,
	Animator = true,
	AnimationController = true,
	IKControl = true,
	AnimationConstraint = true,
	Motor6D = true,
}

local function resolveSubject(target: any): Instance?
	if type(target) == "string" and target ~= "" then
		local inst = Path.resolve(target)
		return inst
	end
	local sel = Selection:Get()
	return if #sel > 0 then sel[1] else nil
end

-- Structural evidence: a class census under the subject + the source of nearby scripts (capped).
local function gatherStructural(subject: Instance?): string
	local parts: { string } = {}
	if subject ~= nil then
		local census: { [string]: number } = {}
		for _, d in subject:GetDescendants() do
			if CLASSES_OF_INTEREST[d.ClassName] then
				census[d.ClassName] = (census[d.ClassName] or 0) + 1
			end
		end
		local cl: { string } = {}
		for k, v in census do
			table.insert(cl, k .. "=" .. tostring(v))
		end
		table.insert(
			parts,
			"Subject "
				.. subject:GetFullName()
				.. ": "
				.. (if #cl > 0 then table.concat(cl, ", ") else "NO locomotion-relevant instances found")
		)
	else
		table.insert(
			parts,
			"No subject given — structural evidence ABSENT; treat the design claims as UNVERIFIED."
		)
	end
	local roots: { Instance } = {}
	if subject ~= nil then
		table.insert(roots, subject)
	end
	local scs = StarterPlayer:FindFirstChild("StarterCharacterScripts")
	if scs ~= nil then
		table.insert(roots, scs)
	end
	table.insert(roots, ServerScriptService)
	local total = 0
	local seen: { [Instance]: boolean } = {}
	for _, root in roots do
		for _, d in root:GetDescendants() do
			if
				(d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript"))
				and not seen[d]
				and total < MAX_TOTAL_EVIDENCE
			then
				seen[d] = true
				local ok, src = pcall(function()
					return (d :: any).Source
				end)
				if ok and type(src) == "string" and src ~= "" then
					local snippet = if #src > MAX_SCRIPT_CHARS
						then string.sub(src, 1, MAX_SCRIPT_CHARS) .. "\n--[[...truncated...]]"
						else src
					total += #snippet
					table.insert(
						parts,
						"\n--- " .. d:GetFullName() .. " (" .. d.ClassName .. ") ---\n" .. snippet
					)
				end
			end
		end
	end
	return table.concat(parts, "\n")
end

-- Fallback: pull the first {...last} JSON object out of a prose response and decode it.
local function parseFromText(text: string): any?
	local first = string.find(text, "{", 1, true)
	local last = string.find(string.reverse(text), "}", 1, true)
	if first == nil or last == nil then
		return nil
	end
	local jsonText = string.sub(text, first, #text - last + 1)
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(jsonText)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

local INSTRUCTION = "You are a STRICT quality-rubric grader. Grade EACH criterion fail|partial|pass "
	.. "strictly against its 'Pass' and 'Evidence required' definitions. Weight VERIFIABLE structural/code "
	.. "evidence over unverified design claims — if the structure contradicts a claim, grade by the "
	.. "structure. Cite the specific evidence per criterion. Set towardFull only when the "
	.. "exceptional/ceiling extras are also met. You MUST call submit_grade with exactly one entry per "
	.. "criterion id."

local function runEvaluate(input: any, context: any): (string, boolean)
	local rubrics = if type(context) == "table" then context.rubrics else nil
	if rubrics == nil then
		return "evaluate isn't available here (no rubrics in this context)", true
	end
	local anthropic = if type(context) == "table" then context.anthropic else nil
	if anthropic == nil or type((anthropic :: any).requestStructured) ~= "function" then
		return "evaluate runs in edit mode or the Server view (structured grading isn't available in "
			.. "the client view yet).",
			true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "evaluate requires { category = <string>, subject?, design? }", true
	end
	local rubric = RubricCatalog.findByCategory(rubrics:all(), args.category)
	if rubric == nil then
		local names: { string } = {}
		for _, r in rubrics:all() do
			table.insert(names, r.module)
		end
		return "evaluate: unknown rubric '"
			.. tostring(args.category)
			.. "'. Available: "
			.. (if #names > 0 then table.concat(names, ", ") else "(none)"),
			true
	end

	local subject = resolveSubject(args.subject)
	local design = if type(args.design) == "string" and args.design ~= ""
		then args.design
		else "(no design summary provided)"
	local structural = gatherStructural(subject)
	local content = INSTRUCTION
		.. "\n\n=== RUBRIC ===\n"
		.. RubricCatalog.render(rubric)
		.. "\n\n=== DESIGN CLAIM (agent's account of what it built) ===\n"
		.. design
		.. "\n\n=== STRUCTURAL EVIDENCE (dumped from the DataModel) ===\n"
		.. structural

	local gradeTool = EvaluateReport.buildGradeTool(rubric)
	local gradeInput, rawText, res = (anthropic :: any):requestStructured({
		messages = { { role = "user", content = content } },
		tool = gradeTool,
		maxTokens = 4096,
	})
	if gradeInput == nil then
		if rawText ~= nil and rawText ~= "" then
			local parsed = parseFromText(rawText)
			if parsed ~= nil then
				gradeInput = parsed
			else
				return "evaluate: structured grading unavailable (the model returned prose, not a "
					.. "submit_grade call). Raw evaluation follows:\n\n" .. rawText,
					false
			end
		else
			local msg = if type(res) == "table" then tostring(res.message) else "unknown error"
			return "evaluate: the grading call failed (" .. msg .. ")", true
		end
	end

	local validated = EvaluateReport.validateGrades(gradeInput, rubric)
	return EvaluateReport.renderReport(rubric, validated), false
end

Evaluate.descriptors = {
	{
		name = "evaluate",
		description = "GRADE a built asset against its quality RUBRIC and get a structured, per-criterion "
			.. "report (tier + evidence + concrete fix) to refine against. Use AFTER building in a rubric "
			.. "category (the rubric grades the SYSTEM's architecture, not a clip's looks). Inputs: category "
			.. "(e.g. 'locomotion'), subject (instance path to the build to dump for structural evidence; "
			.. "omit to use the selection), design (YOUR summary of the architecture you built — what owns "
			.. "routing, IK, layering, etc.). Returns fails-first criteria with the fix for each; address "
			.. "them and re-evaluate.",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "The rubric category from the catalog (e.g. 'locomotion').",
				},
				subject = {
					type = "string",
					description = "Instance path to the build (for structural evidence); omit to use the selection.",
				},
				design = {
					type = "string",
					description = "Your architectural summary of what you built (claims the judge verifies vs structure).",
				},
			},
			required = { "category" },
		},
		destructive = false,
		run = runEvaluate,
	},
} :: { Descriptor }

return Evaluate
```

- [ ] **Step 2: Register in `src/Tools/init.luau`**

After `local AnimateTool = require(script.Animate)` (added in the slice-D plan; if absent, after `local IkTool = require(script.Ik)`), add:
```lua
local EvaluateTool = require(script.Evaluate)
```

After the `AnimateTool` descriptors loop (or the `IkTool` loop), add:
```lua
for _, descriptor in EvaluateTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
```

In the header comment's tool list, append `evaluate.`

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/Tools/Evaluate.luau src/Tools/init.luau
git commit -m "feat: evaluate tool — structured rubric grading (evidence dump + forced-schema grade + report)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: SystemPrompt — Evaluating section

**Files:**
- Modify: `src/SystemPrompt.luau`

- [ ] **Step 1: Add the section** — immediately AFTER the "# Quality rubrics" paragraph (the one ending "...proceed with your normal judgement."), insert:

```
# Evaluating against the rubric (close the loop)
After you BUILD an asset in a category that has a rubric, GRADE it: call evaluate(category, subject?, design) where design is YOUR concise summary of the architecture you built (what owns locomotion routing, foot IK, aim layering, pelvis/accel — the systems the rubric grades). evaluate dumps the build's structure (instances + script source) and grades each criterion fail/partial/pass with cited evidence + a concrete fix, fails-first. Then ADDRESS the fixes for the failing/partial criteria (especially the KILLER SYSTEMS) and re-evaluate, iterating until you clear the bar. The rubric grades the SYSTEM's architecture (owned velocity-driven routing, runtime IK, additive layers), not a single clip's appearance — so "I made one animation" will score low until the surrounding system exists. Grade honestly: evaluate weighs the actual structure over your claims.
```

- [ ] **Step 2: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/SystemPrompt.luau
git commit -m "docs(prompt): Evaluating-against-the-rubric section (close the capture->evaluate->refine loop)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Relay — classify `evaluate` LOCAL

**Files:**
- Modify: `src/Relay.luau`
- Modify: `src/RelaySpec.luau`

- [ ] **Step 1: Add `evaluate` to `LOCAL_TOOLS`** — in `src/Relay.luau`, in the `LOCAL_TOOLS` table, add `evaluate = true,` (alongside `use_rubric = true,`).

- [ ] **Step 2: Add `evaluate` to `EXPECTED_LOCAL`** — in `src/RelaySpec.luau`, add `"evaluate",` to the `EXPECTED_LOCAL` list (after `"use_rubric"`). (This keeps the in-Studio "no-drift" self-test passing, which asserts every registered tool is classified.)

- [ ] **Step 3: Static-verify**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: selene `0 errors, 0 warnings`; rojo build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/Relay.luau src/RelaySpec.luau
git commit -m "feat(relay): classify evaluate as LOCAL (needs rubrics + anthropic deps, like use_rubric)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full verify + bridge dogfood + HANDOFF

**Files:** `src/init.server.luau` (temporary spec require, reverted in Step 6); `HANDOFF.md`.

- [ ] **Step 1: Temporarily wire the spec** — in `src/init.server.luau`, add near the end (before the final lines), a temporary:
```lua
require(script.EvaluateReportSpec).run()
require(script.RelaySpec).run()
```

- [ ] **Step 2: Build + install + restart**

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; .\build.ps1`
Expected: selene `0 errors, 0 warnings`; `Installed -> …\Plugins\StudioAgent.rbxm`.
Then the **USER restarts Studio** ("Restart to update") on a fresh Baseplate. The sidecar + bridge + tunnel are already running.

- [ ] **Step 3: Confirm specs + bridge** — `& scripts/studio-agent.ps1 logs` → expect `[EvaluateReportSpec] 3/3 passed` and `RelaySpec ... Summary: N/N passed, 0 failed` and `dev bridge active`. (Invoke the CLI as `& scripts/studio-agent.ps1 …` from the PowerShell tool — a nested `powershell -File …` strips inner double-quotes.)

- [ ] **Step 4: Dogfood — the discrimination test + the tool_choice live-test** (the verification that matters):
```bash
# Strong design claim -> expect most criteria PASS (incl. killer systems)
& scripts/studio-agent.ps1 tool evaluate '{"category":"locomotion","design":"Locomotion is owned by a custom controller (StarterCharacterScripts) that reads HumanoidRootPart planar velocity each frame and drives a 2D blend space: a speed axis (idle@0->walk->jog->run) crossfading by AdjustWeight, and a direction axis weighted by VectorToObjectSpace(velocity) covering forward/back + strafe. Runtime foot IK via an IKControl (Type Transform) per foot raycasts off the animated hip to plant feet on slopes/steps. An additive aim layer plays at Action priority over Movement so the upper body tracks a target while the legs keep running. Pelvis sway counter-rotates LowerTorso driven by gait phase, and an additive velocity/acceleration lean tilts the root into turns. Acceleration is tracked as a ramped speedRatio feeding both the blend axis and the lean."}'
# Weak design claim -> expect killer systems FAIL with the right fixes
& scripts/studio-agent.ps1 tool evaluate '{"category":"locomotion","design":"It plays one forward run clip swapped onto the stock Animate by WalkSpeed. No blend tree, no foot IK, no aim layer, no pelvis sway. Feet skate on slopes."}'
```
Confirm: (a) the STRONG claim scores most criteria pass (killer systems pass), the WEAK claim scores the killer systems FAIL each with its `concrete_fix` — the grader SEPARATES them (the core acceptance signal); (b) the report is the structured fails-first format from `renderReport` (NOT the prose-fallback note) — which confirms **the CLIProxyAPI honors `tool_choice`**. If instead the prose-fallback note appears, record that the proxy does NOT honor tool_choice and that the JSON-from-text fallback carried it (or, if even that failed, capture the raw output for follow-up). Optionally run a third `evaluate {category="locomotion", subject="<a rig/script you build>", design=...}` to confirm structural evidence (instance census + script source) is cited.

- [ ] **Step 5: (Recommended) adversarial review** — a code-review Workflow / subagents over `EvaluateReport.luau` + `Tools/Evaluate.luau` + the `Anthropic.requestStructured` change (refute-biased); fix confirmed findings, re-verify.

- [ ] **Step 6: Revert the temporary spec require** — remove the two `require(...).run()` lines from `src/init.server.luau`.

Run: `stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm ; echo done`
Expected: clean build.

- [ ] **Step 7: Update HANDOFF.md + commit** — add a dated block: the Evaluate tool (slice E) shipped + bridge-verified (structured rubric grading via forced tool_choice; discrimination confirmed; the proxy tool_choice outcome recorded). Commit.

```bash
git add HANDOFF.md src/init.server.luau
git commit -m "docs: Evaluate tool (slice E) shipped + bridge-verified; revert spec auto-run" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (completed during plan authoring)

- **Spec coverage:** structured-output path (§3 Anthropic) → Task 2; grade schema + validate + render (§3 EvaluateReport, §5 schema) → Task 1; the evaluate tool with structural+design evidence (§4 data flow, §1 insight) → Task 3; LOCAL run-context (§6) → Tasks 3+5; SystemPrompt wiring → Task 4; error handling (§7: no rubrics, unknown category, no subject, HTTP fail, tool_choice-not-honored fallback, malformed grades) → Tasks 1 (validateGrades coercion) + 3 (the guards + parseFromText fallback); testing (§8: pure spec + discrimination dogfood + tool_choice live-test) → Tasks 1 + 6. All spec sections covered.
- **Placeholder scan:** every code step is complete; the deferred items are the spec's explicit non-goals (PropertyCatalog reads, exemplar store, prioritized Learnings, caching, viewer, client-play structured grading).
- **Type/name consistency:** `EvaluateReport.buildGradeTool/validateGrades/renderReport` (Task 1) are called by `Tools/Evaluate.runEvaluate` (Task 3) with the matching shapes; `Anthropic.requestStructured(opts:{messages,tool,maxTokens?}) -> (input?, rawText?, Result)` (Task 2) matches the call in Task 3; `RubricCatalog.findByCategory/render` + `RubricStore:all()` (existing) used in Task 3 with their real signatures; `Path.resolve` (existing) used in Task 3; the `evaluate` tool name matches across Task 3 (descriptor), Task 4 (prompt), and Task 5 (relay classification).
- **Encode safety:** the grade tool's `input_schema.properties` is non-empty (`grades`, `summary`) and every nested object schema has properties, so the `encodeBody` empty-object sentinel (which only swaps a top-level empty `input_schema.properties`) is not needed and not tripped.
