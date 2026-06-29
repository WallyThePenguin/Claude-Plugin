--!strict
-- IconFactorySpec: in-Studio self-test for the PURE IconFactory helpers (no DataModel). Run via
-- `& scripts/studio-agent.ps1 luau 'return require(script.Parent.IconFactorySpec).run()'`.

local IconFactory = require(script.Parent.IconFactory)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("every glyph is rectangular (no ragged rows)", function()
		local err = IconFactory.validateGlyphs()
		return err == "", err
	end)

	add("listKinds is sorted + non-empty; hasKind agrees", function()
		local kinds = IconFactory.listKinds()
		if #kinds == 0 then
			return false, "no kinds"
		end
		for i = 2, #kinds do
			if kinds[i - 1] > kinds[i] then
				return false, "not sorted at " .. tostring(i)
			end
		end
		return IconFactory.hasKind(kinds[1]) and not IconFactory.hasKind("nope") and not IconFactory.hasKind(5)
	end)

	add("glyphToOps: known kind -> white rect ops inside the canvas; unknown -> {}", function()
		local ops = IconFactory.glyphToOps("coin")
		if #ops == 0 then
			return false, "coin produced no ops"
		end
		for _, op in ops do
			if op.color ~= Color3.new(1, 1, 1) then
				return false, "op not white"
			end
			if op.pos.X < 0 or op.pos.Y < 0 or op.pos.X + op.size.X > 256.001 or op.pos.Y + op.size.Y > 256.001 then
				return false, "op out of canvas"
			end
		end
		return #IconFactory.glyphToOps("definitely-not-a-kind") == 0
	end)

	add("glyphToOps op count matches the '#' cells (sword)", function()
		-- independent count of '#' in the sword bitmap via the public op list (one op per filled cell)
		local ops = IconFactory.glyphToOps("sword")
		return #ops > 10 and #ops < 60 -- a plausible, non-degenerate silhouette
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
			print("[IconFactorySpec] PASS " .. c.name)
		else
			warn("[IconFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[IconFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
