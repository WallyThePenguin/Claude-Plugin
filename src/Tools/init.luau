--!strict
-- Tools registry + dispatch (M6: run_luau only; M7 adds the structured tools).
-- schemas() -> the `tools` array for the Anthropic request.
-- dispatch(name, input) -> (contentText, isError); ALWAYS returns a string + bool, never throws,
-- so a tool_use block is never left without a tool_result (which would 400 the next request).
--
-- The M7 structured tools live in sibling modules that each export a `descriptors` LIST of the same
-- Descriptor shape; this module concatenates them after the built-in run_luau into one flat
-- registry. Final registry: run_luau, get_tree, search, get_properties, set_property.

local RunLuau = require(script.RunLuau)
local Tree = require(script.Tree)
local PropertiesTool = require(script.Properties)

local Tools = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any) -> (string, boolean),
}

-- run_luau stays EXACTLY as before; the structured descriptors are appended below.
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
			if type(input) ~= "table" or type(input.code) ~= "string" then
				return "run_luau requires { code = <string> }", true
			end
			local out = RunLuau.run({ code = input.code })
			return out.text, out.error
		end,
	},
}

-- Append each module's exported descriptors in a stable order (Tree, then Properties).
for _, descriptor in Tree.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in PropertiesTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end

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
