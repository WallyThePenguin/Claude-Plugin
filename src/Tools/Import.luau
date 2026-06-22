--!strict
-- Import tool: import_animation. Bring an EXISTING animation (a published asset id, or an in-place
-- KeyframeSequence/Animation) into an editable clip on a rig via AnimationImport (name-based retarget),
-- so list_clip / capture_animation / evaluate / export work on it. For an FBX/GLB file a plugin can't read
-- the file -- use Studio's 3D Importer first, then import the in-place result. DataModel write -> undoable
-- + relays in client view (absent from Relay.LOCAL_TOOLS, like the other animation tools).

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local AnimationImport = require(script.Parent.Parent.AnimationImport)
local Path = require(script.Parent.Path)

local Import = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function resolveRig(target: any): (Instance?, string?)
	if type(target) == "string" and target ~= "" then
		return Path.resolve(target)
	end
	local sel = Selection:Get()
	if #sel > 0 then
		return sel[1], nil
	end
	return nil, "no rig given and nothing selected — pass a rig path or select the rig."
end

-- Wrap the DataModel write in an undoable ChangeHistory recording (edit only).
local function recorded(label: string, fn: () -> (string, boolean)): (string, boolean)
	if not RunService:IsEdit() then
		return fn()
	end
	local rid = ChangeHistoryService:TryBeginRecording(label)
	if rid == nil then
		return label .. ": a change recording is already in progress — try again.", true
	end
	local text, ok = fn()
	ChangeHistoryService:FinishRecording(
		rid,
		if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	return text, ok
end

-- Fetch the source KeyframeSequence from { animation = <asset id> } OR { source = <KeyframeSequence/Animation path> }.
local function resolveSource(args: any): (KeyframeSequence?, string?)
	local function fetchById(id: string): (KeyframeSequence?, string?)
		local url = if string.match(id, "^%d+$") ~= nil then "rbxassetid://" .. id else id
		local ok, ks = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(url)
		end)
		if not ok or typeof(ks) ~= "Instance" or not (ks :: Instance):IsA("KeyframeSequence") then
			return nil,
				"couldn't fetch animation '"
					.. url
					.. "' (must be a public or owned animation): "
					.. tostring(ks)
		end
		return ks :: KeyframeSequence, nil
	end

	local anim = if type(args.animation) == "string" and args.animation ~= ""
		then args.animation
		else nil
	if anim ~= nil then
		return fetchById(anim)
	end
	local src = if type(args.source) == "string" and args.source ~= "" then args.source else nil
	if src == nil then
		return nil,
			"requires { animation = <asset id> } OR { source = <KeyframeSequence/Animation path> }"
	end
	local inst, perr = Path.resolve(src)
	if inst == nil then
		return nil, "source path didn't resolve: " .. tostring(perr)
	end
	if inst:IsA("KeyframeSequence") then
		return inst :: KeyframeSequence, nil
	end
	if inst:IsA("Animation") then
		local id = (inst :: Animation).AnimationId
		if id == nil or id == "" then
			return nil, "the Animation at '" .. src .. "' has no AnimationId."
		end
		return fetchById(id)
	end
	return nil, "source must be a KeyframeSequence or an Animation (got " .. inst.ClassName .. ")."
end

-- Clip name: explicit arg, else the source's own name (unless the generic "KeyframeSequence"), else default.
local function clipName(args: any, sourceKS: KeyframeSequence): string
	if type(args.clip) == "string" and args.clip ~= "" then
		return args.clip
	end
	if sourceKS.Name ~= "" and sourceKS.Name ~= "KeyframeSequence" then
		return sourceKS.Name
	end
	return "ImportedClip"
end

local function runImport(input: any, _context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local rig, rerr = resolveRig(args.rig)
	if rig == nil then
		return "import_animation: " .. tostring(rerr), true
	end
	local sourceKS, serr = resolveSource(args)
	if sourceKS == nil then
		return "import_animation: " .. tostring(serr), true
	end
	local clip = clipName(args, sourceKS :: KeyframeSequence)
	local text, ok = recorded("Import animation", function()
		return AnimationImport.importInto(sourceKS :: KeyframeSequence, rig :: Instance, clip)
	end)
	return text, not ok
end

Import.descriptors = {
	{
		name = "import_animation",
		description = "Import an EXISTING animation into an editable clip on a rig (then list_clip / "
			.. "capture_animation / evaluate / export it). Sources: animation = a published asset id "
			.. "(rbxassetid://N or a bare number), OR source = an instance path to a KeyframeSequence or an "
			.. "Animation already in the place. It retargets the source's poses onto the target rig's joints "
			.. "BY NAME (clean for R15->R15) and reports joint coverage. For an FBX/GLB file (e.g. a "
			.. "Quaternius clip) a plugin CAN'T read the file: first use Studio's 3D Importer (File > Import "
			.. "3D) to bring it in as an in-place rig+animation, then import_animation that in-place "
			.. "KeyframeSequence. Inputs: animation OR source, rig (path or selection), clip (default = the "
			.. "source name or 'ImportedClip').",
		inputSchema = {
			type = "object",
			properties = {
				animation = {
					type = "string",
					description = "Published animation asset id (rbxassetid://N or a bare number).",
				},
				source = {
					type = "string",
					description = "Instance path to an in-place KeyframeSequence or Animation.",
				},
				rig = {
					type = "string",
					description = "Target rig path; omit to use the selection.",
				},
				clip = {
					type = "string",
					description = "Clip name to save under rig/AnimSaves (default: the source name or 'ImportedClip').",
				},
			},
		},
		destructive = true,
		run = runImport,
	},
} :: { Descriptor }

return Import
