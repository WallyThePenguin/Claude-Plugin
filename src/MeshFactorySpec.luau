--!strict
-- MeshFactorySpec: in-Studio self-test for the PURE MeshFactory helpers (no DataModel). Run via
-- `require(script.MeshFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'.

local MeshFactory = require(script.Parent.MeshFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("coneGeometry vertex/triangle counts", function()
		local g = MeshFactory.coneGeometry(2, 5, 8)
		if #g.vertices ~= 10 then
			return false, "verts=" .. #g.vertices
		end
		if #g.triangles ~= 16 then
			return false, "tris=" .. #g.triangles
		end
		return true
	end)

	add("coneGeometry apex + base center positions", function()
		local g = MeshFactory.coneGeometry(2, 5, 8)
		return g.vertices[1] == Vector3.new(0, 5, 0) and g.vertices[2] == Vector3.new(0, 0, 0)
	end)

	add("coneGeometry ring sits at y=0 with radius", function()
		local g = MeshFactory.coneGeometry(3, 4, 6)
		return math.abs(g.vertices[3].Magnitude - 3) < 0.001 and math.abs(g.vertices[3].Y) < 0.001
	end)

	add("scaleFactorForHeight", function()
		return MeshFactory.scaleFactorForHeight(2, 10) == 5
			and MeshFactory.scaleFactorForHeight(0, 10) == 1
	end)

	add("rockClusterLayout: 3 pieces, deterministic by seed, seed varies output", function()
		local a = MeshFactory.rockClusterLayout(3, 7)
		local b = MeshFactory.rockClusterLayout(3, 7)
		local c = MeshFactory.rockClusterLayout(3, 9)
		if #a ~= 3 then
			return false, "count=" .. #a
		end
		if a[1].size ~= b[1].size or a[2].rot ~= b[2].rot then
			return false, "not deterministic"
		end
		if a[1].size == c[1].size then
			return false, "seed had no effect"
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
			print("[MeshFactorySpec] PASS " .. c.name)
		else
			warn("[MeshFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[MeshFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
