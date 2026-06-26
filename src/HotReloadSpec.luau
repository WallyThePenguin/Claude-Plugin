--!strict
-- HotReloadSpec: in-Studio self-test for the PURE HotReload helpers (resolvePath + newLifecycle). No
-- sidecar/clone/require. Run via require(script.HotReloadSpec).run() in init, OR from the bridge:
-- luau 'return tostring(require(script.Parent.HotReloadSpec).run())'.

local HotReload = require(script.Parent.HotReload)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

-- A synthetic clone container: AnimationClip (ModuleScript), Tools (ModuleScript) -> Animate
-- (ModuleScript), UI (Folder) -> Widget (ModuleScript).
local function sampleContainer(): Instance
	local c = Instance.new("Folder")
	c.Name = "container"
	local function ms(name: string, parent: Instance): ModuleScript
		local m = Instance.new("ModuleScript")
		m.Name = name
		m.Parent = parent
		return m
	end
	ms("AnimationClip", c)
	local tools = ms("Tools", c)
	ms("Animate", tools)
	local ui = Instance.new("Folder")
	ui.Name = "UI"
	ui.Parent = c
	ms("Widget", ui)
	return c
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("resolvePath: root module", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "AnimationClip.luau")
		return parent == c and child == "AnimationClip",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: nested module under a ModuleScript folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "Tools/Animate.luau")
		return parent == c:FindFirstChild("Tools") and child == "Animate",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: init.luau targets the folder-module itself", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "Tools/init.luau")
		return parent == c and child == "Tools",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: module under a plain Folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "UI/Widget.luau")
		return parent == c:FindFirstChild("UI") and child == "Widget",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: bootstrap is skipped", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "init.server.luau")
		return parent == nil and child == nil, "bootstrap should map to (nil,nil)"
	end)

	add("resolvePath: a new leaf module returns its (existing-parent, name)", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "NewModule.luau")
		return parent == c and child == "NewModule",
			"got " .. tostring(parent) .. "/" .. tostring(child)
	end)

	add("resolvePath: a new nested path creates the intermediate Folder", function()
		local c = sampleContainer()
		local parent, child = HotReload.resolvePath(c, "NewFolder/NewMod.luau")
		local nf = c:FindFirstChild("NewFolder")
		return nf ~= nil and parent == nf and child == "NewMod",
			"intermediate folder not created or wrong target"
	end)

	add("newLifecycle: cancel sets the flag and disconnects connections", function()
		local lc = HotReload.newLifecycle()
		local disconnected = false
		lc:add({
			Disconnect = function()
				disconnected = true
			end,
		} :: any)
		if lc.cancelled then
			return false, "should start un-cancelled"
		end
		lc:cancel()
		return lc.cancelled and disconnected and #lc.connections == 0,
			"cancelled=" .. tostring(lc.cancelled) .. " disconnected=" .. tostring(disconnected)
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
			print("[HotReloadSpec] PASS " .. c.name)
		else
			warn("[HotReloadSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[HotReloadSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
