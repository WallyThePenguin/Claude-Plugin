--!strict
-- Tree: two structured tools for exploring the data model — get_tree and search.
--
-- Both build a result TABLE and JSONEncode it into the contentText, returning isError per the
-- success/failure of the underlying operation (the uniform structured-tool contract). A resolve miss
-- is a clean {ok=false, error=...} with isError=true; it never throws.
--
-- This is a Tools/ submodule. It reaches Path via require(script.Parent.Path).

local HttpService = game:GetService("HttpService")

local Path = require(script.Parent.Path)

local Tree = {}

-- Mirror the registry's Descriptor shape (init.luau owns the canonical type; this matches it so the
-- exported list concatenates cleanly).
export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any) -> (string, boolean),
}

local DEFAULT_TREE_PATH = "game.Workspace"
local DEFAULT_DEPTH = 2
local DEFAULT_MAX_NODES = 500
local DEFAULT_SEARCH_ROOT = "game.Workspace"
local DEFAULT_MAX_RESULTS = 100

-- Encode a result table into compact JSON. Total: JSONEncode can only throw on values it cannot
-- represent, and we feed it plain string/number/bool/array/dict trees, so a pcall fallback keeps the
-- tool from ever leaving a tool_use without a tool_result.
local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

-- Coerce an optional numeric input that may arrive as a JSON number or numeric string, falling back
-- to a default when absent or unusable. Clamped to >= 0 (callers add their own minimums).
local function numberOr(value: any, fallback: number): number
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local parsed = tonumber(value)
		if parsed ~= nil then
			return parsed
		end
	end
	return fallback
end

-- get_tree: depth- and node-capped structural snapshot rooted at a resolved path.
local function runGetTree(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}

	local pathArg = if type(args.path) == "string" then args.path else DEFAULT_TREE_PATH
	local depth = math.max(0, math.floor(numberOr(args.depth, DEFAULT_DEPTH)))
	local maxNodes = math.max(1, math.floor(numberOr(args.maxNodes, DEFAULT_MAX_NODES)))

	local root, err = Path.resolve(pathArg)
	if root == nil then
		return encodeResult({ ok = false, error = err }), true
	end

	local nodeCount = 0
	local truncated = false

	-- Recursively build {class, name, children}. Per-node full paths are OMITTED (the nesting
	-- structure already implies the path); only the root carries an explicit "path" field (added by
	-- the caller below). Honors both the depth cap and the global node budget.
	local function build(inst: Instance, remainingDepth: number): { [string]: any }
		local node: { [string]: any } = {
			class = inst.ClassName,
			name = inst.Name,
		}

		if remainingDepth <= 0 then
			return node
		end

		local children: { any } = {}
		for _, child in inst:GetChildren() do
			if nodeCount >= maxNodes then
				truncated = true
				break
			end
			nodeCount += 1
			table.insert(children, build(child, remainingDepth - 1))
		end
		if #children > 0 then
			node.children = children
		end
		return node
	end

	-- The root counts as the first node.
	nodeCount = 1
	local rootNode = build(root :: Instance, depth)
	rootNode.path = Path.fullPath(root :: Instance)

	return encodeResult({
		ok = true,
		root = rootNode,
		truncated = truncated,
	}), false
end

-- search: BFS over descendants of a resolved root, filtered by case-insensitive name substring
-- and/or className (via IsA), capped at maxResults.
local function runSearch(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}

	local rootArg = if type(args.root) == "string" then args.root else DEFAULT_SEARCH_ROOT
	local nameNeedle = if type(args.name) == "string" then args.name else nil
	local classNeedle = if type(args.className) == "string" then args.className else nil
	local maxResults = math.max(1, math.floor(numberOr(args.maxResults, DEFAULT_MAX_RESULTS)))

	local root, err = Path.resolve(rootArg)
	if root == nil then
		return encodeResult({ ok = false, error = err }), true
	end

	local lowerName = if nameNeedle ~= nil then string.lower(nameNeedle) else nil

	local results: { any } = {}

	-- IsA(className) returns FALSE (does NOT throw) for an unknown class string, so an unrecognized
	-- className simply matches nothing and we return {ok=true, results={}} rather than an error.
	-- Wrapped in pcall anyway to stay total against any future edge.
	local function classMatches(inst: Instance): boolean
		if classNeedle == nil then
			return true
		end
		local ok, isa = pcall(function(): boolean
			return inst:IsA(classNeedle :: string)
		end)
		return ok and isa
	end

	local function nameMatches(inst: Instance): boolean
		if lowerName == nil then
			return true
		end
		return string.find(string.lower(inst.Name), lowerName, 1, true) ~= nil
	end

	-- GetDescendants gives the full subtree in a deterministic pre-order; iterate and collect until
	-- the result cap is hit. (Equivalent coverage to an explicit BFS for matching purposes.)
	for _, inst in (root :: Instance):GetDescendants() do
		if #results >= maxResults then
			break
		end
		if nameMatches(inst) and classMatches(inst) then
			table.insert(results, {
				class = inst.ClassName,
				name = inst.Name,
				path = Path.fullPath(inst),
			})
		end
	end

	return encodeResult({ ok = true, results = results }), false
end

local AMBIGUITY_NOTE = "Paths are case-sensitive and dot-separated (e.g. 'game.Workspace.Part'). "
	.. "Instances whose Name contains a '.', or several siblings sharing one Name, are ambiguous "
	.. "and CANNOT be addressed here — use run_luau for those."

-- Exported descriptor list; init.luau concatenates it into the master registry.
Tree.descriptors = {
	{
		name = "get_tree",
		description = "Return a depth- and node-capped tree {class, name, children} of the data "
			.. "model rooted at a path. Defaults: path 'game.Workspace', depth 2, maxNodes 500. "
			.. "Only the root node carries an explicit path; child paths are implied by nesting. "
			.. "Sets truncated=true if the node cap is reached. "
			.. AMBIGUITY_NOTE,
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Dot-separated, case-sensitive root path. Default 'game.Workspace'.",
				},
				depth = {
					type = "number",
					description = "How many levels of children to include. Default 2.",
				},
				maxNodes = {
					type = "number",
					description = "Maximum total nodes to emit before truncating. Default 500.",
				},
			},
		},
		destructive = false,
		run = runGetTree,
	},
	{
		name = "search",
		description = "Search descendants under a root for instances matching a case-insensitive "
			.. "name substring and/or a className (via IsA). Defaults: root 'game.Workspace', "
			.. "maxResults 100. An unknown className matches nothing (returns an empty result set, "
			.. "NOT an error). Each result is {class, name, path}. "
			.. AMBIGUITY_NOTE,
		inputSchema = {
			type = "object",
			properties = {
				root = {
					type = "string",
					description = "Dot-separated, case-sensitive root path. Default 'game.Workspace'.",
				},
				name = {
					type = "string",
					description = "Case-insensitive substring matched against each instance's Name.",
				},
				className = {
					type = "string",
					description = "Filter to instances where inst:IsA(className) is true.",
				},
				maxResults = {
					type = "number",
					description = "Maximum results to return. Default 100.",
				},
			},
		},
		destructive = false,
		run = runSearch,
	},
} :: { Descriptor }

return Tree
