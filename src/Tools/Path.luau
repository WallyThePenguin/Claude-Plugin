--!strict
-- Path: dotted instance-path resolution shared by the structured property/tree tools.
--
-- This is a Tools/ submodule. It reaches no top-level siblings, but its Tools siblings (Tree,
-- Properties) require it via require(script.Parent.Path).
--
-- A path is a CASE-SENSITIVE, dot-separated string of child names, e.g.
--   "game.Workspace.Baseplate"  /  "workspace.Model.Part".
--
-- AMBIGUITY (documented, intentional): this resolver cannot address
--   * instances whose .Name itself contains a "." (the dotted name is split on every "."), nor
--   * a specific sibling when several siblings share the same .Name (FindFirstChild returns the
--     FIRST match in child order, which is not stable across edits).
-- The tool schemas tell Claude to fall back to run_luau (which can index by reference / GetChildren
-- and filter) for those cases. resolve() never throws — it returns (nil, errMessage) on any miss.

local M = {}

-- Resolve a dotted path to a live Instance.
--   success -> (instance, nil)
--   failure -> (nil, errMessage)   -- errMessage names the first segment that failed.
--
-- First-segment rules:
--   * "game" / "datamodel"  -> the DataModel (game) itself.
--   * "workspace"           -> game:GetService("Workspace") (Workspace is a known-valid service, so
--                              GetService is safe and side-effect-free here).
--   * anything else         -> game:FindService(seg) inside a pcall (FindService ERRORS on an invalid
--                              class name, hence the pcall), falling back to game:FindFirstChild(seg).
--                              We NEVER call game:GetService(seg) on arbitrary input: it errors on
--                              garbage AND creates the service as a side effect on a valid-but-absent
--                              service name.
--
-- Subsequent segments: parent:FindFirstChild(seg) (NEVER raw parent[seg] indexing, which would throw
-- on a missing child and could hit a property/method instead of a child). Case-sensitive; first
-- matching sibling wins.
function M.resolve(path: string): (Instance?, string?)
	if type(path) ~= "string" then
		return nil, "path must be a string"
	end
	if path == "" then
		return nil, "path is empty"
	end

	local segments: { string } = string.split(path, ".")
	if #segments == 0 then
		return nil, "path is empty"
	end

	local first = segments[1]
	local current: Instance?

	if first == "game" or first == "datamodel" then
		current = game
	elseif first == "workspace" then
		-- Workspace is a guaranteed service; GetService is safe and creates nothing new.
		current = game:GetService("Workspace")
	else
		-- Try FindService first (covers other services by their real name without creating them),
		-- guarded because FindService throws on an invalid class name. Fall back to a plain child
		-- lookup so non-service top-level instances (e.g. a renamed model parented to game) resolve.
		local okService, service = pcall(function(): Instance?
			return game:FindService(first)
		end)
		if okService and service ~= nil then
			current = service
		else
			current = game:FindFirstChild(first)
		end
	end

	if current == nil then
		return nil, "could not resolve first path segment: " .. first
	end

	for index = 2, #segments do
		local seg = segments[index]
		local nextChild = (current :: Instance):FindFirstChild(seg)
		if nextChild == nil then
			return nil,
				"no child named '" .. seg .. "' under " .. (current :: Instance):GetFullName()
		end
		current = nextChild
	end

	return current, nil
end

-- Human-facing full path for echoing back in tool results. GetFullName is fine for DISPLAY (it does
-- not escape periods, but it is never fed back into resolve()).
function M.fullPath(inst: Instance): string
	return inst:GetFullName()
end

return M
