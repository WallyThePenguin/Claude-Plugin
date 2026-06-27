--!strict
-- PlayBridgeSpec: pure tests for PlayBridge's only pure-ish exported helper, cleanupTestScripts (the
-- templates are strings). No sidecar/play. Run: luau 'return tostring(require(script.Parent.PlayBridgeSpec).run())'.

local PlayBridge = require(script.Parent.PlayBridge)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("cleanupTestScripts is callable + idempotent (no error when nothing to clean)", function()
		local ok1 = pcall(PlayBridge.cleanupTestScripts)
		local ok2 = pcall(PlayBridge.cleanupTestScripts)
		return ok1 and ok2, "cleanupTestScripts should never error"
	end)

	add("restoreStarterPlayer is callable + a no-op when nothing was saved", function()
		-- With no test in flight (savedAppearance == nil) it must not touch StarterPlayer or error.
		local before = game:GetService("StarterPlayer").LoadCharacterAppearance
		local ok1 = pcall(PlayBridge.restoreStarterPlayer)
		local ok2 = pcall(PlayBridge.restoreStarterPlayer)
		local after = game:GetService("StarterPlayer").LoadCharacterAppearance
		return ok1 and ok2 and before == after,
			"restoreStarterPlayer should be a safe no-op when no test forced LoadCharacterAppearance"
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
			print("[PlayBridgeSpec] PASS " .. c.name)
		else
			warn("[PlayBridgeSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[PlayBridgeSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
