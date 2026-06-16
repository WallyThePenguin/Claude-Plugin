--!strict
-- M2 panel: minimal connection settings (proxy key) + a Ping button to smoke-test
-- the plugin -> proxy -> Claude path. M9 replaces this with the full task UI.
-- A DockWidgetPluginGui renders a Frame-rooted tree (NOT a ScreenGui).

local Widget = {}

-- Loosely typed to keep the UI decoupled from the Config/Anthropic modules.
export type Deps = {
	config: any,
	anthropic: any,
	runLuau: any,
	agentLoop: any,
}

local function makeText(parent: Instance, text: string, height: number, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, height)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Text = text
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function makeButton(parent: Instance, text: string, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 28)
	b.Text = text
	b.LayoutOrder = order
	b.Parent = parent
	return b
end

function Widget.mount(gui: Instance, deps: Deps)
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root

	makeText(root, "Claude Agent", 20, 1)
	makeText(root, "Proxy key (Bearer):", 16, 2)

	local keyBox = Instance.new("TextBox")
	keyBox.Size = UDim2.new(1, 0, 0, 28)
	keyBox.ClearTextOnFocus = false
	keyBox.PlaceholderText = "paste the proxy inbound key"
	keyBox.Text = deps.config:getProxyKey()
	keyBox.LayoutOrder = 3
	keyBox.Parent = root

	local status = makeText(root, "", 16, 98)
	local result = makeText(root, "", 120, 99)

	local saveBtn = makeButton(root, "Save key", 4)
	saveBtn.Activated:Connect(function()
		local ok, reason = deps.config:set("proxyKey", keyBox.Text)
		if ok then
			status.Text = "Key saved."
		else
			status.Text = "Rejected: " .. tostring(reason)
		end
	end)

	local pingBtn = makeButton(root, "Ping Claude", 5)
	pingBtn.Activated:Connect(function()
		status.Text = "Pinging " .. deps.config:getModel() .. " ..."
		result.Text = ""
		deps.anthropic:ping("Reply with the single word: ok", function(res, text)
			if res.ok then
				status.Text = "OK"
				result.Text = "Claude: " .. text
			else
				status.Text = "Error [" .. tostring(res.kind) .. "]"
				result.Text = tostring(res.message)
			end
		end)
	end)

	makeText(root, "run_luau test:", 16, 6)
	local codeBox = Instance.new("TextBox")
	codeBox.Size = UDim2.new(1, 0, 0, 72)
	codeBox.MultiLine = true
	codeBox.ClearTextOnFocus = false
	codeBox.TextXAlignment = Enum.TextXAlignment.Left
	codeBox.TextYAlignment = Enum.TextYAlignment.Top
	codeBox.PlaceholderText = "local p = Instance.new('Part') p.Parent = workspace return p.Name"
	codeBox.Text = ""
	codeBox.LayoutOrder = 7
	codeBox.Parent = root

	local runBtn = makeButton(root, "Run", 8)
	runBtn.Activated:Connect(function()
		local out = deps.runLuau.run({ code = codeBox.Text })
		status.Text = if out.error then "run_luau error" else "run_luau ok"
		result.Text = out.text
	end)

	makeText(root, "Agent task:", 16, 9)
	local taskBox = Instance.new("TextBox")
	taskBox.Size = UDim2.new(1, 0, 0, 56)
	taskBox.MultiLine = true
	taskBox.ClearTextOnFocus = false
	taskBox.TextXAlignment = Enum.TextXAlignment.Left
	taskBox.TextYAlignment = Enum.TextYAlignment.Top
	taskBox.PlaceholderText = "create a red part at 0,5,0"
	taskBox.LayoutOrder = 10
	taskBox.Parent = root

	local cancelled = false

	local startBtn = makeButton(root, "Start agent", 11)
	startBtn.Activated:Connect(function()
		cancelled = false
		result.Text = ""
		local system = "You are a build assistant working INSIDE Roblox Studio (edit mode) at "
			.. "PluginSecurity. Use the run_luau tool to inspect and modify the open place; address "
			.. "instances by path (e.g. game.Workspace). Compose multiple operations per call. When "
			.. "the task is complete, reply with a short confirmation of what you changed."
		deps.agentLoop.start(deps.anthropic, deps.config, system, taskBox.Text, {
			onEvent = function(event: string, data: any)
				if event == "assistant_text" then
					result.Text = result.Text .. "\n" .. tostring(data)
					print("[agent] " .. tostring(data))
				elseif event == "tool_use" then
					status.Text = "running tool: " .. tostring(data.name)
					print("[agent] tool_use -> " .. tostring(data.name))
				elseif event == "tool_result" then
					print(
						"[agent] tool_result (error="
							.. tostring(data.isError)
							.. "): "
							.. tostring(data.text)
					)
				elseif event == "iteration" then
					status.Text = "iteration " .. tostring(data.n) .. "/" .. tostring(data.max)
				elseif event == "done" then
					status.Text = "done (" .. tostring(data.stop) .. ")"
				elseif event == "error" then
					status.Text = "error [" .. tostring(data.kind) .. "]"
					result.Text = result.Text .. "\nERROR: " .. tostring(data.message)
				end
			end,
			shouldCancel = function(): boolean
				return cancelled
			end,
		})
	end)

	local stopBtn = makeButton(root, "Stop", 12)
	stopBtn.Activated:Connect(function()
		cancelled = true
		status.Text = "stopping after current step..."
	end)
end

return Widget
