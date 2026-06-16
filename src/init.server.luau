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
Widget.mount(widget, {
	config = config,
	anthropic = anthropic,
	agentLoop = AgentLoop,
	systemPrompt = SystemPrompt.build(),
	conversation = Conversation.new(),
	sessions = Sessions.new(plugin),
})

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	button:SetActive(widget.Enabled)
end)

-- Keep the toolbar highlight in sync when the user closes the panel via its X.
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)

button:SetActive(widget.Enabled)

print("[StudioAgent] M9 plugin loaded (chat UI + session history)")
