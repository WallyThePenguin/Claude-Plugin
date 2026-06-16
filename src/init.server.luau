--!strict
-- StudioAgent plugin entry (M0): a toolbar button that toggles a dockable widget.
-- Later milestones wire the Claude agent loop, tools, and the real UI into this.

local Widget = require(script.UI.Widget)
local Config = require(script.Config)
local Anthropic = require(script.Anthropic)
local AgentLoop = require(script.AgentLoop)
local SystemPrompt = require(script.SystemPrompt)
local Conversation = require(script.Conversation)
local Sessions = require(script.Sessions)

-- Best-effort: try to enable runtime loadstring (run_luau) during a playtest. The property does not
-- exist in all Studio versions (the pcall swallows that); when loadstring can't be enabled, the
-- agent builds during a playtest with create_instance + set_property instead (engine API, no
-- loadstring). Remove before publishing if you don't want loadstring enabled in your live game.
pcall(function()
	game:GetService("ServerScriptService").LoadStringEnabled = true
end)

local toolbar = plugin:CreateToolbar("Claude Agent")
-- Empty iconAssetName -> text-only button (no asset dependency for M0).
local button =
	toolbar:CreateButton("StudioAgentToggle", "Open the Claude Agent panel", "", "Claude")
button.ClickableWhenViewportHidden = true

-- DockWidgetPluginGuiInfo.new(initDockState, initEnabled, overrideEnabled, w, h, minW, minH)
local info =
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)
local widget = plugin:CreateDockWidgetPluginGui("StudioAgentWidget", info)
widget.Title = "Claude Agent"

local config = Config.new(plugin)
local anthropic = Anthropic.new(config)
local deps = {
	config = config,
	anthropic = anthropic,
	agentLoop = AgentLoop,
	systemPrompt = SystemPrompt.build(),
	conversation = Conversation.new(),
	sessions = Sessions.new(plugin),
}

-- Mount the panel, and re-mount if Studio clears the widget's content on an edit<->play transition
-- (DockWidgetPluginGui can blank out across Play Solo). The conversation lives in `deps`, so a
-- re-mount rebuilds the same chat (Widget.mount renders the conversation transcript).
local function ensureMounted()
	if widget:FindFirstChild("StudioAgentRoot") == nil then
		Widget.mount(widget, deps)
	end
end
ensureMounted()
widget.ChildRemoved:Connect(function()
	task.defer(ensureMounted)
end)

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	button:SetActive(widget.Enabled)
end)

-- Keep the toolbar highlight in sync when the user closes the panel via its X.
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)

button:SetActive(widget.Enabled)

print("[StudioAgent] M13 plugin loaded (works in playtest + self-verify + get_output)")
