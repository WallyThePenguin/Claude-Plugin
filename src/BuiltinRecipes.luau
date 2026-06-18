--!strict
-- BuiltinRecipes: built-in Roblox BUILD recipes (category "recipe"). Pure data — a list of
-- { name, description, body, parameters }. Validated by SkillStore at load (source="builtin").
-- Bodies are INSTRUCTIONS the agent follows with its existing tools; {{param}} markers are substituted.

local BuiltinRecipes = {}

BuiltinRecipes.list = {
	{
		name = "leaderstats",
		description = "Set up the standard per-player leaderstats shown on the in-game leaderboard.",
		parameters = {
			{
				name = "statNames",
				description = "Comma-separated stat names (default: Coins).",
				required = false,
			},
		},
		body = "Set up standard leaderstats (per-player leaderboard values).\n"
			.. "1) create_instance a 'Script' under game.ServerScriptService named 'LeaderstatsSetup'.\n"
			.. "2) Set its Source (a \\n-joined Luau string): on game.Players.PlayerAdded, make a Folder "
			.. "named 'leaderstats' parented to the player, and for each stat in {{statNames}} (default "
			.. "'Coins') create an IntValue (Name = the stat, Value = 0) parented to that Folder.\n"
			.. "3) Scripts you create run during Play, not edit — so VERIFY by reading the Source back "
			.. "(get_properties) and confirming the Script is under ServerScriptService (get_tree).\n"
			.. "4) Tell the user the values appear on the leaderboard once they Play.",
	},
	{
		name = "shop-gui",
		description = "Build a shop ScreenGui scaffold (item grid, buy/close buttons, styled).",
		parameters = {
			{ name = "title", description = "Shop title (default: Shop).", required = false },
			{
				name = "itemCount",
				description = "Number of placeholder item slots (default: 6).",
				required = false,
			},
		},
		body = "Build a shop ScreenGui scaffold.\n"
			.. "1) create_instance a 'ScreenGui' named '{{title}}' (default 'Shop') under game.StarterGui "
			.. "(ships to players) — or game.CoreGui for an edit-time preview you can capture immediately.\n"
			.. "2) A main Frame centered (AnchorPoint 0.5,0.5; Position UDim2.fromScale(0.5,0.5); a sensible "
			.. "Size), with UICorner + UIPadding.\n"
			.. "3) A title TextLabel at top; a ScrollingFrame (or Frame) holding {{itemCount}} (default 6) "
			.. "item Frames laid out with a UIGridLayout, each with an icon ImageLabel + a name TextLabel + "
			.. "a 'Buy' TextButton (UICorner).\n"
			.. "4) A 'Close' TextButton at the top-right.\n"
			.. "5) Build with create_instance/set_property (loadstring-free; works in a playtest too).\n"
			.. "6) capture and LOOK — fix spacing/alignment/color, then capture again until it looks "
			.. "intentional. Wire Buy/Close behavior with scripts only if the user asks.",
	},
	{
		name = "r15-npc",
		description = "Scaffold a basic R15 NPC (Humanoid + HumanoidRootPart + joined body parts).",
		parameters = {
			{ name = "name", description = "NPC model name (default: NPC).", required = false },
			{
				name = "spawnPosition",
				description = "Where to place it, e.g. 0,5,0 (default near origin).",
				required = false,
			},
		},
		body = "Scaffold a basic R15 NPC.\n"
			.. "1) Build a Model named '{{name}}' (default 'NPC') containing a Humanoid, a HumanoidRootPart "
			.. "(a Part), and the R15 body Parts joined by Motor6D objects (.Part0/.Part1/.C0/.C1).\n"
			.. "2) Set the Model's PrimaryPart to the HumanoidRootPart, and position it at {{spawnPosition}} "
			.. "(default near 0,5,0) via Model:PivotTo or by setting the HumanoidRootPart CFrame.\n"
			.. "3) Parent the Model under game.Workspace.\n"
			.. "4) VERIFY: get_tree the Model to confirm the Humanoid + HumanoidRootPart + joints exist; "
			.. "capture to see it.\n"
			.. "If a full R15 joint setup is heavy or error-prone, tell the user and offer to load a Roblox "
			.. "rig template (Avatar tab) instead, then continue from there.",
	},
	{
		name = "datastore-save",
		description = "Add a robust DataStore save/load scaffold (pcall + retry, fail-safe).",
		parameters = {
			{
				name = "storeName",
				description = "DataStore name (default: PlayerData).",
				required = false,
			},
		},
		body = "Add a robust DataStore save/load scaffold.\n"
			.. "1) create_instance a 'Script' under game.ServerScriptService named 'DataStoreManager'.\n"
			.. "2) Source (\\n-joined Luau): get a store via DataStoreService:GetDataStore('{{storeName}}') "
			.. "(default 'PlayerData'); on PlayerAdded, pcall GetAsync(key) where key = 'Player_'..userId, "
			.. "with a retry loop (3 tries, task.wait backoff), then apply the data or a default; on "
			.. "PlayerRemoving AND game:BindToClose, pcall SetAsync with the same retry.\n"
			.. "3) ALWAYS wrap Get/SetAsync in pcall and handle failure — do NOT overwrite good data after a "
			.. "failed read.\n"
			.. "4) Note to the user: DataStores require 'Enable Studio Access to API Services' (Game "
			.. "Settings > Security) to test in Studio.\n"
			.. "5) VERIFY by reading the Source back and checking get_output(errorsOnly=true) after a Play test.",
	},
	{
		name = "parallel-zones",
		description = "Build several INDEPENDENT zones/areas at once with dispatch_writers.",
		parameters = {
			{
				name = "zones",
				description = "The zones to build (names, or name+what-to-build pairs).",
				required = true,
			},
		},
		body = "Build several INDEPENDENT zones/areas fast, in parallel.\n"
			.. "1) Decide the zones from {{zones}}.\n"
			.. "2) Create each zone's CONTAINER yourself FIRST (a Folder or Model per zone under "
			.. "game.Workspace, e.g. game.Workspace.Zones.<name>) — they must EXIST before you dispatch.\n"
			.. "3) Call dispatch_writers with one { region = the zone container's full dot-path, task = what "
			.. "to build there } per zone; each writer builds its zone IN PARALLEL, confined to its region.\n"
			.. "4) When they return, do any cross-zone wiring yourself and capture / get_tree to verify.\n"
			.. "Use this only when the zones are genuinely independent and the build is big enough to be "
			.. "worth it; for a small or tightly-coupled build, just build it yourself.",
	},
}

return BuiltinRecipes
