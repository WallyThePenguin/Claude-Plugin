--!strict
-- RuntimeInstallerSpec: the pure surface (needsInstall + launcherSource). The install path is
-- live-verified via the bridge (install -> Version attribute -> launchers require the modules).

local RuntimeInstaller = require(script.Parent.RuntimeInstaller)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("needsInstall: nothing installed -> true", function()
		return RuntimeInstaller.needsInstall(nil, 1) == true
	end)

	add("needsInstall: older installed -> true; same/newer -> false (never downgrade)", function()
		return RuntimeInstaller.needsInstall(1, 2) == true
			and RuntimeInstaller.needsInstall(2, 2) == false
			and RuntimeInstaller.needsInstall(3, 2) == false
	end)

	add("needsInstall: corrupt current (NaN/non-number) -> true", function()
		return RuntimeInstaller.needsInstall(0 / 0, 1) == true
			and RuntimeInstaller.needsInstall(("x" :: any) :: number?, 1) == true
	end)

	add("launcherSource: waits for the named module and attaches script.Parent", function()
		local src = RuntimeInstaller.launcherSource("BehaviorRuntime")
		return string.find(src, 'WaitForChild("BehaviorRuntime", 10)', 1, true) ~= nil
			and string.find(src, "require(mod).attach(script.Parent)", 1, true) ~= nil
			and string.find(src, "StudioAgentRuntime", 1, true) ~= nil
	end)

	add("launcherSource: compiles", function()
		local okCall, chunk = pcall(loadstring, RuntimeInstaller.launcherSource("NpcAI"))
		return okCall and chunk ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== RuntimeInstallerSpec: running " .. tostring(total) .. " cases ===")
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
