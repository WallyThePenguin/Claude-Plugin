--!strict
-- M0 stub panel. M9 replaces this with the real task input / transcript / status UI.
-- NOTE: a DockWidgetPluginGui renders a Frame-rooted tree (NOT a ScreenGui).

local Widget = {}

function Widget.mount(gui: Instance)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.Text = "Claude Agent (M0 stub)"
	label.Parent = gui
end

return Widget
