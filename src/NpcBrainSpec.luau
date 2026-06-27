--!strict
-- NpcBrainSpec: in-Studio self-test for the PURE NpcBrain perception logic (roadmap #5). Run via the bridge:
-- luau 'return tostring(require(script.Parent.NpcBrainSpec).run())'.

local NpcBrain = require(script.Parent.NpcBrain)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("no target -> idle", function()
		return NpcBrain.decideState(nil, 40, 6) == "idle", "nil dist should be idle"
	end)

	add("far beyond detect -> idle", function()
		return NpcBrain.decideState(100, 40, 6) == "idle", "100 > detect 40 should be idle"
	end)

	add("within detect, beyond attack -> chase", function()
		return NpcBrain.decideState(20, 40, 6) == "chase", "20 in (6,40] should be chase"
	end)

	add("within attack -> attack", function()
		return NpcBrain.decideState(4, 40, 6) == "attack", "4 <= attack 6 should be attack"
	end)

	add("boundaries: == attackRange -> attack, == detectRange -> chase", function()
		if NpcBrain.decideState(6, 40, 6) ~= "attack" then
			return false, "dist == attackRange should be attack"
		end
		if NpcBrain.decideState(40, 40, 6) ~= "chase" then
			return false, "dist == detectRange should be chase"
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
			print("[NpcBrainSpec] PASS " .. c.name)
		else
			warn("[NpcBrainSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[NpcBrainSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
