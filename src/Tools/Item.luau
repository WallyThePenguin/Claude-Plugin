--!strict
-- Handheld-item tools: make_tool (toolify a built Part/Model into a Roblox Tool) + grip_tool (equip on a
-- rig + set the grip from intuitive offset/rot + capture so the agent fits the grip by LOOKING).
-- Destructive (DataModel writes); RELAY. Parent-only.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local ToolFactory = require(script.Parent.Parent.ToolFactory)
local Path = require(script.Parent.Path)
local CaptureCore = require(script.Parent.CaptureCore)

local Item = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (any, boolean),
}

local function runMakeTool(input: any, _context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.target) ~= "string" or args.target == "" then
		return "make_tool requires { target = <path to a built Part/Model>, name?, handle? }", true
	end
	local target, terr = Path.resolve(args.target)
	if target == nil then
		return "make_tool: target '" .. tostring(args.target) .. "' did not resolve" .. (if terr
				~= nil
			then " — " .. terr
			else ""),
			true
	end
	local handleHint: Instance? = nil
	if type(args.handle) == "string" and args.handle ~= "" then
		handleHint = Path.resolve(args.handle)
	end
	local toolName = if type(args.name) == "string" then args.name else nil
	local tool: Tool?, err: string?
	local function doToolify()
		tool, err = ToolFactory.toolify(target :: Instance, handleHint, toolName)
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("make_tool")
		doToolify()
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doToolify()
	end
	if tool == nil then
		return "make_tool: " .. tostring(err), true
	end
	local t = tool :: Tool
	local partCount = 0
	for _, d in t:GetDescendants() do
		if d:IsA("BasePart") then
			partCount += 1
		end
	end
	return string.format(
		"make_tool OK: '%s' at %s (%d part(s): a Handle + %d welded, all unanchored). Equip + fit it with grip_tool.",
		t.Name,
		t:GetFullName(),
		partCount,
		math.max(0, partCount - 1)
	),
		false
end

local function runGripTool(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.tool) ~= "string" or args.tool == "" then
		return "grip_tool requires { tool = <path to a Tool>, rig?, offset? {x,y,z}, rot? {rx,ry,rz} }",
			true
	end
	local toolInst = Path.resolve(args.tool)
	if toolInst == nil or not toolInst:IsA("Tool") then
		return "grip_tool: '" .. tostring(args.tool) .. "' is not a Tool (run make_tool first)",
			true
	end
	local tool = toolInst :: Tool
	local rigInst: Instance? = nil
	if type(args.rig) == "string" and args.rig ~= "" then
		rigInst = Path.resolve(args.rig)
	end
	local rig, rerr = ToolFactory.resolveRig(rigInst)
	if rig == nil then
		return "grip_tool: " .. tostring(rerr), true
	end
	local theRig = rig :: Model
	local grip = ToolFactory.gripCFrame(args.offset, args.rot)
	local function doEquipGrip()
		ToolFactory.equip(tool, theRig)
		ToolFactory.applyGrip(tool, grip)
	end
	if RunService:IsEdit() then
		local rid = ChangeHistoryService:TryBeginRecording("grip_tool")
		doEquipGrip()
		if rid ~= nil then
			ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
		end
	else
		doEquipGrip()
	end
	local note = string.format(
		"grip_tool: equipped '%s' on %s, grip set. Adjust offset/rot and re-call until it sits right.",
		tool.Name,
		theRig.Name
	)
	-- frame the Handle (the held item) + capture so the agent SEES the grip
	local r = if type(context) == "table" then context.cameraRig else nil
	local handle = tool:FindFirstChild("Handle")
	if r == nil or handle == nil then
		return note .. " (no camera/Handle here — capture it yourself)", false
	end
	local state, ferr = r:focus((handle :: Instance):GetFullName())
	if state == nil then
		return note .. " (couldn't frame: " .. tostring(ferr) .. ")", false
	end
	local since = os.time() - 2
	if not CaptureCore.triggerCapture() then
		return note .. " (CaptureService produced no screenshot — focus Studio and re-call)",
			false
	end
	CaptureCore.settle(2)
	local config = if type(context) == "table" then context.config else nil
	local blocks, berr = CaptureCore.fetchCaptures(1, since, config)
	if blocks == nil then
		return note .. " (capture fetch failed: " .. tostring(berr) .. ")", false
	end
	local content: { any } = { { type = "text", text = note } }
	for _, b in blocks do
		table.insert(content, b)
	end
	return content, false
end

local VEC3_SCHEMA = {
	type = "object",
	properties = { x = { type = "number" }, y = { type = "number" }, z = { type = "number" } },
}
local ROT_SCHEMA = {
	type = "object",
	properties = { rx = { type = "number" }, ry = { type = "number" }, rz = { type = "number" } },
}

Item.descriptors = {
	{
		name = "make_tool",
		description = "Turn a built Part/Model (an item's VISUAL — make it first with generate_mesh/"
			.. "author_mesh/paint_texture/primitives) into an equippable Roblox Tool a character can HOLD. It "
			.. "picks a Handle (a single Part, else the `handle` part, else the Model's PrimaryPart/first part), "
			.. "unanchors all parts, welds the rest to the Handle, and names it 'Handle'. Inputs: target "
			.. "(required path), name? (Tool name), handle? (path to the part to grip by). Then fit it in-hand "
			.. "with grip_tool.",
		inputSchema = {
			type = "object",
			properties = {
				target = { type = "string", description = "Path to the built Part/Model." },
				name = { type = "string", description = "Name for the Tool." },
				handle = {
					type = "string",
					description = "Path to the part to use as the Handle (for a multi-part item).",
				},
			},
			required = { "target" },
		},
		destructive = true,
		run = runMakeTool,
	},
	{
		name = "grip_tool",
		description = "EQUIP a Tool on a rig and FIT its grip, returning a capture so you SEE it in-hand. "
			.. "Sets Tool.Grip from intuitive offset {x,y,z} (studs) + rot {rx,ry,rz} (degrees), then frames the "
			.. "item and screenshots it. LOOK at the result and RE-CALL with adjusted offset/rot until the item "
			.. "sits right in the fist (e.g. a sword's blade pointing out, gripped near the hilt). Inputs: tool "
			.. "(required path, from make_tool), rig? (path; else the first workspace rig — spawn_rig first if "
			.. "none), offset?, rot?. Requires the vision sidecar + a focused Studio.",
		inputSchema = {
			type = "object",
			properties = {
				tool = { type = "string", description = "Path to the Tool (from make_tool)." },
				rig = {
					type = "string",
					description = "Path to a Humanoid rig; omit to use the first workspace rig.",
				},
				offset = VEC3_SCHEMA,
				rot = ROT_SCHEMA,
			},
			required = { "tool" },
		},
		destructive = true,
		run = runGripTool,
	},
} :: { Descriptor }

return Item
