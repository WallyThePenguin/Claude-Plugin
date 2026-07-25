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

-- Shape the ergonomic tool input into a raw guide validateGuide accepts. Accepts either a full `tiers`
-- array OR a flat `steps` list (strings or {instruction,...} objects) wrapped into one baseline tier.
local function rawFromInput(args: any): any?
	local raw: { [string]: any } = {
		module = args.category,
		version = if type(args.version) == "string" then args.version else "1",
		overview = if type(args.overview) == "string" then args.overview else "",
		rubric_version = if type(args.rubric_version) == "string" then args.rubric_version else "",
		killer_systems = args.killer_systems,
		common_pitfalls = args.common_pitfalls,
	}
	if type(args.tiers) == "table" then
		raw.tiers = args.tiers
		return raw
	end
	if type(args.steps) == "table" then
		local steps: { any } = {}
		for i, st in ipairs(args.steps :: { any }) do
			if type(st) == "string" then
				table.insert(steps, { id = "step-" .. i, order_index = i, instruction = st })
			elseif type(st) == "table" and type(st.instruction) == "string" then
				table.insert(steps, {
					id = if type(st.id) == "string" then st.id else "step-" .. i,
					order_index = i,
					instruction = st.instruction,
					tools = st.tools,
					addresses_criteria = st.addresses_criteria,
					pitfalls = st.pitfalls,
				})
			end
		end
		raw.tiers = {
			{
				tier = "baseline",
				goal = if type(args.overview) == "string" then args.overview else "",
				steps = steps,
			},
		}
		return raw
	end
	return nil
end

local function saveBuildGuide(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "save_build_guide is not available here (no build guides in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "save_build_guide requires { category = <string>, and either steps = [string] or a full tiers = [...] }",
			true
	end
	local raw = rawFromInput(args)
	if raw == nil then
		return "save_build_guide requires either steps = [string|object] or a full tiers = [...] array",
			true
	end
	local note, ok = s:save(raw)
	return note, not ok
end

local function deleteBuildGuide(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "delete_build_guide is not available here", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.category) ~= "string" then
		return "delete_build_guide requires { category = <string> }", true
	end
	local note, ok = s:delete(args.category)
	return note, not ok
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
	{
		name = "save_build_guide",
		description = "Save a NEW reusable BUILD GUIDE (your own how-to-build approach for a category) that "
			.. "persists across chats and appears in your build-guide catalog next time. Use this to capture "
			.. "a build approach the user teaches you or that you refine. Pass a NEW category name (it can't "
			.. "collide with a built-in like 'locomotion') plus either a simple steps = [\"step one\", ...] "
			.. "list (wrapped into a baseline tier) or a full tiers = [{ tier, goal, steps }] structure.",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "The guide's category/name. Must NOT match a built-in guide category.",
				},
				overview = {
					type = "string",
					description = "One-paragraph overview of the build approach.",
				},
				steps = {
					type = "array",
					description = "Simple form: an ordered list of step instruction strings (wrapped into a "
						.. "baseline tier). Use this OR tiers.",
					items = { type = "string" },
				},
				tiers = {
					type = "array",
					description = "Full form: [{ tier='baseline'|'good'|'exceptional', goal, steps=[{id, "
						.. "instruction, tools?, addresses_criteria?, pitfalls?}] }]. Use this OR steps.",
					items = { type = "object" },
				},
			},
			required = { "category" },
		},
		destructive = false,
		run = saveBuildGuide,
	},
	{
		name = "delete_build_guide",
		description = "Delete one of YOUR saved build guides by category (built-in guides can't be deleted).",
		inputSchema = {
			type = "object",
			properties = {
				category = {
					type = "string",
					description = "The user build-guide category to delete.",
				},
			},
			required = { "category" },
		},
		destructive = true,
		run = deleteBuildGuide,
	},
} :: { Descriptor }

return BuildGuides
