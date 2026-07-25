--!strict
-- Handheld-item tools: make_tool (toolify a built Part/Model into a Roblox Tool) + grip_tool (equip on a
-- rig + set the grip from intuitive offset/rot + capture so the agent fits the grip by LOOKING).
-- Destructive (DataModel writes); RELAY. Parent-only.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local ToolFactory = require(script.Parent.Parent.ToolFactory)
local RigWorkbench = require(script.Parent.Parent.RigWorkbench)
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
		local hinst, herr = Path.resolve(args.handle)
		if hinst == nil then
			return "make_tool: handle '" .. tostring(args.handle) .. "' did not resolve" .. (if herr
					~= nil
				then " — " .. herr
				else ""),
				true
		end
		if not hinst:IsA("BasePart") then
			return "make_tool: handle '" .. tostring(args.handle) .. "' is not a BasePart", true
		end
		if hinst ~= target and not hinst:IsDescendantOf(target :: Instance) then
			return "make_tool: handle must be a part of the target (got "
				.. hinst:GetFullName()
				.. ")",
				true
		end
		handleHint = hinst
	end
	local toolName = if type(args.name) == "string" then args.name else nil
	local tool: Tool?, err: string?
	local chainCount = 0
	local function doToolify()
		tool, err, chainCount = ToolFactory.toolify(target :: Instance, handleHint, toolName)
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
	local chainNote = if chainCount > 0
		then string.format(
			" ARTICULATED: %d Motor6D chain joint(s) kept (fit as animatable pose channels — "
				.. "key them via add_keyframe poses + weapon=true).",
			chainCount
		)
		else ""
	return string.format(
		"make_tool OK: '%s' at %s (%d part(s): a Handle + %d welded/jointed, all unanchored).%s Equip + fit it with grip_tool.",
		t.Name,
		t:GetFullName(),
		partCount,
		math.max(0, partCount - 1),
		chainNote
	),
		false
end

-- Doctrine (2026-07-11): every authoring/preview path purges playing AnimationTracks first —
-- a stale playing track re-stamps its pose on every StepAnimations call, silently overwriting
-- fits, resets, and keypose snapshots (the add_keyframe frozen-snapshot aggravator).
local function stopPlayingTracks(rig: Model)
	local controller = rig:FindFirstChildOfClass("Humanoid")
		or rig:FindFirstChildOfClass("AnimationController")
	local animator = if controller ~= nil then controller:FindFirstChildOfClass("Animator") else nil
	if animator == nil then
		return
	end
	local anim = animator :: Animator
	pcall(function()
		for _, tr in anim:GetPlayingAnimationTracks() do
			tr:Stop(0)
		end
		anim:StepAnimations(0)
	end)
end

-- Frame the rig + screenshot so the agent SEES the result in context; falls back to the bare
-- note when no camera/capture is available. Shared by the equip and release paths.
local function captureTail(note: string, theRig: Model, context: any): (any, boolean)
	local r = if type(context) == "table" then context.cameraRig else nil
	if r == nil then
		return note .. " (no camera here — capture it yourself)", false
	end
	local state, ferr = r:focus(theRig:GetFullName())
	if state == nil then
		return note .. " (couldn't frame: " .. tostring(ferr) .. ")", false
	end
	local since = os.time() - 2
	local shotOk = false
	pcall(function()
		-- Neutral light: a backlit rig+item renders as a silhouette nobody can judge.
		CaptureCore.withNeutralLighting(function()
			shotOk = CaptureCore.triggerCapture()
		end)
	end)
	if not shotOk then
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

