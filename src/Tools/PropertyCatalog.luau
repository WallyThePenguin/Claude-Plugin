--!strict
-- PropertyCatalog: a curated, type-tagged catalog of settable/readable properties per class.
--
-- WHY a hand-curated catalog instead of reflection: at PluginSecurity there is NO general
-- property-reflection API exposed to Luau (no public way to enumerate a class's properties at
-- runtime). So get_properties / set_property work from this static map, cross-checked against the
-- create.roblox.com docs for exact name CASING (e.g. MeshPart.TextureID has an all-caps "ID";
-- MeshPart.MeshId ends in a lowercase "d"; Decal exposes Color3, not Color).
--
-- byClass[className][propName] = valueTypeString. The valueTypeString is the EXPECTED typeof() of a
-- successful read. get_properties uses it as a shadow guard: if the catalog tags a property as a
-- non-Instance but a live read returns an Instance, that read actually hit a same-named CHILD
-- shadowing the property name (FindFirstChild-style sugar), and the wrong value is skipped/flagged
-- rather than serialized as if it were the property.
--
-- This is a Tools/ submodule; Properties.luau requires it via require(script.Parent.PropertyCatalog).

local M = {}

export type ValueType = string
export type ClassProps = { [string]: ValueType }

-- Properties keyed by the class that FIRST introduces them, type-tagged with the typeof() of a
-- normal read. get() unions these across the instance's IsA chain.
M.byClass = {
	Instance = {
		Name = "string",
		-- Parent reads as an Instance (or nil at the root). Tagged "Instance" so the shadow guard
		-- expects an Instance here and does not mis-flag it.
		Parent = "Instance",
		ClassName = "string", -- read-only
		Archivable = "boolean",
	} :: ClassProps,

	BasePart = {
		Size = "Vector3",
		Position = "Vector3",
		CFrame = "CFrame",
		Orientation = "Vector3", -- degrees, (X, Y, Z)
		Anchored = "boolean",
		CanCollide = "boolean",
		Color = "Color3",
		Material = "EnumItem", -- Enum.Material
		Transparency = "number",
	} :: ClassProps,

	Part = {
		Shape = "EnumItem", -- Enum.PartType
	} :: ClassProps,

	MeshPart = {
		MeshId = "string",
		TextureID = "string", -- NOTE: all-caps "ID" per the engine API.
	} :: ClassProps,

	Model = {
		PrimaryPart = "Instance",
	} :: ClassProps,

	Folder = {} :: ClassProps,

	Decal = {
		Texture = "string",
		Color3 = "Color3", -- NOTE: the property is literally named "Color3" on Decal.
		Transparency = "number",
	} :: ClassProps,

	PointLight = {
		Brightness = "number",
		Color = "Color3",
		Range = "number",
	} :: ClassProps,

	-- Script family. Source is deliberately NOT here: script IO goes through the script tools
	-- (get_script/edit_script), which use ScriptEditorService and compile-check writes.
	BaseScript = {
		Enabled = "boolean",
	} :: ClassProps,

	Script = {
		RunContext = "EnumItem", -- Enum.RunContext
	} :: ClassProps,

	Humanoid = {
		Health = "number",
		MaxHealth = "number",
		WalkSpeed = "number",
		JumpPower = "number",
		JumpHeight = "number",
		UseJumpPower = "boolean",
		HipHeight = "number",
		DisplayName = "string",
		AutoRotate = "boolean",
	} :: ClassProps,

	ScreenGui = {
		Enabled = "boolean",
		DisplayOrder = "number",
		IgnoreGuiInset = "boolean",
		ResetOnSpawn = "boolean",
	} :: ClassProps,

	GuiObject = {
		Size = "UDim2",
		Position = "UDim2",
		AnchorPoint = "Vector2",
		BackgroundColor3 = "Color3",
		BackgroundTransparency = "number",
		Visible = "boolean",
		ZIndex = "number",
		LayoutOrder = "number",
		Rotation = "number",
	} :: ClassProps,

	TextLabel = {
		Text = "string",
		TextColor3 = "Color3",
		TextSize = "number",
		TextWrapped = "boolean",
		TextScaled = "boolean",
		TextXAlignment = "EnumItem",
		TextYAlignment = "EnumItem",
		RichText = "boolean",
	} :: ClassProps,

	TextButton = {
		Text = "string",
		TextColor3 = "Color3",
		TextSize = "number",
		TextWrapped = "boolean",
		TextScaled = "boolean",
		TextXAlignment = "EnumItem",
		TextYAlignment = "EnumItem",
		AutoButtonColor = "boolean",
	} :: ClassProps,

	TextBox = {
		Text = "string",
		PlaceholderText = "string",
		TextColor3 = "Color3",
		TextSize = "number",
		ClearTextOnFocus = "boolean",
		TextEditable = "boolean",
	} :: ClassProps,

	ImageLabel = {
		Image = "string",
		ImageColor3 = "Color3",
		ImageTransparency = "number",
		ScaleType = "EnumItem",
	} :: ClassProps,

	ImageButton = {
		Image = "string",
		ImageColor3 = "Color3",
		ImageTransparency = "number",
		ScaleType = "EnumItem",
	} :: ClassProps,

	ScrollingFrame = {
		CanvasSize = "UDim2",
		AutomaticCanvasSize = "EnumItem",
		ScrollBarThickness = "number",
		ScrollingDirection = "EnumItem",
	} :: ClassProps,

	UIListLayout = {
		Padding = "UDim",
		FillDirection = "EnumItem",
		HorizontalAlignment = "EnumItem",
		VerticalAlignment = "EnumItem",
		SortOrder = "EnumItem",
	} :: ClassProps,

	UICorner = {
		CornerRadius = "UDim",
	} :: ClassProps,

	UIPadding = {
		PaddingTop = "UDim",
		PaddingBottom = "UDim",
		PaddingLeft = "UDim",
		PaddingRight = "UDim",
	} :: ClassProps,

	Lighting = {
		Ambient = "Color3",
		OutdoorAmbient = "Color3",
		Brightness = "number",
		ClockTime = "number",
		FogColor = "Color3",
		FogStart = "number",
		FogEnd = "number",
		EnvironmentDiffuseScale = "number",
		EnvironmentSpecularScale = "number",
	} :: ClassProps,

	Workspace = {
		Gravity = "number",
		StreamingEnabled = "boolean",
	} :: ClassProps,

	Sound = {
		SoundId = "string",
		Volume = "number",
		PlaybackSpeed = "number",
		Looped = "boolean",
		Playing = "boolean",
		TimeLength = "number", -- read-only
		RollOffMaxDistance = "number",
		RollOffMinDistance = "number",
	} :: ClassProps,

	SpawnLocation = {
		Neutral = "boolean",
		Duration = "number",
	} :: ClassProps,

	Tool = {
		Grip = "CFrame",
		RequiresHandle = "boolean",
		CanBeDropped = "boolean",
		Enabled = "boolean",
		ToolTip = "string",
	} :: ClassProps,

	Attachment = {
		CFrame = "CFrame",
		Position = "Vector3",
		Visible = "boolean",
	} :: ClassProps,
}

-- Names that are never settable, regardless of class. set_property refuses these up front.
M.readOnly = {
	ClassName = true,
	TimeLength = true, -- Sound
} :: { [string]: boolean }

-- Union the catalog entries for every catalogued class the instance IsA, leaf values winning on
-- name collisions (none expected, but deterministic). De-duped by construction (a dict). IsA is used
-- to walk the inheritance chain without needing to know the exact hierarchy here: we simply test the
-- instance against each catalogued class name and merge the matches. IsA returns FALSE (never throws)
-- for a class the instance is not, and for unknown class strings, so this is total.
function M.get(inst: Instance): ClassProps
	local result: ClassProps = {}
	for className, props in M.byClass do
		local ok, isa = pcall(function(): boolean
			return inst:IsA(className)
		end)
		if ok and isa then
			for name, valueType in props do
				result[name] = valueType
			end
		end
	end
	return result
end

return M
