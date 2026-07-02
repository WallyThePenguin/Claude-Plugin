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
local BuildGuideStore = require(script.Parent.BuildGuideStore)
local CameraRig = require(script.Parent.CameraRig)
local Relay = require(script.Parent.Relay)
local SkillCatalog = require(script.Parent.SkillCatalog)
local StoreClient = require(script.Parent.StoreClient)
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
		buildGuides = BuildGuideStore.new(plugin),
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

	-- Hydrate USER skills from the sidecar's durable, git-versioned store into the plugin-settings
	-- working cache. NOT a blind overwrite: a skill saved while the sidecar was down exists ONLY
	-- locally (its mirror failed with an honest note), so the store is NOT always the superset —
	-- an existing local skill that DIFFERS from the store copy is KEPT (re-save it to re-mirror),
	-- and hydration never evicts (a cache at cap skips additions; the store keeps them safe).
	-- OLDEST-first so the newest durable skills win the remaining cache room. Async + fail-open.
	if relayMode == "edit" then
		task.spawn(function()
			local items = StoreClient.list(config, "skills")
			if type(items) ~= "table" then
				return
			end
			local localByName: { [string]: any } = {}
			local localCount = 0
			for _, s in ipairs(deps.skills:listUser()) do
				localByName[s.name] = s
				localCount += 1
			end
			local hydrated = 0
			local keptLocal = 0
			for i = #items, 1, -1 do -- list is newest-first; iterate reversed (oldest first)
				local body = StoreClient.get(config, "skills", tostring((items[i] :: any).id))
				if type(body) == "table" and type((body :: any).name) == "string" then
					local b = body :: any
					local name = SkillCatalog.normalizeName(b.name)
					local existing = if name ~= nil then localByName[name] else nil
					if existing == nil then
						-- New to the cache: add only when there is room (never FIFO-evict a local
						-- skill to make space — it might be the sole copy of a failed mirror).
						if localCount < SkillCatalog.MAX_USER_SKILLS then
							local _, ok = deps.skills:save(b.name, b.description, b.body, b.parameters)
							if ok and name ~= nil then
								localByName[name] = b
								localCount += 1
								hydrated += 1
							end
						end
					elseif existing.body ~= b.body or existing.description ~= b.description then
						-- The local copy differs — possibly a NEWER local edit whose mirror failed.
						-- Keep local; the user/agent re-saving it re-mirrors the durable copy.
						keptLocal += 1
					end
				end
			end
			if hydrated > 0 or keptLocal > 0 then
				print(
					"[StudioAgent] skills hydration: "
						.. tostring(hydrated)
						.. " added from the durable store"
						.. (if keptLocal > 0
							then "; kept " .. tostring(keptLocal) .. " differing local copy(ies) (re-save to re-mirror)"
							else "")
				)
			end
		end)
	end

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
