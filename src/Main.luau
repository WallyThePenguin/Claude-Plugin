--!strict
-- Main: the RELOADABLE plugin entry. Everything the bootstrap (init.server) does AFTER creating the
-- persistent toolbar/widget lives here, so a hot-reload swaps it wholesale. Main.run(ctx) builds the
-- deps, wires the relay, starts the (lifecycle-aware) dev bridge loop, mounts the UI, wires the button/
-- widget connections, and returns the generation's Lifecycle (the bootstrap cancels it on the next
-- reload). Requires its siblings via script.Parent.X so the clone's relative requires resolve.

local Widget = require(script.Parent.UI.Widget)
local Config = require(script.Parent.Config)
local Anthropic = require(script.Parent.Anthropic)
local AgentLoop = require(script.Parent.AgentLoop)
local SystemPrompt = require(script.Parent.SystemPrompt)
local Conversation = require(script.Parent.Conversation)
local Sessions = require(script.Parent.Sessions)
local TaskList = require(script.Parent.TaskList)
local Memory = require(script.Parent.Memory)
local Learnings = require(script.Parent.Learnings)
local SkillStore = require(script.Parent.SkillStore)
local RubricStore = require(script.Parent.RubricStore)
local CameraRig = require(script.Parent.CameraRig)
local Relay = require(script.Parent.Relay)
local DevBridge = require(script.Parent.DevBridge)
local PlayBridge = require(script.Parent.PlayBridge)
local HotReload = require(script.Parent.HotReload)

local Main = {}

export type Ctx = {
	plugin: Plugin,
	toolbar: PluginToolbar,
	button: PluginToolbarButton,
	widget: DockWidgetPluginGui,
}

-- Build a fresh generation: deps, relay, bridge loop, UI mount, connections. Returns its Lifecycle.
function Main.run(ctx: Ctx): HotReload.Lifecycle
	local plugin = ctx.plugin
	local widget = ctx.widget
	local button = ctx.button
	local lifecycle = HotReload.newLifecycle()

	-- Best-effort: enable runtime loadstring (run_luau) during a playtest (property absent in some
	-- Studio versions; the pcall swallows that).
	pcall(function()
		game:GetService("ServerScriptService").LoadStringEnabled = true
	end)

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

	-- Client-view relay (edit: none; serverplay: host; clientplay: relay-aware anthropic).
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

	DevBridge.start(deps, lifecycle)
	PlayBridge.start(deps, lifecycle)

	-- Mount the panel fresh this generation (clear any stale content first), and re-mount if Studio
	-- clears the widget on an edit<->play transition.
	local function ensureMounted()
		if widget:FindFirstChild("StudioAgentRoot") == nil then
			Widget.mount(widget, deps)
		end
	end
	local existingRoot = widget:FindFirstChild("StudioAgentRoot")
	if existingRoot ~= nil then
		existingRoot:Destroy()
	end
	ensureMounted()
	lifecycle:add(widget.ChildRemoved:Connect(function()
		task.defer(ensureMounted)
	end))

	lifecycle:add(button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
		button:SetActive(widget.Enabled)
	end))
	lifecycle:add(widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end))
	button:SetActive(widget.Enabled)

	print("[StudioAgent] Main generation running (hot-reloadable)")
	return lifecycle
end

return Main
