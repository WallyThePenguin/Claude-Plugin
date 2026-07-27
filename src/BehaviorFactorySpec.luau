--!strict
-- BehaviorFactorySpec: in-Studio self-test for the PURE BehaviorFactory logic (roadmap #3). Run via the
-- bridge: luau 'return tostring(require(script.Parent.BehaviorFactorySpec).run())'.

local BehaviorFactory = require(script.Parent.BehaviorFactory)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function approx(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("validate applies defaults for missing/invalid fields", function()
		local c = BehaviorFactory.validate({ active = 0.3 })
		if not approx(c.windup, BehaviorFactory.DEFAULTS.windup) then
			return false, "windup default not applied"
		end
		if not approx(c.active, 0.3) then
			return false, "active not kept"
		end
		if not approx(c.cooldown, BehaviorFactory.DEFAULTS.cooldown) then
			return false, "cooldown default not applied"
		end
		return true
	end)

	add("lungeStuds defaults to 0 so bound weapons stay stationary", function()
		local c = BehaviorFactory.validate({ active = 0.3 })
		if not approx(c.lungeStuds, 0) then
			return false, "lungeStuds should default to 0 (no stride)"
		end
		local kept = BehaviorFactory.validate({ lungeStuds = 2.5 })
		if not approx(kept.lungeStuds, 2.5) then
			return false, "lungeStuds not kept"
		end
		return true
	end)

	add(
		"lungeStuds is a DISTANCE: negatives clamp, and it never rescues a zero timeline",
		function()
			local c = BehaviorFactory.validate({ lungeStuds = -3 })
			if not approx(c.lungeStuds, 0) then
				return false, "negative lungeStuds not clamped to 0"
			end
			-- a stride with no time to run in is still an invalid machine
			local _, err = BehaviorFactory.validate({
				windup = 0,
				active = 0,
				cooldown = 0,
				lungeStuds = 5,
			})
			if err == nil then
				return false, "lungeStuds must not count toward the duration total"
			end
			return true
		end
	)

	add("validate clamps negatives to 0 and rejects an all-zero total", function()
		local c = BehaviorFactory.validate({ windup = -5, active = 0.2, cooldown = "x" })
		if not approx(c.windup, 0) then
			return false, "negative not clamped to 0"
		end
		local zeroed, err = BehaviorFactory.validate({ windup = 0, active = 0, cooldown = 0 })
		if err == nil then
			return false, "all-zero total should error"
		end
		if not (approx(zeroed.windup, 0) and approx(zeroed.cooldown, 0)) then
			return false, "zero config not returned"
		end
		return true
	end)

	add("timeline has cumulative offsets and the right active window", function()
		local tl = BehaviorFactory.timeline({ windup = 0.2, active = 0.1, cooldown = 0.5 })
		if #tl ~= 4 then
			return false, "expected 4 phases, got " .. tostring(#tl)
		end
		if tl[1].state ~= "windup" or not approx(tl[1].at, 0) then
			return false, "windup not first @0"
		end
		if tl[2].state ~= "active" or not approx(tl[2].at, 0.2) then
			return false, "active not @windup"
		end
		if tl[3].state ~= "cooldown" or not approx(tl[3].at, 0.3) then
			return false, "cooldown not @windup+active"
		end
		if tl[4].state ~= "idle" or not approx(tl[4].at, 0.8) then
			return false, "idle return not @total"
		end
		local s, f = BehaviorFactory.activeWindow({ windup = 0.2, active = 0.1, cooldown = 0.5 })
		if not (approx(s, 0.2) and approx(f, 0.3)) then
			return false, "active window wrong: " .. tostring(s) .. "," .. tostring(f)
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
			print("[BehaviorFactorySpec] PASS " .. c.name)
		else
			warn("[BehaviorFactorySpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[BehaviorFactorySpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
