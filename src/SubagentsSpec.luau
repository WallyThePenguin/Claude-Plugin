--!strict
-- SubagentsSpec: in-Studio self-test for the PURE subagent pieces (no network). Run via temporarily
-- adding `require(script.SubagentsSpec).run()` to init.server.luau, build, reopen Studio, read Output.

local Tools = require(script.Parent.Tools)

local M = {}

local READ_ONLY = { "get_tree", "search", "get_properties", "get_output", "capture" }

local function allowedSet(): { [string]: boolean }
	local a: { [string]: boolean } = {}
	for _, n in READ_ONLY do
		a[n] = true
	end
	return a
end

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("schemasFor returns exactly the read-only set", function()
		local s = (Tools :: any).schemasFor(READ_ONLY)
		if #s ~= #READ_ONLY then
			return false, "got " .. tostring(#s) .. " schemas"
		end
		local names: { [string]: boolean } = {}
		for _, t in s do
			names[t.name] = true
		end
		for _, n in READ_ONLY do
			if not names[n] then
				return false, "missing " .. n
			end
		end
		return true
	end)

	add("schemasFor excludes writers and dispatch_subagents", function()
		local s = (Tools :: any).schemasFor(READ_ONLY)
		for _, t in s do
			if
				t.name == "create_instance"
				or t.name == "run_luau"
				or t.name == "set_property"
				or t.name == "dispatch_subagents"
			then
				return false, "leaked " .. t.name
			end
		end
		return true
	end)

	add("dispatch allowlist rejects a writer (create_instance)", function()
		local _, isError = Tools.dispatch(
			"create_instance",
			{ className = "Part" },
			{ allowedTools = allowedSet() }
		)
		return isError == true
	end)

	add("dispatch allowlist rejects dispatch_subagents (depth-1)", function()
		local _, isError = Tools.dispatch(
			"dispatch_subagents",
			{ subagents = {} },
			{ allowedTools = allowedSet() }
		)
		return isError == true
	end)

	add("dispatch allowlist allows a read tool (get_tree)", function()
		local text, isError = Tools.dispatch(
			"get_tree",
			{ path = "game", depth = 0 },
			{ allowedTools = allowedSet() }
		)
		return isError == false and type(text) == "string"
	end)

	add("dispatch without allowlist still permits a read (parent path unchanged)", function()
		-- No allowedTools in context -> the guard does not apply. get_tree must still work normally.
		local _, isError = Tools.dispatch(
			"get_tree",
			{ path = "game", depth = 0 },
			{ config = nil }
		)
		return isError == false
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== SubagentsSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print(
		"=== Summary: "
			.. tostring(passed)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)
	return { passed = failed == 0, total = total, failed = failed }
end

return M
