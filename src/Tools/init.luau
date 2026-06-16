--!strict
-- Tools registry + dispatch (M6: run_luau only; M7 adds the structured tools).
-- schemas() -> the `tools` array for the Anthropic request.
-- dispatch(name, input) -> (contentText, isError); ALWAYS returns a string + bool, never throws,
-- so a tool_use block is never left without a tool_result (which would 400 the next request).

local RunLuau = require(script.RunLuau)

local Tools = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any) -> (string, boolean),
}

local registry: { Descriptor } = {
	{
		name = "run_luau",
		description = "Execute Luau in Studio at PluginSecurity. State persists across calls (a REPL "
			.. "session). Returns serialized return values plus captured print/warn output. Edits are "
			.. "wrapped in an undoable ChangeHistory recording. Use this for anything the structured "
			.. "tools don't cover; compose multiple operations in one call to minimize round-trips.",
		inputSchema = {
			type = "object",
			properties = {
				code = { type = "string", description = "Luau source to run." },
			},
			required = { "code" },
		},
		destructive = true,
		run = function(input: any): (string, boolean)
			local code = if type(input) == "table" then input.code else nil
			local out = RunLuau.run({ code = tostring(code) })
			return out.text, out.error
		end,
	},
}

local byName: { [string]: Descriptor } = {}
for _, descriptor in registry do
	byName[descriptor.name] = descriptor
end

-- The Anthropic `tools` payload: one {name, description, input_schema} per registered tool.
function Tools.schemas(): { any }
	local out: { any } = {}
	for _, descriptor in registry do
		table.insert(out, {
			name = descriptor.name,
			description = descriptor.description,
			input_schema = descriptor.inputSchema,
		})
	end
	return out
end

-- Look up a descriptor (used by M11's destructive-confirm gate).
function Tools.get(name: string): Descriptor?
	return byName[name]
end

-- Run one tool_use. Wraps both the handler and its failure in pcall so dispatch is total:
-- a thrown error becomes an is_error tool_result rather than aborting the loop.
function Tools.dispatch(name: string, input: any): (string, boolean)
	local descriptor = byName[name]
	if descriptor == nil then
		return "unknown tool: " .. tostring(name), true
	end
	local ok, text, isError = pcall(descriptor.run, input)
	if not ok then
		return "tool handler error: " .. tostring(text), true
	end
	return tostring(text), isError == true
end

return Tools
