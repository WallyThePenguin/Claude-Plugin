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
