--!strict
-- WritersSpec: in-Studio self-test for the PURE/structural pieces of dispatch_writers — the writer
-- toolset/allowlist and the RegionGuard. Run via temporarily adding `require(script.WritersSpec).run()`
-- to init.server.luau, build, reopen Studio, read Output.

local Tools = require(script.Parent.Tools)
local RegionGuard = require(script.Parent.Tools.RegionGuard)

local M = {}

local WRITE_TOOLS = {
	"create_instance",
	"set_property",
	"get_tree",
	"search",
	"get_properties",
	"get_output",
	"capture",
}

local function allowedSet(): { [string]: boolean }
	local a: { [string]: boolean } = {}
	for _, n in WRITE_TOOLS do
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

	add("schemasFor returns exactly the writer toolset", function()
		local s = (Tools :: any).schemasFor(WRITE_TOOLS)
		if #s ~= #WRITE_TOOLS then
			return false, "got " .. tostring(#s) .. " schemas"
		end
		local names: { [string]: boolean } = {}
		for _, t in s do
			names[t.name] = true
		end
		for _, n in WRITE_TOOLS do
			if not names[n] then
				return false, "missing " .. n
			end
		end
		return true
	end)

	add("writer toolset excludes run_luau and the dispatch tools", function()
		local s = (Tools :: any).schemasFor(WRITE_TOOLS)
		for _, t in s do
			if
				t.name == "run_luau"
				or t.name == "dispatch_subagents"
				or t.name == "dispatch_writers"
			then
				return false, "leaked " .. t.name
			end
		end
		return true
	end)

	add("dispatch allowlist rejects run_luau for a writer context", function()
		local _, isError = Tools.dispatch(
			"run_luau",
			{ code = "return 1" },
			{ allowedTools = allowedSet() }
		)
		return isError == true
	end)

	add("dispatch allowlist rejects dispatch_writers (depth-1)", function()
		local _, isError = Tools.dispatch(
			"dispatch_writers",
			{ writers = {} },
			{ allowedTools = allowedSet() }
		)
		return isError == true
	end)

	add("dispatch allowlist allows a read tool (get_tree)", function()
		local _, isError = Tools.dispatch(
			"get_tree",
			{ path = "game", depth = 0 },
			{ allowedTools = allowedSet() }
		)
		return isError == false
	end)

	add("RegionGuard.within: region root, descendant, and outside", function()
		local region = Instance.new("Folder")
		local child = Instance.new("Part")
		child.Parent = region
		local outside = Instance.new("Part")
		local ok = RegionGuard.within(region, region) == true
			and RegionGuard.within(child, region) == true
			and RegionGuard.within(outside, region) == false
		region:Destroy()
		outside:Destroy()
		return ok
	end)

	add("RegionGuard.check: no region is a no-op; within passes; outside fails", function()
		local region = Instance.new("Folder")
		local child = Instance.new("Part")
		child.Parent = region
		local outside = Instance.new("Part")
		local noRegionOk = RegionGuard.check(outside, {}) == true -- no writeRegion -> allowed
		local withinOk = RegionGuard.check(child, { writeRegion = region }) == true
		local outsideOk, msg = RegionGuard.check(outside, { writeRegion = region })
		region:Destroy()
		outside:Destroy()
		return noRegionOk and withinOk and outsideOk == false and type(msg) == "string"
	end)

	add("dispatch_writers is total on bad input (no config)", function()
		local _, isError = Tools.dispatch("dispatch_writers", { writers = {} }, { config = nil })
		return isError == true
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== WritersSpec: running " .. tostring(total) .. " cases ===")
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
