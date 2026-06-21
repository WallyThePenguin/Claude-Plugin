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
				.. (
					if #cl > 0
						then table.concat(cl, ", ")
						else "NO locomotion-relevant instances found"
				)
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
					.. "submit_grade call). Raw evaluation follows:\n\n"
					.. rawText,
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
