--!strict
-- Skill tools: use_skill + save_skill + delete_skill. Thin wrappers over context.skills (the SkillStore).
-- Parent-only: NOT in the subagent/writer allowlists, and a child's context carries no skills, so they
-- no-op gracefully for a child (defence in depth). All non-destructive (they don't touch the DataModel).

local Skills = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function store(context: any): any
	return if type(context) == "table" then context.skills else nil
end

local function useSkill(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "use_skill is not available here (no skills in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.name) ~= "string" then
		return "use_skill requires { name = <string>, args? = <object> }", true
	end
	local text, ok = s:resolve(args.name, args.args)
	return text, not ok
end

local function saveSkill(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "save_skill is not available here (no skills in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if
		type(args.name) ~= "string"
		or type(args.description) ~= "string"
		or type(args.body) ~= "string"
	then
		return "save_skill requires { name, description, body (strings), parameters? = [ {name, description, required?} ] }",
			true
	end
	local note, ok = s:save(args.name, args.description, args.body, args.parameters)
	return note, not ok
end

local function deleteSkill(input: any, context: any): (string, boolean)
	local s = store(context)
	if s == nil then
		return "delete_skill is not available here (no skills in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.name) ~= "string" then
		return "delete_skill requires { name = <string> }", true
	end
	local note, ok = s:delete(args.name)
	return note, not ok
end

Skills.descriptors = {
	{
		name = "use_skill",
		description = "Load a named skill recipe and FOLLOW it with your normal tools. Skills are listed in "
			.. "your context under '# Skills' (build recipes + working skills + your saved skills). This "
			.. "returns the recipe TEXT (instructions), NOT a finished build — read it and do the work, "
			.. "passing any required values in `args`. A recipe may itself tell you to use dispatch_writers / "
			.. "update_tasks / capture.",
		inputSchema = {
			type = "object",
			properties = {
				name = {
					type = "string",
					description = "The skill name from the catalog (e.g. 'shop-gui').",
				},
				args = {
					type = "object",
					description = "Optional values for the skill's declared parameters.",
				},
			},
			required = { "name" },
		},
		destructive = false,
		run = useSkill,
	},
	{
		name = "save_skill",
		description = "Save a NEW reusable skill (a build recipe) that persists across chats and appears in "
			.. "your skill catalog next time. Use the create-skill working skill to author it WITH the user "
			.. "first. `body` is concrete ordered steps referencing your real tools; use {{paramName}} where a "
			.. "value varies, and declare those in `parameters`. You can't overwrite a built-in name.",
		inputSchema = {
			type = "object",
			properties = {
				name = { type = "string", description = "Short skill name, e.g. 'my-shop'." },
				description = {
					type = "string",
					description = "One line: what it does + when to use it.",
				},
				body = {
					type = "string",
					description = "The recipe: concrete ordered steps to follow.",
				},
				parameters = {
					type = "array",
					description = "Declared parameters substituted as {{name}} in the body.",
					items = {
						type = "object",
						properties = {
							name = { type = "string" },
							description = { type = "string" },
							required = { type = "boolean" },
						},
						required = { "name" },
					},
				},
			},
			required = { "name", "description", "body" },
		},
		destructive = false,
		run = saveSkill,
	},
	{
		name = "delete_skill",
		description = "Delete one of YOUR saved skills by name (built-in skills can't be deleted).",
		inputSchema = {
			type = "object",
			properties = {
				name = { type = "string", description = "The user skill to delete." },
			},
			required = { "name" },
		},
		destructive = false,
		run = deleteSkill,
	},
} :: { Descriptor }

return Skills