local function runGripTool(input: any, context: any): (any, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.tool) ~= "string" or args.tool == "" then
		return "grip_tool requires { tool = <path to a Tool>, rig?, offset? {x,y,z}, rot? {rx,ry,rz}, release? }",
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
	-- Release path (arm-hold C0 residue fix, 2026-07-11): un-equip + restore the rig. The rig
	-- the Tool is actually PARENTED to wins over resolution (release must hit the held rig).
	if args.release == true then
		local heldRig: Model? = nil
		local hp = tool.Parent
		if hp ~= nil and hp:IsA("Model") and hp:FindFirstChildOfClass("Humanoid") ~= nil then
			heldRig = hp :: Model
		end
		if heldRig == nil then
			local r2, rerr2 = ToolFactory.resolveRig(rigInst)
			if r2 == nil then
				return "grip_tool release: " .. tostring(rerr2), true
			end
			heldRig = r2 :: Model
		end
		local relRig = heldRig :: Model
		stopPlayingTracks(relRig)
		local restored = 0
		local function doRelease()
			restored = ToolFactory.release(tool, relRig)
			-- Re-home the Tool where equip found it (fallback: workspace).
			local priorPath = tool:GetAttribute(ToolFactory.PRE_EQUIP_PARENT_ATTR)
			local dest: Instance? = nil
			if type(priorPath) == "string" and priorPath ~= "" then
				dest = Path.resolve(priorPath)
			end
			tool.Parent = if dest ~= nil then dest else workspace
			tool:SetAttribute(ToolFactory.PRE_EQUIP_PARENT_ATTR, nil)
		end
		if RunService:IsEdit() then
			local rid = ChangeHistoryService:TryBeginRecording("grip_tool release")
			doRelease()
			if rid ~= nil then
				ChangeHistoryService:FinishRecording(rid, Enum.FinishRecordingOperation.Commit)
			end
		else
			doRelease()
		end
		-- Neutralize Motor6D Transforms + StepAnimations so the C0 restore is VISIBLE (its own
		-- ChangeHistory recording — sequenced after ours, same pattern as the equip path).
		RigWorkbench.resetPose(relRig)
		local note = string.format(
			"grip_tool release: un-equipped '%s' from %s — grip motor + off-hand IK removed, "
				.. "%d joint C0/C1 pair(s) restored to pre-hold values, pose reset to neutral. "
				.. "Tool re-homed to %s.",
			tool.Name,
			relRig.Name,
			restored,
			if tool.Parent ~= nil then (tool.Parent :: Instance):GetFullName() else "nil"
		)
		return captureTail(note, relRig, context)
	end
	local rig, rerr = ToolFactory.resolveRig(rigInst)
	if rig == nil then
		return "grip_tool: " .. tostring(rerr), true
	end
	local theRig = rig :: Model
	-- Purge playing tracks BEFORE fitting/resetting (doctrine; a playing track would re-stamp
	-- its pose over the T-pose reset and the capture below).
	stopPlayingTracks(theRig)
	-- Optional HAND-LOCAL hold overrides (candidate rendering): {x,y,z} unit-ish vectors.
	local function vec3Arg(v: any): Vector3?
		if type(v) ~= "table" then
			return nil
		end
		local out = Vector3.new(tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0)
		return if out.Magnitude > 1e-4 then out else nil
	end
	local frameGrip = if args.offset == nil and args.rot == nil
		then ToolFactory.gripFromFrame(
			tool,
			theRig,
			vec3Arg(args.holdBlade),
			vec3Arg(args.holdEdge)
		)
		else nil
	local grip = if frameGrip ~= nil
		then frameGrip
		else ToolFactory.gripCFrame(args.offset, args.rot)
	-- T-pose-first (SP2c): frame auto-alignment must fit against the canonical NEUTRAL pose —
	-- C0/C1 frozen on a posed rig would offset every authored clip by the pose delta.
	local poseReset = false
	if frameGrip ~= nil then
		local _, resetOk = RigWorkbench.resetPose(theRig)
		poseReset = resetOk
	end
	-- Off-hand IK (SP2c item 6): offhand=true stamps/reuses a Semantic_OffHand attachment on the
	-- Handle + creates a LeftUpperArm->LeftHand IKControl targeting it; offhand=false removes it.
	local offhandNote = ""
	local offhandPos: Vector3? = nil
	if type(args.offhandOffset) == "table" then
		offhandPos = Vector3.new(
			tonumber(args.offhandOffset.x) or 0,
			tonumber(args.offhandOffset.y) or 0,
			tonumber(args.offhandOffset.z) or 0
		)
	end
	local chainFitted, chainNames, chainFlipped = 0, {} :: { string }, 0
	local function doEquipGrip()
		-- Fit the articulated chain BEFORE the grip joint exists (weapon-as-limb): fitChain
		-- freezes the tool's CURRENT geometry into the chain joints' C0/C1, so it must read the
		-- built placement, not a hand-snapped one. Idempotent — already-fitted joints are kept.
		-- The Handle root also normalizes joint DIRECTION (tip-down authored joints are flipped
		-- so every chain channel is actually drivable by the Animator).
		local handleRoot = tool:FindFirstChild("Handle")
		chainFitted, chainNames, chainFlipped = ToolFactory.fitChain(
			tool,
			if handleRoot ~= nil and handleRoot:IsA("BasePart") then handleRoot else nil
		)
		ToolFactory.equip(tool, theRig)
		ToolFactory.applyGrip(tool, grip)
		if type(args.offhand) == "boolean" then
			local otext, _ook = ToolFactory.setOffHand(tool, theRig, args.offhand, offhandPos)
			offhandNote = " " .. otext
		end
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
	local chainNote = if #chainNames > 0
		then string.format(
			" Weapon chain: %d joint(s) [%s]%s%s — each is an animatable pose channel "
				.. "(add_keyframe poses + weapon=true keys them all).",
			#chainNames,
			table.concat(chainNames, ", "),
			if chainFitted > 0
				then string.format(" (%d newly fit from built geometry)", chainFitted)
				else "",
			if chainFlipped > 0
				then string.format(
					" (%d joint(s) FLIPPED hilt-outward so the Animator can drive them)",
					chainFlipped
				)
				else ""
		)
		else ""
	local note = string.format(
		"grip_tool: equipped '%s' on %s, grip set. Adjust offset/rot and re-call until it sits right.",
		tool.Name,
		theRig.Name
	) .. (if frameGrip ~= nil then " (aligned to Semantic_Grip frame)" else "") .. (if poseReset
		then " (rig pose reset to neutral first)"
		else "") .. chainNote .. offhandNote
	-- frame the RIG (the held pose) + capture so the agent SEES the grip in context. (Framing the tiny
	-- Handle part gives an unusable extreme close-up — verified live; the whole-rig shot shows the arm +
	-- item so the grip is assessable; the agent can camera_orbit/zoom for detail.)
	return captureTail(note, theRig, context)
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
			.. "with grip_tool. Stamps a candidate Semantic_Grip at the Handle center if none exists — run "
			.. "stamp_frame for the full semantic frame (family schema) before previewing.",
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
			.. "ARTICULATED weapons (a Motor6D segment chain inside the Tool — snake sword/flail) are fit "
			.. "automatically: each chain joint's C0/C1 freeze the built geometry (hinge at the segment base) "
			.. "and become animatable pose channels named after their Part1. "
			.. "Sets Tool.Grip from intuitive offset {x,y,z} (studs) + rot {rx,ry,rz} (degrees), then frames the "
			.. "item and screenshots it. LOOK at the result and RE-CALL with adjusted offset/rot until the item "
			.. "sits right in the fist (e.g. a sword's blade pointing out, gripped near the hilt). Inputs: tool "
			.. "(required path, from make_tool), rig? (path; else the first workspace rig — spawn_rig first if "
			.. "none), offset?, rot?, offhand? (true = two-handed: IK the LeftHand to a Semantic_OffHand "
			.. "attachment on the Handle; offhandOffset {x,y,z} moves that attachment in Handle-local studs), "
			.. "release? (true = UN-equip: removes the grip motor + off-hand IK, restores every joint's "
			.. "pre-hold C0/C1 snapshotted at equip time, resets the pose to neutral, and re-homes the Tool "
			.. "where it came from — ALWAYS release before validating rest poses or authoring keyposes on an "
			.. "unheld rig). Requires the vision sidecar + a focused Studio. When the tool carries a "
			.. "Semantic_Grip frame (stamp_frame) and no offset/rot is given, the grip AUTO-ALIGNS to the "
			.. "declared frame.",
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
				holdBlade = {
					type = "object",
					description = "HAND-LOCAL blade direction override for the auto-align "
						.. "({x,y,z}; default ToolFactory.HOLD_BLADE_DIR = 0,0,-1 out the "
						.. "knuckles). Candidate-rendering seam — omit for the doctrine hold.",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
				holdEdge = {
					type = "object",
					description = "HAND-LOCAL edge direction override ({x,y,z}; default "
						.. "0,-1,0 toward the palm). Orthogonalized against holdBlade.",
					properties = {
						x = { type = "number" },
						y = { type = "number" },
						z = { type = "number" },
					},
				},
				offhand = {
					type = "boolean",
					description = "true = two-handed hold: stamp/reuse a Semantic_OffHand attachment "
						.. "on the Handle and IK the LeftHand to it (IKControl under the Humanoid). "
						.. "false = remove the off-hand IK.",
				},
				offhandOffset = VEC3_SCHEMA,
				release = {
					type = "boolean",
					description = "true = un-equip the Tool: remove the AgentEditGrip motor + "
						.. "off-hand IK, restore the joints' pre-hold C0/C1 (snapshotted at equip), "
						.. "reset the pose to neutral, re-home the Tool. Other args are ignored.",
				},
			},
			required = { "tool" },
		},
		destructive = true,
		run = runGripTool,
	},
} :: { Descriptor }

return Item
