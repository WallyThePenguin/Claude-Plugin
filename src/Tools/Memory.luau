--!strict
-- Memory tools: remember + forget. Thin wrappers over context.memory (the cross-session store).
-- Parent-only: NOT in the subagent allowlist, and a subagent context carries no memory, so they
-- no-op gracefully for a child (defence in depth).

local Memory = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function remember(input: any, context: any): (string, boolean)
	local mem = if type(context) == "table" then context.memory else nil
	if mem == nil then
		return "remember is not available here (no memory in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	if type(args.text) ~= "string" then
		return "remember requires { text = <string>, scope? = 'game'|'global' }", true
	end
	-- scope is optional (defaults to game), but a PRESENT scope must be valid (don't silently coerce a
	-- typo like 'gloabl' into the game bucket).
	if args.scope ~= nil and args.scope ~= "game" and args.scope ~= "global" then
		return "remember scope must be 'game' or 'global' (or omitted for 'game')", true
	end
	return mem:add(args.scope, args.text), false
end

local function forget(input: any, context: any): (string, boolean)
	local mem = if type(context) == "table" then context.memory else nil
	if mem == nil then
		return "forget is not available here (no memory in this context)", true
	end
	local args = if type(input) == "table" then input else {}
	-- scope is REQUIRED here (id namespaces overlap between buckets, so a missing/typo'd scope could
	-- target the wrong entry), and id must be a real number.
	if args.scope ~= "game" and args.scope ~= "global" then
		return "forget requires scope = 'game' or 'global'", true
	end
	if tonumber(args.id) == nil then
		return "forget requires { scope = 'game'|'global', id = <number> }", true
	end
	return mem:forget(args.scope, args.id), false
end

Memory.descriptors = {
	{
		name = "remember",
		description = "Save a DURABLE fact to recall in FUTURE chats (it is injected into your context "
			.. "automatically next time). scope='game' (default) is for THIS place's architecture, "
			.. "conventions, and decisions; scope='global' is for your reusable techniques, Roblox "
			.. "gotchas, and the user's stated preferences (carried to every place). Keep each fact to "
			.. "one concise sentence. Don't save the obvious, the ephemeral, or anything already visible "
			.. "in the DataModel. Use forget to drop a fact that becomes wrong.",
		inputSchema = {
			type = "object",
			properties = {
				text = {
					type = "string",
					description = "The fact to remember (one concise sentence).",
				},
				scope = {
					type = "string",
					enum = { "game", "global" },
					description = "'game' (this place; default) or 'global' (every place).",
				},
			},
			required = { "text" },
		},
		destructive = false,
		run = remember,
	},
	{
		name = "forget",
		description = "Remove a remembered fact by its #id (shown in the injected memory list). Use "
			.. "when a fact is now wrong or obsolete.",
		inputSchema = {
			type = "object",
			properties = {
				scope = {
					type = "string",
					enum = { "game", "global" },
					description = "Which memory the entry is in.",
				},
				id = { type = "number", description = "The #id of the entry to forget." },
			},
			required = { "scope", "id" },
		},
		destructive = false,
		run = forget,
	},
} :: { Descriptor }

return Memory
