--!strict
-- GameSyncSpec: the pure surface of GameSync (suffixes, sanitization, relpaths, hashing,
-- test-symbol + collision detection). The impure pull is live-verified via the bridge.

local GameSync = require(script.Parent.GameSync)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("kindSuffix per class", function()
		return GameSync.kindSuffix("Script") == ".server.luau"
			and GameSync.kindSuffix("LocalScript") == ".client.luau"
			and GameSync.kindSuffix("ModuleScript") == ".luau"
	end)

	add("sanitizeSegment: illegal chars, trailing dots, reserved names, empty", function()
		local a = GameSync.sanitizeSegment('My:Script*Name?')
		if a ~= "My_Script_Name_" then
			return false, "got " .. tostring(a)
		end
		local b = GameSync.sanitizeSegment("Trailing. ")
		if b ~= "Trailing" then
			return false, "trailing got " .. tostring(b)
		end
		local c = GameSync.sanitizeSegment("CON")
		if c ~= "rbx_CON" then
			return false, "reserved got " .. tostring(c)
		end
		-- Illegal chars become "_" (a valid segment): "///" -> "___", not empty.
		local d = GameSync.sanitizeSegment("///")
		if d ~= "___" then
			return false, "slashes got " .. tostring(d)
		end
		-- Only a name that strips to NOTHING falls back to "unnamed".
		local e = GameSync.sanitizeSegment("...")
		return e == "unnamed"
	end)

	add("relpathFor: nested chain + suffix + changed flag", function()
		local p, changed = GameSync.relpathFor(
			{ "StarterPack", "UseSword", "ItemHitClient" },
			"LocalScript"
		)
		if p ~= "src/StarterPack/UseSword/ItemHitClient.client.luau" or changed then
			return false, tostring(p)
		end
		local q, changed2 = GameSync.relpathFor({ "Workspace", "A:B", "Run" }, "Script")
		return q == "src/Workspace/A_B/Run.server.luau" and changed2 == true
	end)

	add("hashSource: deterministic, content-sensitive", function()
		local h1 = GameSync.hashSource("local a = 1")
		return h1 == GameSync.hashSource("local a = 1")
			and h1 ~= GameSync.hashSource("local a = 2")
			and string.len(h1) == 8
	end)

	add("findTestSymbols: reserved prefix + legacy denylist, deduped", function()
		local src = 'x = GetAttribute("TestAutoKill") -- StudioAgentTest_Marker + StudioAgentTest_Marker'
		local syms = GameSync.findTestSymbols(src)
		return #syms == 2
			and syms[1] == "StudioAgentTest_Marker"
			and syms[2] == "TestAutoKill"
	end)

	add("findTestSymbols: clean source -> {}", function()
		return #GameSync.findTestSymbols("local kill = testAuto .. 'x'") == 0
	end)

	add("findCollisions: case-insensitive twins detected; clean set passes", function()
		local groups = GameSync.findCollisions({
			"src/A/WaveConfig.luau",
			"src/A/waveconfig.luau",
			"src/B/Other.luau",
		})
		if #groups ~= 1 or #groups[1] ~= 2 then
			return false, "groups " .. tostring(#groups)
		end
		return #GameSync.findCollisions({ "src/A/x.luau", "src/B/x.luau" }) == 0
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== GameSyncSpec: running " .. tostring(total) .. " cases ===")
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
