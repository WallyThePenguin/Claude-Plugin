--!strict
-- Subagents: the dispatch_subagents tool. The parent agent fans out READ-ONLY child agents that run
-- IN PARALLEL (on the subagent model), each exploring/verifying/judging, and returns each child's
-- terse final text as one JSON tool_result. Children cannot mutate (allowlist enforced at
-- Tools.dispatch) and cannot nest (dispatch_subagents is not in their allowlist -> depth-1).
--
-- Tools/init requires this module at load to register the tool; the Subagent runner + the Tools
-- registry are required LAZILY inside run() to avoid a module-load require cycle.

local HttpService = game:GetService("HttpService")
local SystemPrompt = require(script.Parent.Parent.SystemPrompt)

local Subagents = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local READ_ONLY = { "get_tree", "search", "get_properties", "get_output", "capture" }

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"subagent result not JSON-encodable"}'
end

local function runDispatch(input: any, context: any): (string, boolean)
	local config = if type(context) == "table" then context.config else nil
	local anthropic = if type(context) == "table" then context.anthropic else nil
	if config == nil or anthropic == nil then
		return encodeResult({ ok = false, error = "dispatch_subagents: missing config/anthropic" }),
			true
	end

	local args = if type(input) == "table" then input else {}
	local subs = args.subagents
	if type(subs) ~= "table" or #subs == 0 then
		return encodeResult({
			ok = false,
			error = "dispatch_subagents requires { subagents = [ { role, prompt }, ... ] } (at least 1)",
		}),
			true
	end

	-- Lazy requires break the Tools <- Subagents <- Subagent <- Tools load-time cycle.
	local Tools = require(script.Parent)
	local Subagent = require(script.Parent.Parent.Subagent)

	local cap = config:getSubagentMaxParallel()
	local n = math.min(#subs, cap)
	local dropped = #subs - n

	local toolSchemas = (Tools :: any).schemasFor(READ_ONLY)
	local allowed: { [string]: boolean } = {}
	for _, name in READ_ONLY do
		allowed[name] = true
	end

	local model = config:getSubagentModel()
	local maxIter = config:getSubagentMaxIterations()
	local shouldCancel = if type(context) == "table" then context.shouldCancel else nil

	local results: { any } = {}
	local done = 0
	for i = 1, n do
		local sub = subs[i]
		local role = if type(sub) == "table" and type(sub.role) == "string"
			then sub.role
			else "subagent " .. i
		local prompt = if type(sub) == "table" and type(sub.prompt) == "string"
			then sub.prompt
			else ""
		task.spawn(function()
			-- The WHOLE body is pcall-wrapped (incl. buildSubagent) so `done` always increments — a
			-- throw before `done += 1` would otherwise hang the join (`while done < n`) forever.
			local ok, res = pcall(function()
				return (Subagent :: any).run({
					anthropic = anthropic,
					config = config,
					systemPrompt = SystemPrompt.buildSubagent(role),
					taskPrompt = prompt,
					toolSchemas = toolSchemas,
					allowedTools = allowed,
					model = model,
					maxIterations = maxIter,
					shouldCancel = shouldCancel,
				})
			end)
			if ok and type(res) == "table" then
				results[i] = { role = role, ok = res.ok, capped = res.capped, text = res.text }
			else
				results[i] = {
					role = role,
					ok = false,
					capped = false,
					text = "subagent error: " .. tostring(res),
				}
			end
			done += 1
		end)
	end

	-- Join. The parent loop is yielding here, so it is NOT writing -> the DataModel is quiescent for
	-- the children's reads. Cooperative scheduling means results[i] writes never interleave.
	while done < n do
		task.wait()
	end

	local out: { any } = {}
	for i = 1, n do
		out[i] = results[i]
	end
	local payload: { [string]: any } = { ok = true, count = n, results = out }
	if dropped > 0 then
		payload.dropped = dropped
	end
	return encodeResult(payload), false
end

Subagents.descriptors = {
	{
		name = "dispatch_subagents",
		description = "Fan out READ-ONLY subagents that run IN PARALLEL to explore, analyze, verify, "
			.. "or judge, then return each one's final text report. Use for read-heavy or "
			.. "parallelizable work: several finders over different areas at once; an adversarial "
			.. "verifier to independently double-check something YOU just built; or a judge panel for "
			.. "a design decision. Children CANNOT modify anything (you do all building) and cannot "
			.. "spawn their own subagents. Each child sees NONE of your context — give it a "
			.. "self-contained `prompt` and a short `role`, and expect a terse text report back.",
		inputSchema = {
			type = "object",
			properties = {
				subagents = {
					type = "array",
					description = "One or more read-only children to run in parallel.",
					items = {
						type = "object",
						properties = {
							role = {
								type = "string",
								description = "Short label, e.g. 'gui-auditor'.",
							},
							prompt = {
								type = "string",
								description = "Self-contained task for this child (it sees none of your chat).",
							},
						},
						required = { "role", "prompt" },
					},
				},
			},
			required = { "subagents" },
		},
		destructive = false,
		run = runDispatch,
	},
} :: { Descriptor }

return Subagents
