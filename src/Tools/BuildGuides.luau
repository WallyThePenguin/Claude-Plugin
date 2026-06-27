--!strict
-- Build-guide tools: use_build_guide. Thin wrapper over context.buildGuides (the BuildGuideStore).
-- Parent-only: NOT in the subagent/writer allowlists, and a child's context carries no buildGuides, so
-- it no-ops gracefully for a child. Non-destructive (no DataModel writes). Mirrors Tools/Rubrics.

local BuildGuides = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function store(context: any): any
	return if type(context) == "table" then context.buildGuides else nil
end

local function useBuildGuide(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "use_build_guide is not available here (no build guides in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "use_build_guide requires { category = <string> }", true
	end
	local text, ok = s:resolve(args.category)
	return text, not ok
end

BuildGuides.descriptors = {
	{
		name = "use_build_guide",
		description = "Load the BUILD GUIDE for an asset category — the tiered, rubric-anchored approach "
			.. "for how to build a great one (each step cites real tools + the rubric criteria it "
			.. "satisfies). Build guides are listed in your context under '# Build guides'. Call this "
			.. "together with use_rubric BEFORE building an asset in a listed category: the rubric is the "
			.. "bar, this is how to reach it. Follow the steps from baseline up to the highest tier you can.",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "The category from the build-guide catalog (e.g. 'locomotion').",
				},
			},
			required = { "category" },
		},
		destructive = false,
		run = useBuildGuide,
	},
} :: { Descriptor }

return BuildGuides
