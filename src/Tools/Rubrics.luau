--!strict
-- Rubric tools: use_rubric. Thin wrapper over context.rubrics (the RubricStore). Parent-only: NOT in
-- the subagent/writer allowlists, and a child's context carries no rubrics, so it no-ops gracefully for
-- a child. Non-destructive (no DataModel writes).

local Rubrics = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function store(context: any): any
	return if type(context) == "table" then context.rubrics else nil
end

local function useRubric(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "use_rubric is not available here (no rubrics in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "use_rubric requires { category = <string> }", true
	end
	local text, ok = s:resolve(args.category)
	return text, not ok
end

Rubrics.descriptors = {
	{
		name = "use_rubric",
		description = "Load the quality RUBRIC for an asset category and build TO it. Rubrics are listed "
			.. "in your context under '# Quality rubrics'. This returns the full tiered rubric "
			.. "(baseline/good/exceptional criteria with evidence + concrete fixes) — read it, then build "
			.. "to the highest tier you can, addressing each criterion. Call this BEFORE building an asset "
			.. "in a listed category.",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "The rubric category from the catalog (e.g. 'locomotion').",
				},
			},
			required = { "category" },
		},
		destructive = false,
		run = useRubric,
	},
} :: { Descriptor }

return Rubrics
