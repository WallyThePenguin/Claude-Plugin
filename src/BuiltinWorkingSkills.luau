--!strict
-- BuiltinWorkingSkills: built-in WORKING skills (category "working") — Studio-adapted ports of the
-- orchestrator's process skills (brainstorming, planning, TDD, debugging, code-review, frontend-design,
-- skill-creator, deep-research). Pure data. Each teaches HOW to approach a task; the reasoning is kept,
-- the tool references rewritten to the Studio toolset.

local BuiltinWorkingSkills = {}

BuiltinWorkingSkills.list = {
	{
		name = "brainstorm-a-build",
		description = "Explore intent before building anything non-trivial (clarify → approaches → plan).",
		parameters = {},
		body = "Before building anything non-trivial, understand intent FIRST.\n"
			.. "1) Ask the user 1-2 clarifying questions (purpose, constraints, what 'done' looks like) — "
			.. "one at a time.\n"
			.. "2) Propose 2-3 approaches with trade-offs and your recommendation.\n"
			.. "3) Once they pick, lay out the steps with update_tasks.\n"
			.. "4) Then build, verifying each step (get_properties / get_tree / capture).\n"
			.. "Don't start building until the goal is clear. Skip this for a trivial one-step request.",
	},
	{
		name = "plan-a-build",
		description = "Decompose a large multi-part build, mark what parallelizes, verify at checkpoints.",
		parameters = {},
		body = "For a large multi-part build:\n"
			.. "1) Decompose it into independent regions/steps.\n"
			.. "2) Mark which parts are INDEPENDENT — those can be built in parallel with dispatch_writers "
			.. "(create each region's container first). Use the parallel-zones recipe for that pattern.\n"
			.. "3) Lay the steps out with update_tasks (keep exactly one in_progress).\n"
			.. "4) Build in order, VERIFYING at each checkpoint (get_tree / get_properties / capture).\n"
			.. "5) Do cross-region wiring last, then a final verify.",
	},
	{
		name = "test-first",
		description = "Write a failing check before building gameplay logic, then build until it passes.",
		parameters = {},
		body = "For gameplay LOGIC (not just appearance), test-first:\n"
			.. "1) Before building, write a small check that FAILS now — a run_luau snippet (in edit) or a "
			.. "RunService:Run() in-place sim that asserts the expected end state, or that reads get_output "
			.. "for an expected print.\n"
			.. "2) Run it and confirm it fails for the right reason.\n"
			.. "3) Build the minimal thing to make it pass.\n"
			.. "4) Re-run the check; iterate until it passes.\n"
			.. "5) For scripts, also check get_output(errorsOnly=true). This catches logic bugs early "
			.. "instead of eyeballing.",
	},
	{
		name = "debug-systematically",
		description = "Reproduce → hypothesize → isolate → fix the root cause → re-verify (no guessing).",
		parameters = {},
		body = "When a script errors or behaves wrong:\n"
			.. "1) REPRODUCE first — get_output(errorsOnly=true) for the error, or RunService:Run() to "
			.. "trigger it; note the exact symptom.\n"
			.. "2) Form ONE hypothesis about the ROOT cause.\n"
			.. "3) Isolate it — read the relevant Source/properties (get_properties / get_tree), add a "
			.. "targeted print or assertion to confirm the hypothesis.\n"
			.. "4) Fix the root cause, not the symptom.\n"
			.. "5) Re-run and verify the symptom is gone AND no new errors appear.\n"
			.. "Don't guess-and-check randomly — each step should rule something in or out.",
	},
	{
		name = "review-my-build",
		description = "Independently verify a finished build with adversarial read-only subagents.",
		parameters = {},
		body = "After building something substantial, verify it independently before calling it done:\n"
			.. "1) dispatch_subagents with 1-3 READ-ONLY reviewers, each prompted to ADVERSARIALLY check a "
			.. "specific aspect — does the GUI match the request? do the scripts error in "
			.. "get_output(errorsOnly)? are the key properties correct? Each captures/inspects and reports "
			.. "pass/fail with concrete specifics (paths, values, what it saw).\n"
			.. "2) Triage their findings with rigor — re-read the actual state to confirm each one is real "
			.. "before fixing. Treat a vague 'looks fine' skeptically; treat a concrete defect seriously.\n"
			.. "3) Fix confirmed issues and re-verify.",
	},
	{
		name = "gui-design-quality",
		description = "Make a ScreenGui look intentional: hierarchy, spacing, alignment, color, then capture.",
		parameters = {},
		body = "When building a ScreenGui, make it look intentional, not default-grey:\n"
			.. "1) Hierarchy — size/position the primary element first; group children with UIListLayout / "
			.. "UIGridLayout + UIPadding.\n"
			.. "2) Spacing — consistent padding/margins (UIPadding); don't crowd elements.\n"
			.. "3) Alignment — AnchorPoint + UDim2 scale for centering; align edges deliberately.\n"
			.. "4) Color — a small cohesive palette (a background, ONE accent, readable text contrast); round "
			.. "corners with UICorner.\n"
			.. "5) Then capture and actually LOOK — fix colors/alignment/framing and capture again until it "
			.. "looks good. Avoid the generic default look.",
	},
	{
		name = "create-skill",
		description = "Brainstorm + author a new reusable Roblox skill WITH the user, then save it.",
		parameters = {},
		body = "When the user wants a new reusable skill (or asks you to always build something a certain "
			.. "way):\n"
			.. "1) INTERVIEW them — what task it does, WHEN it should be used (this becomes the description), "
			.. "what VARIES between uses (parameters), and the concrete ordered steps. Ask one thing at a "
			.. "time.\n"
			.. "2) Draft the recipe BODY as concrete ordered steps the agent would follow, referencing the "
			.. "real tools (create_instance / set_property / run_luau / dispatch_writers / capture / "
			.. "update_tasks). Use {{paramName}} where a value varies.\n"
			.. "3) Show the user the draft (name, description, parameters, body) and get their OK.\n"
			.. "4) Call save_skill(name, description, body, parameters) to persist it.\n"
			.. "5) Confirm it's now in the catalog and they can invoke it next time. Keep the description "
			.. "trigger-focused and the steps concrete.",
	},
	{
		name = "research-a-topic",
		description = "Fan out web research (incl. roblox.com), verify sources, synthesize a cited answer.",
		parameters = {},
		body = "To research something (a Roblox API, a technique, how other games do X):\n"
			.. "1) For BREADTH, dispatch_subagents with 2-4 READ-ONLY children, each researching a different "
			.. "angle via web_search / web_fetch (these run on Anthropic's servers and reach the whole web "
			.. "INCLUDING roblox.com).\n"
			.. "2) Each child finds sources, reads the best ones, and reports concise findings WITH source "
			.. "URLs.\n"
			.. "3) For Roblox docs specifically, prefer the GitHub creator-docs raw mirror "
			.. "(raw.githubusercontent.com/Roblox/creator-docs/...) for full bodies — create.roblox.com is a "
			.. "JS SPA so a raw fetch returns mostly metadata.\n"
			.. "4) Synthesize the children's reports into a clear answer, noting which source backs each claim "
			.. "and any disagreement. Use this for genuinely open questions, not a single lookup you can do "
			.. "yourself.",
	},
}

return BuiltinWorkingSkills
