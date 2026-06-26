--!strict
-- PlayBridgeSpec: pure tests for PlayBridge.actSnippet (the act-verb -> Luau-snippet expansion). No
-- sidecar/play. Run: luau 'return tostring(require(script.Parent.PlayBridgeSpec).run())'.

local PlayBridge = require(script.Parent.PlayBridge)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("actSnippet: known verbs return a non-empty snippet", function()
		for _, v in { "equip", "walk", "stop", "activate" } do
			local s = PlayBridge.actSnippet(v, nil)
			if type(s) ~= "string" or s == "" then
				return false, v .. " returned no snippet"
			end
		end
		return true
	end)

	add("actSnippet: equip references EquipTool, activate references Activate", function()
		local e = PlayBridge.actSnippet("equip", nil) :: string
		local a = PlayBridge.actSnippet("activate", nil) :: string
		if string.find(e, "EquipTool", 1, true) == nil then
			return false, "equip snippet missing EquipTool"
		end
		if string.find(a, "Activate", 1, true) == nil then
			return false, "activate snippet missing Activate"
		end
		return true
	end)

	add("actSnippet: an unknown verb returns nil", function()
		return PlayBridge.actSnippet("fly", nil) == nil, "unknown verb should be nil"
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
