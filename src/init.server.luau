--!strict
-- StudioAgent bootstrap (STABLE — the only file that needs a Studio restart when changed; kept tiny).
-- Creates the persistent toolbar + dock widget (Studio dedupes them by name/id, so they survive hot-
-- reloads), runs generation 1 of the reloadable Main, and starts the hot-reload supervisor: a `reload`
-- from the shell makes the sidecar hand over the current src/, and HotReload swaps in fresh code with NO
-- restart. See docs/superpowers/specs/2026-06-26-dev-bridge-hot-reload-design.md.

local Main = require(script.Main)
local HotReload = require(script.HotReload)
local Config = require(script.Config)

local toolbar = plugin:CreateToolbar("Claude Agent")
local button =
	toolbar:CreateButton("StudioAgentToggle", "Open the Claude Agent panel", "", "Claude")
button.ClickableWhenViewportHidden = true

local info =
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("StudioAgentWidget", info)
widget.Title = "Claude Agent"

local ctx = { plugin = plugin, toolbar = toolbar, button = button, widget = widget }
local runtime = { lifecycle = nil :: any, container = nil :: any }

-- Generation 1: run the real Main directly (its source is already current; no clone needed).
runtime.lifecycle = Main.run(ctx)

-- Hot-reload supervisor (stable; survives a failed reload so a fixed reload recovers).
HotReload.startSupervisor(script, Config.new(plugin), runtime, ctx)

print("[StudioAgent] bootstrap loaded (hot-reload supervisor active)")
