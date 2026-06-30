--!strict
-- HitValidatorSpec: in-Studio self-test for the PURE HitValidator (server-authoritative cooldown gate).
-- Run via `& scripts/studio-agent.ps1 luau 'return tostring(require(script.Parent.HitValidatorSpec).run())'`.

local HitValidator = require(script.Parent.HitValidator)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("first hit (no prior) is accepted and advances the window to now", function()
		local ok, reason, nextHit = HitValidator.check(nil, 100, 0.4)
		return ok and reason == "ok" and nextHit == 100
	end)

	add("an immediate re-hit inside the cooldown is REJECTED and keeps the old timestamp", function()
		local ok, reason, nextHit = HitValidator.check(100, 100.1, 0.4)
		return (not ok) and reason == "cooldown" and nextHit == 100
	end)

	add("a hit exactly at the cooldown boundary is accepted (>=)", function()
		local ok, _, nextHit = HitValidator.check(100, 100.4, 0.4)
		return ok and nextHit == 100.4
	end)

	add("a hit after the cooldown is accepted and advances the window", function()
		local ok, reason, nextHit = HitValidator.check(100, 101, 0.4)
		return ok and reason == "ok" and nextHit == 101
	end)

	add("a REJECTED spam request must not extend the window (so a later real swing isn't starved)", function()
		-- accept at 100; spam at 100.1 (reject, keep 100); a legit swing at 100.45 must still be accepted
		local _, _, afterAccept = HitValidator.check(nil, 100, 0.4)
		local _, _, afterSpam = HitValidator.check(afterAccept, 100.1, 0.4)
		local ok = HitValidator.check(afterSpam, 100.45, 0.4)
		return afterAccept == 100 and afterSpam == 100 and ok
	end)

	add("coerceCooldown: nil/NaN -> default, negative -> 0, valid -> itself", function()
		return HitValidator.coerceCooldown(nil) == HitValidator.DEFAULT_COOLDOWN
			and HitValidator.coerceCooldown(0 / 0) == HitValidator.DEFAULT_COOLDOWN
			and HitValidator.coerceCooldown(-5) == 0
			and HitValidator.coerceCooldown(0.25) == 0.25
	end)

	add("a NaN timestamp is rejected (bad-timestamp), not silently accepted", function()
		local ok, reason = HitValidator.check(100, 0 / 0, 0.4)
		return (not ok) and reason == "bad-timestamp"
	end)

	add("cooldown 0 accepts every request (opt-out)", function()
		local ok1 = HitValidator.check(100, 100, 0)
		local ok2 = HitValidator.check(100, 100, 0)
		return ok1 and ok2
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
			print("[HitValidatorSpec] PASS " .. c.name)
		else
			warn("[HitValidatorSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[HitValidatorSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
