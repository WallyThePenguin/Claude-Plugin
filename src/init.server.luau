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
local TaskList = require(script.TaskList)
local Memory = require(script.Memory)
local Learnings = require(script.Learnings)
local SkillStore = require(script.SkillStore)
local RubricStore = require(script.RubricStore)
local CameraRig = require(script.CameraRig)
local Relay = require(script.Relay)
local DevBridge = require(script.DevBridge)

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
-- CreateDockWidgetPluginGuiAsync supersedes the deprecated CreateDockWidgetPluginGui (same args).
-- It yields, which is fine here: plugin scripts run on their own thread, and this is the standard
-- top-level pattern. Verified against create.roblox.com (Plugin class reference, 2026-06-18).
local widget = plugin:CreateDockWidgetPluginGuiAsync("StudioAgentWidget", info)
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
	taskList = TaskList.new(),
	memory = Memory.new(plugin),
	learnings = Learnings.new(plugin),
	skills = SkillStore.new(plugin),
	rubrics = RubricStore.new(),
	cameraRig = CameraRig.new(config),
}

-- Client-view relay (LIVE-VERIFIED 2026-06-18): Accurate Play Solo runs separate per-context plugin
-- copies. In the Play SERVER copy, host the relay RemoteFunction. In the Play CLIENT copy (the panel
-- the user sees in client view), build the relay client + swap deps.anthropic for a relay-aware one,
-- so the loop's HTTP + DataModel/dispatch tools run server-side. In edit / Server-view: no relay.
local relayMode = Relay.mode()
if relayMode == "serverplay" then
	Relay.startHost(deps)
elseif relayMode == "clientplay" then
	local relayClient = Relay.newClient()
	if relayClient ~= nil then
		deps.relay = relayClient
		deps.anthropic = Relay.wrapAnthropic(relayClient)
	end
end

-- Dev bridge: let Claude Code drive the plugin from the shell over the sidecar. EDIT-only + localhost-
-- only (DevBridge.start no-ops in play/published), default-on via config. Pass the shared deps so prompt
-- mode runs on the same conversation the panel shows.
DevBridge.start(deps)

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
