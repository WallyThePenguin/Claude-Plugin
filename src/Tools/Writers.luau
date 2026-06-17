--!strict
-- Writers: the dispatch_writers tool. Fans out PARALLEL WRITER children, each CONFINED to a region
-- subtree, to build independent parts of the place at once. The speedup is overlapping LLM round-trips
-- (the DataModel writes themselves are instant). Each child runs the Subagent loop with the structured
-- WRITE toolset + a region guard (context.writeRegion) — NO run_luau (can't be region-guarded) and NO
-- nesting (depth-1, enforced by the allowlist). Safe under Luau's cooperative scheduling because the
-- structured write tools are synchronous, so their ChangeHistory recordings are atomic (never overlap).
--
-- Tools/init requires this at load to register the tool; the Subagent runner, the Tools registry, and
-- Path are required LAZILY inside run() to avoid a module-load require cycle.

local HttpService = game:GetService("HttpService")
local SystemPrompt = require(script.Parent.Parent.SystemPrompt)

local Writers = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

-- Writer children get the structured WRITE tools + the read tools. NOT run_luau (arbitrary Luau can't
-- be region-guarded), NOT dispatch_* (depth-1).
local WRITE_TOOLS = {
	"create_instance",
	"set_property",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"capture",
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"writer result not JSON-encodable"}'
end

local function runDispatch(input: any, context: any): (string, boolean)
	local config = if type(context) == "table" then context.config else nil
	local anthropic = if type(context) == "table" then context.anthropic else nil
	if config == nil or anthropic == nil then
		return encodeResult({ ok = false, error = "dispatch_writers: missing config/anthropic" }),
			true
	end

	local args = if type(input) == "table" then input else {}
	local list = args.writers
	if type(list) ~= "table" or #list == 0 then
		return encodeResult({
			ok = false,
			error = "dispatch_writers requires { writers = [ { region, task }, ... ] } (at least 1)",
		}),
			true
	end

	-- Lazy requires break the Tools <- Writers <- Subagent <- Tools load-time cycle.
	local Tools = require(script.Parent)
	local Subagent = require(script.Parent.Parent.Subagent)
	local Path = require(script.Parent.Path)

	local cap = config:getWriterMaxParallel()
	local n = math.min(#list, cap)
	local dropped = #list - n

	local toolSchemas = (Tools :: any).schemasFor(WRITE_TOOLS, config)
	local allowed: { [string]: boolean } = {}
	for _, name in WRITE_TOOLS do
		allowed[name] = true
	end

	local model = config:getWriterModel()
	local maxIter = config:getWriterMaxIterations()
	local shouldCancel = if type(context) == "table" then context.shouldCancel else nil

	-- Resolve + VALIDATE every region UP FRONT, before spawning any child. The feature's safety rests
	-- on regions being specific containers AND mutually disjoint — neither can be assumed from model
	-- input, so enforce both here and reject the WHOLE dispatch on a violation (the parent re-partitions).
	-- Path.resolve is synchronous, so resolving here (not in the workers) introduces no yield.
	local entries: { { path: string, region: Instance, task: string } } = {}
	for i = 1, n do
		local w = list[i]
		local regionPath = if type(w) == "table" and type(w.region) == "string"
			then w.region
			else ""
		local taskPrompt = if type(w) == "table" and type(w.task) == "string" then w.task else ""
		local region, rerr = (Path :: any).resolve(regionPath)
		if region == nil then
			return encodeResult({
				ok = false,
				error = "writer " .. i .. ": region not found: " .. tostring(rerr),
			}),
				true
		end
		-- Breadth: a region must be a specific container (depth >= 2 under game) the parent created —
		-- NOT the DataModel root or a bare top-level service, which would make the guard a no-op.
		if region == game or region.Parent == game then
			return encodeResult({
				ok = false,
				error = "writer "
					.. i
					.. " region '"
					.. regionPath
					.. "' is too broad — give each writer a specific container you created (not the "
					.. "DataModel root or a whole service)",
			}),
				true
		end
		entries[i] = { path = regionPath, region = region, task = taskPrompt }
	end
	-- Disjointness: no two regions may be equal or nested (one a descendant of the other), else two
	-- writers share a subtree and their edits logically race across HTTP yield points.
	for a = 1, n do
		for b = a + 1, n do
			local ra, rb = entries[a].region, entries[b].region
			if ra == rb or ra:IsDescendantOf(rb) or rb:IsDescendantOf(ra) then
				return encodeResult({
					ok = false,
					error = "writer regions '"
						.. entries[a].path
						.. "' and '"
						.. entries[b].path
						.. "' overlap — each writer needs a DISJOINT region",
				}),
					true
			end
		end
	end

	local results: { any } = {}
	local done = 0
	for i = 1, n do
		local entry = entries[i]
		task.spawn(function()
			-- Whole body pcall-wrapped so `done` always increments and the join can't hang on a throw.
			local ok, res = pcall(function()
				local out = (Subagent :: any).run({
					anthropic = anthropic,
					config = config,
					systemPrompt = SystemPrompt.buildWriter(entry.path, entry.task),
					taskPrompt = entry.task,
					toolSchemas = toolSchemas,
					allowedTools = allowed,
					model = model,
					maxIterations = maxIter,
					shouldCancel = shouldCancel,
					writeRegion = entry.region,
				})
				return { region = entry.path, ok = out.ok, capped = out.capped, text = out.text }
			end)
			if ok and type(res) == "table" then
				results[i] = res
			else
				results[i] = {
					region = entry.path,
					ok = false,
					capped = false,
					text = "writer error: " .. tostring(res),
				}
			end
			done += 1
		end)
	end

	-- Join. The parent loop is yielding here, so it is NOT writing -> the DataModel is quiescent for
	-- the children's edits. Cooperative scheduling means results[i] writes never interleave.
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

Writers.descriptors = {
	{
		name = "dispatch_writers",
		description = "Fan out PARALLEL WRITER subagents to build INDEPENDENT parts of the place at the "
			.. "same time — use this to go faster on a LARGE build with separable pieces. Each child is "
			.. "CONFINED to its `region` (a case-sensitive dot-path that must ALREADY EXIST — create the "
			.. "container instance first) and may ONLY create/edit instances inside it with "
			.. "create_instance/set_property (NO run_luau, NO nesting). Give each a self-contained "
			.. "`task` (it sees none of your chat). After they return, do any cross-region wiring "
			.. "yourself and verify. Don't use this for a small or tightly-coupled build — just build "
			.. "that yourself.",
		inputSchema = {
			type = "object",
			properties = {
				writers = {
					type = "array",
					description = "One or more writer children, each confined to its region, run in parallel.",
					items = {
						type = "object",
						properties = {
							region = {
								type = "string",
								description = "Existing dot-path the child is fenced to, e.g. 'game.StarterGui.Shop'.",
							},
							task = {
								type = "string",
								description = "Self-contained build task for this region (it sees none of your chat).",
							},
						},
						required = { "region", "task" },
					},
				},
			},
			required = { "writers" },
		},
		destructive = true,
		run = runDispatch,
	},
} :: { Descriptor }

return Writers
