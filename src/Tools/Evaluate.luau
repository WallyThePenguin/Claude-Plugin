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
local GuiEvidence = require(script.Parent.Parent.GuiEvidence)
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

local function resolveSubject(target: any): (Instance?, string?)
	if type(target) == "string" and target ~= "" then
		return Path.resolve(target) -- (Instance?, errString?)
	end
	local sel = Selection:Get()
	return (if #sel > 0 then sel[1] else nil), nil
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
				.. (
					if #cl > 0
						then table.concat(cl, ", ")
						else "NO locomotion-relevant instances found"
				)
		)
		local guiEv = GuiEvidence.gather(subject)
		if guiEv ~= "" then
			table.insert(parts, guiEv)
		end
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

	local subject, subjectErr = resolveSubject(args.subject)
	local design = if type(args.design) == "string" and args.design ~= ""
		then args.design
		else "(no design summary provided)"
	local structural = gatherStructural(subject)
	-- A given-but-unresolvable subject path: tell the judge structure is absent because the path failed
	-- (so it doesn't silently grade design-only as if no subject was intended).
	if subject == nil and type(args.subject) == "string" and args.subject ~= "" then
		structural = "(note: subject path '"
			.. args.subject
			.. "' did not resolve"
			.. (if subjectErr ~= nil then " — " .. subjectErr else "")
			.. ")\n"
			.. structural
	end
	local learningsStore = if type(context) == "table" then context.learnings else nil
	local learned = if learningsStore ~= nil
		then (learningsStore :: any):forCategory(args.category)
		else ""
	local content = INSTRUCTION
		.. "\n\n=== RUBRIC ===\n"
		.. RubricCatalog.render(rubric)
		.. "\n\n=== DESIGN CLAIM (agent's account of what it built) ===\n"
		.. design
		.. "\n\n=== STRUCTURAL EVIDENCE (dumped from the DataModel) ===\n"
		.. structural
		.. (
			if learned ~= ""
				then "\n\n=== ESTABLISHED LEARNINGS for this category (confirmed corrections to weight) ===\n"
					.. learned
				else ""
		)

	local gradeTool = EvaluateReport.buildGradeTool(rubric)
	-- 8192 (the model max), not 4096: a large rubric's forced grade response (one entry per criterion +
	-- cited evidence) overflows 4096 once the rubric passes ~30 criteria (the 35-criterion gui rubric
	-- truncated to an empty result at 4096; combat's 29 just fit). Smaller rubrics use less, unaffected.
	local gradeInput, rawText, res = (anthropic :: any):requestStructured({
		messages = { { role = "user", content = content } },
		tool = gradeTool,
		maxTokens = 8192,
	})
	-- A result is USABLE only if it carries a non-empty grades array. A forced tool_choice does NOT
	-- guarantee non-empty arguments (and the proxy may not honor it), so a non-nil-but-empty/degenerate
	-- result (grades = {} or absent) must NOT be rendered as a confident all-ungraded grade.
	local function usable(g: any): boolean
		return type(g) == "table" and type(g.grades) == "table" and #g.grades > 0
	end
	if not usable(gradeInput) and rawText ~= nil and rawText ~= "" then
		local parsed = parseFromText(rawText)
		if usable(parsed) then
			gradeInput = parsed
		end
	end
	if not usable(gradeInput) then
		if type(res) == "table" and res.ok == false then
			local msg = if type(res.message) == "string" then res.message else "unknown error"
			return "evaluate: the grading call failed (" .. msg .. ")", true
		end
		if rawText ~= nil and rawText ~= "" then
			-- The model returned prose, not a usable submit_grade call: graceful degrade — hand back the
			-- prose so the agent still gets the substance (not a hard error).
			return "evaluate: structured grading unavailable (the model returned prose, not a "
				.. "submit_grade call). Raw evaluation follows:\n\n"
				.. rawText,
				false
		end
		-- A 2xx but empty/degenerate result (no grades AND no text — truncated, or structured output not
		-- honored): flag it so the agent RETRIES rather than seeing a confident all-ungraded report.
		return "evaluate: the grader returned an empty result (no grades) — the response was likely "
			.. "truncated or the structured-output path was not honored. Try again.",
			true
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
