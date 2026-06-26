--!strict
-- StudioAgent bootstrap. Creates the persistent toolbar + dock widget (these survive hot-reloads —
-- Studio dedupes them by name/id), then runs the reloadable Main. (Task 5 adds the hot-reload
-- supervisor loop; until then this is a plain refactor that behaves exactly like before.)

local Main = require(script.Main)

local toolbar = plugin:CreateToolbar("Claude Agent")
local button =
	toolbar:CreateButton("StudioAgentToggle", "Open the Claude Agent panel", "", "Claude")
button.ClickableWhenViewportHidden = true

local info =
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 480, 260, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("StudioAgentWidget", info)
widget.Title = "Claude Agent"

Main.run({ plugin = plugin, toolbar = toolbar, button = button, widget = widget })

print("[StudioAgent] bootstrap loaded")
