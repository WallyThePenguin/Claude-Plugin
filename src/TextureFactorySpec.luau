--!strict
-- TextureFactorySpec: in-Studio self-test for the PURE TextureFactory generators (no DataModel). Run via
-- `require(script.TextureFactorySpec).run()` in init.server.luau, OR from the bridge:
-- luau 'return tostring(require(script.Parent.TextureFactorySpec).run())'.

local TextureFactory = require(script.Parent.TextureFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

-- Every pattern's first op is a full-tile background fill (the bg-first invariant).
local function bgIsFullTile(ops: { TextureFactory.DrawOp }, tile: number): boolean
	local bg = ops[1]
	return bg ~= nil and bg.pos == Vector2.new(0, 0) and bg.size == Vector2.new(tile, tile)
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	local A = Color3.fromRGB(10, 20, 30)
	local B = Color3.fromRGB(200, 210, 220)

	add("checkerPattern: bg-first + half the cells of a cols x cols grid", function()
		local ops = TextureFactory.checkerPattern(256, 4, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		if #ops ~= 9 then
			return false, "ops=" .. #ops
		end
		if ops[1].color ~= A or ops[2].color ~= B then
			return false, "colors wrong"
		end
		return true
	end)

	add("tilesPattern: bg-first + cols*cols inset tiles", function()
		local ops = TextureFactory.tilesPattern(256, 4, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		if #ops ~= 1 + 16 then
			return false, "ops=" .. #ops
		end
		if ops[2].size.X >= 64 then
			return false, "tile not inset"
		end
		return true
	end)

	add("planksPattern: bg-first + count planks, deterministic", function()
		local ops1 = TextureFactory.planksPattern(256, 5, A, B)
		local ops2 = TextureFactory.planksPattern(256, 5, A, B)
		if not bgIsFullTile(ops1, 256) then
			return false, "no full-tile bg"
		end
		if #ops1 ~= 1 + 5 then
			return false, "ops=" .. #ops1
		end
		if ops1[2].size.Y ~= 256 then
			return false, "plank not full height"
		end
		if ops1[2].color ~= ops2[2].color then
			return false, "not deterministic"
		end
		return true
	end)

	add("bricksPattern: bg-first; odd rows offset from even rows", function()
		local ops = TextureFactory.bricksPattern(256, 6, A, B)
		if not bgIsFullTile(ops, 256) then
			return false, "no full-tile bg"
		end
		if #ops < 1 + 6 then
			return false, "too few bricks: " .. #ops
		end
		local rowH = 256 / 6
		local firstRow0X, firstRow1X
		for i = 2, #ops do
			local op = ops[i]
			if firstRow0X == nil and op.pos.Y < rowH * 0.5 then
				firstRow0X = op.pos.X
			elseif firstRow1X == nil and op.pos.Y >= rowH * 0.5 and op.pos.Y < rowH * 1.5 then
				firstRow1X = op.pos.X
			end
		end
		if firstRow0X == nil or firstRow1X == nil then
			return false, "rows not found"
		end
		if math.abs((firstRow1X - firstRow0X)) < 5 then
			return false, "rows not offset (running bond missing)"
		end
		return true
	end)

	add("noisePattern: bg-first + cells speckles, deterministic by seed", function()
		local a = TextureFactory.noisePattern(256, 40, A, B, 1)
		local b = TextureFactory.noisePattern(256, 40, A, B, 1)
		if not bgIsFullTile(a, 256) then
			return false, "no full-tile bg"
		end
		if #a ~= 1 + 40 then
			return false, "ops=" .. #a
		end
		if a[2].pos ~= b[2].pos then
			return false, "not deterministic"
		end
		return true
	end)

	add("buildPattern: dispatches by kind + applies defaults; unknown -> noise default", function()
		local bricks = TextureFactory.buildPattern("bricks", nil, nil)
		local checker = TextureFactory.buildPattern("checker", nil, nil)
		if not bgIsFullTile(bricks, 256) or not bgIsFullTile(checker, 256) then
			return false, "bg missing"
		end
		if #checker ~= 9 then
			return false, "checker ops=" .. #checker
		end
		local custom = TextureFactory.buildPattern("checker", Color3.fromRGB(1, 2, 3), nil)
		if custom[1].color ~= Color3.fromRGB(1, 2, 3) then
			return false, "primary override ignored"
		end
		local unknown = TextureFactory.buildPattern("bogus", nil, nil)
		if not bgIsFullTile(unknown, 256) then
			return false, "unknown kind did not fall back"
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
			print("[TextureFactorySpec] PASS " .. c.name)
		else
			warn("[TextureFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[TextureFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
