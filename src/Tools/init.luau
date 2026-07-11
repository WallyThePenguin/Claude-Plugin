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
-- create_instance, destroy_instance, place_relative, capture, capture_angles, capture_animation,
-- dispatch_subagents, update_tasks, remember, forget, dispatch_writers, use_skill, save_skill,
-- delete_skill, add_keyframe, list_clip, remove_keyframe, clear_clip, export_animation, evaluate, learn, unlearn,
-- import_animation, generate_mesh, author_mesh, save_mesh, confirm_mesh, paint_texture, make_tool, grip_tool, bind_animation.
-- web_fetch/web_search are NOT custom tools — they are Anthropic SERVER-side tools appended by
-- schemas()/schemasFor() (executed by the API, never dispatched locally; see SERVER_TOOL_TYPES below).

local RunLuau = require(script.RunLuau)
local Tree = require(script.Tree)
local PropertiesTool = require(script.Properties)
local OutputTool = require(script.Output)
local CreateTool = require(script.Create)
local CaptureTool = require(script.Capture)
local ReferencesTool = require(script.References)
local SubagentsTool = require(script.Subagents)
local TasksTool = require(script.Tasks)
local MemoryTool = require(script.Memory)
local LearningsTool = require(script.Learnings)
local WritersTool = require(script.Writers)
local SkillsTool = require(script.Skills)
-- NB: the module is DestroyInstance (NOT Destroy) — `script.Destroy` resolves to the built-in
-- Instance:Destroy method (methods shadow same-named children on dot-access), so requiring it errors.
local DestroyTool = require(script.DestroyInstance)
local PlaceTool = require(script.Place)
local RubricsTool = require(script.Rubrics)
local BuildGuidesTool = require(script.BuildGuides)
local CameraRigTool = require(script.CameraRig)
local RigTool = require(script.Rig)
local IkTool = require(script.Ik)
local AnimateTool = require(script.Animate)
local ImportTool = require(script.Import)
local EvaluateTool = require(script.Evaluate)
local MeshTool = require(script.Mesh)
local TextureTool = require(script.Texture)
local IconTool = require(script.Icon)
local ItemTool = require(script.Item)
local ItemAnimTool = require(script.ItemAnim)
local ItemBehaviorTool = require(script.ItemBehavior)
local ItemHitTool = require(script.ItemHit)
local NpcTool = require(script.Npc)
local ScriptsTool = require(script.Scripts)
local PlaytestTool = require(script.Playtest)
local GameSyncTool = require(script.GameSyncTool)
local OracleTool = require(script.Oracle)

local Tools = {}

-- A tool's content is USUALLY a string, but a tool may return a tool_result blocks array instead
-- (e.g. `capture` returns an image block). Anthropic's tool_result `content` accepts either form.
export type Content = string | { any }

-- `context` carries loop-level dependencies a tool may need at run time (config, anthropic). Most
-- tools ignore it; `capture` reads context.config for the sidecar URL.
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
for _, descriptor in ReferencesTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in SubagentsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in TasksTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in MemoryTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in LearningsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in WritersTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in SkillsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in DestroyTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in PlaceTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in RubricsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in BuildGuidesTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in CameraRigTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in RigTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in IkTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in AnimateTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ImportTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in EvaluateTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in MeshTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in TextureTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in IconTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ItemTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ItemAnimTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ItemBehaviorTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ItemHitTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in NpcTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in ScriptsTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in PlaytestTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in GameSyncTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end
for _, descriptor in OracleTool.descriptors :: { Descriptor } do
	table.insert(registry, descriptor)
end

local byName: { [string]: Descriptor } = {}
for _, descriptor in registry do
	byName[descriptor.name] = descriptor
end

-- Server-side web tools: executed by ANTHROPIC, not dispatched locally (see AgentLoop). Declared as
-- {type,name} entries with NO input_schema and NO run handler — the model emits a `server_tool_use`
-- block and the API inserts the matching `*_tool_result` block into the same assistant turn. Use the
-- DIRECT versions: the code-execution-backed `_20260209` variants return `too_many_requests` on the
-- subscription path (the code-execution sandbox is quota-capped). `max_uses` bounds calls per turn.
local SERVER_TOOL_TYPES: { [string]: string } = {
	web_search = "web_search_20250305",
	web_fetch = "web_fetch_20250910",
}
-- Deterministic emission order (tools render at prompt position 0; a stable order keeps prompt
-- caching intact).
local SERVER_TOOLS_ORDER = { "web_search", "web_fetch" }
local DEFAULT_MAX_USES = 5

-- Build one server-tool entry, stamping `max_uses` from config when available (else a safe default,
-- so the web tools work even if a caller doesn't pass config).
local function serverToolEntry(name: string, config: any): any
	local maxUses = DEFAULT_MAX_USES
	if config ~= nil then
		if name == "web_search" then
			maxUses = config:getWebSearchMaxUses()
		elseif name == "web_fetch" then
			maxUses = config:getWebFetchMaxUses()
		end
	end
	return { type = SERVER_TOOL_TYPES[name], name = name, max_uses = maxUses }
end

-- The Anthropic `tools` payload: one {name, description, input_schema} per registered custom tool,
-- followed by the server-side web tools (stamped with max_uses from `config` when provided).
function Tools.schemas(config: any?): { any }
	local out: { any } = {}
	for _, descriptor in registry do
		table.insert(out, {
			name = descriptor.name,
			description = descriptor.description,
			input_schema = descriptor.inputSchema,
		})
	end
	for _, name in SERVER_TOOLS_ORDER do
		table.insert(out, serverToolEntry(name, config))
	end
	return out
end

-- Like schemas(), but filtered to a named subset (used to give a subagent a read-only toolset). A
-- requested name that is a SERVER tool (web_search/web_fetch) is emitted as its server-tool entry.
function Tools.schemasFor(names: { string }, config: any?): { any }
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
	for _, name in SERVER_TOOLS_ORDER do
		if want[name] then
			table.insert(out, serverToolEntry(name, config))
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
