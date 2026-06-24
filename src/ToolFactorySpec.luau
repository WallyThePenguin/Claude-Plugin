--!strict
-- ToolFactorySpec: in-Studio self-test for the PURE ToolFactory.gripCFrame (no DataModel). Run via
-- `require(script.ToolFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.ToolFactorySpec).run())'.

local ToolFactory = require(script.Parent.ToolFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("gripCFrame: identity default", function()
		local g = ToolFactory.gripCFrame(nil, nil)
		return g.Position == Vector3.new(0, 0, 0)
	end)

	add("gripCFrame: offset -> position", function()
		local g = ToolFactory.gripCFrame({ x = 1, y = 2, z = 3 }, nil)
		return g.Position == Vector3.new(1, 2, 3)
	end)

	add("gripCFrame: a Y rotation reorients (-Z maps to +/-X, Y unchanged)", function()
		local g = ToolFactory.gripCFrame(nil, { ry = 90 })
		local v = g:VectorToWorldSpace(Vector3.new(0, 0, -1))
		if math.abs(v.Y) > 0.01 then
			return false, "Y not preserved: " .. tostring(v.Y)
		end
		if math.abs(math.abs(v.X) - 1) > 0.01 or math.abs(v.Z) > 0.01 then
			return false, "did not map -Z to +/-X: " .. tostring(v)
		end
		return true
	end)

	add("gripCFrame: partial fields default to 0 (offset y only; rot rx only)", function()
		local g = ToolFactory.gripCFrame({ y = 5 }, { rx = 45 })
		if g.Position ~= Vector3.new(0, 5, 0) then
			return false, "offset partial wrong: " .. tostring(g.Position)
		end
		-- only rx set -> a pure X-axis rotation leaves the world X axis unchanged (ry/rz defaulted to 0)
		local vx = g:VectorToWorldSpace(Vector3.new(1, 0, 0))
		if math.abs(vx.X - 1) > 0.01 or math.abs(vx.Y) > 0.01 or math.abs(vx.Z) > 0.01 then
			return false, "rot not pure-X (ry/rz didn't default): " .. tostring(vx)
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
			print("[ToolFactorySpec] PASS " .. c.name)
		else
			warn("[ToolFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[ToolFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
