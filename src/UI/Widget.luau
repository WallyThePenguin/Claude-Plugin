--!strict
-- M2 panel: minimal connection settings (proxy key) + a Ping button to smoke-test
-- the plugin -> proxy -> Claude path. M9 replaces this with the full task UI.
-- A DockWidgetPluginGui renders a Frame-rooted tree (NOT a ScreenGui).

local Widget = {}

-- Loosely typed to keep the UI decoupled from the Config/Anthropic modules.
export type Deps = {
	config: any,
	anthropic: any,
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
end

return Widget
