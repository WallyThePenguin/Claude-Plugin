--!strict
-- AnimationImportSpec: in-Studio self-test for the PURE retarget-coverage logic (no DataModel). Run via
-- temporarily adding `require(script.AnimationImportSpec).run()` to init.server.luau.

local AnimationImport = require(script.Parent.AnimationImport)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("coverage full match: all target joints matched, nothing dropped", function()
		local cov = AnimationImport.coverage({ "A", "B", "C" }, { "A", "B", "C" })
		return cov.matched == 3 and cov.total == 3 and #cov.droppedSource == 0
	end)

	add("coverage partial: extra source name dropped, missing target unmatched", function()
		-- source animates A,B,X; target has A,B,C -> matched A,B (2/3); X dropped
		local cov = AnimationImport.coverage({ "A", "B", "X" }, { "A", "B", "C" })
		if cov.matched ~= 2 or cov.total ~= 3 then
			return false, "counts " .. tostring(cov.matched) .. "/" .. tostring(cov.total)
		end
		if #cov.droppedSource ~= 1 or cov.droppedSource[1] ~= "X" then
			return false, "dropped wrong"
		end
		return true
	end)

	add("coverage empty source -> 0 matched, none dropped", function()
		local cov = AnimationImport.coverage({}, { "A", "B" })
		return cov.matched == 0 and cov.total == 2 and #cov.droppedSource == 0
	end)

	add("coverage de-dups dropped + target", function()
		local cov = AnimationImport.coverage({ "X", "X", "Y" }, { "Z", "Z" })
		if cov.matched ~= 0 or cov.total ~= 1 then
			return false, "total should de-dup to 1"
		end
		if
			#cov.droppedSource ~= 2
			or cov.droppedSource[1] ~= "X"
			or cov.droppedSource[2] ~= "Y"
		then
			return false, "dropped should be X,Y once each"
		end
		return true
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[AnimationImportSpec] PASS " .. c.name)
		else
			warn("[AnimationImportSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[AnimationImportSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
