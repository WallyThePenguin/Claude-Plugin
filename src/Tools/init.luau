--!strict
-- Tools registry + dispatch (M6: run_luau only; M7 adds the structured tools; capture adds vision).
-- schemas() -> the `tools` array for the Anthropic request.
-- dispatch(name, input, context) -> (content, isError); content is a string for most tools OR a
-- tool_result blocks array (capture's image). Never throws, and always returns a string-or-table
-- content, so a tool_use block is never left without a valid tool_result (which would 400 the next
-- request). `context` carries loop deps (config/anthropic) for tools that need them.
--
-- The structured tools live in sibling modules that each export a `descriptors` LIST of the same
-- Descriptor shape; this module concatenates them after the built-in run_luau into one flat
-- registry. Final registry: run_luau, get_tree, search, get_properties, get_output, set_property,
-- create_instance, capture, web_fetch, web_search, dispatch_subagents, update_tasks.

local RunLuau = require(script.RunLuau)
local Tree = require(script.Tree)
local PropertiesTool = require(script.Properties)
local OutputTool = require(script.Output)
local CreateTool = require(script.Create)
local CaptureTool = require(script.Capture)
local WebTool = require(script.Web)
local SubagentsTool = require(script.Subagents)
local TasksTool = require(script.Tasks)

local Tools = {}

-- A tool's content is USUALLY a string, but a tool may return a tool_result blocks array instead
-- (e.g. `capture` returns an image block). Anthropic's tool_result `content` accepts either form.
export type Content = string | { any }

-- `context` carries loop-level dependencies a tool may need at run time (config, anthropic). Most
-- tools ignore it; `capture` reads context.config for the sidecar URL + token.
export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (Content, boolean),
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
		run = function(input: any, _context: any): (string, boolean)
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
for _, descriptor in OutputTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in CreateTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in CaptureTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in WebTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in SubagentsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in TasksTool.descriptors :: { Descriptor } do
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

-- Like schemas(), but filtered to a named subset (used to give a subagent a read-only toolset).
function Tools.schemasFor(names: { string }): { any }
	local want: { [string]: boolean } = {}
	for _, n in names do
		want[n] = true
	end
	local out: { any } = {}
	for _, descriptor in registry do
		if want[descriptor.name] then
			table.insert(out, {
				name = descriptor.name,
				description = descriptor.description,
				input_schema = descriptor.inputSchema,
			})
		end
	end
	return out
end

-- Look up a descriptor (used by M11's destructive-confirm gate).
function Tools.get(name: string): Descriptor?
	return byName[name]
end

-- Run one tool_use. Wraps both the handler and its failure in pcall so dispatch is total:
-- a thrown error becomes an is_error tool_result rather than aborting the loop. `context` carries
-- loop dependencies (config/anthropic) for tools that need them. Returns the tool's content — a
-- string for most tools, or a blocks array for `capture` (the caller forwards it as tool_result
-- content). Anything that is neither string nor table is coerced to a string so the tool_result is
-- never malformed (the API rejects a missing/invalid content).
function Tools.dispatch(name: string, input: any, context: any): (Content, boolean)
	local descriptor = byName[name]
	if descriptor == nil then
		return "unknown tool: " .. tostring(name), true
	end
	-- Subagent allowlist: when a context carries `allowedTools`, a tool NOT in the set is rejected
	-- WITHOUT running. An allowlist (not a destructive-flag check) is required because
	-- dispatch_subagents is itself non-destructive — only an allowlist blocks both writers AND nesting.
	if
		type(context) == "table"
		and type(context.allowedTools) == "table"
		and not context.allowedTools[name]
	then
		return "'" .. tostring(name) .. "' is not permitted for this subagent", true
	end
	local ok, content, isError = pcall(descriptor.run, input, context)
	if not ok then
		return "tool handler error: " .. tostring(content), true
	end
	if type(content) ~= "string" and type(content) ~= "table" then
		return tostring(content), isError == true
	end
	return content, isError == true
end

return Tools
