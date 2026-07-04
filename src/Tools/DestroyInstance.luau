--!strict
-- Destroy: the destroy_instance tool — delete the instance at a path via Instance:Destroy(), with NO
-- loadstring (works during a playtest as well as in edit; undoable in edit). A safety guard refuses to
-- delete `game` itself or a top-level service, so the agent can clear its own builds but not nuke
-- Workspace/Players. Mirrors Create.luau/Properties.luau plumbing.
--
-- Tools/ submodule: reaches its Tools siblings (Path, RegionGuard) via script.Parent.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Path = require(script.Parent.Path)
local RegionGuard = require(script.Parent.RegionGuard)

local Destroy = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

-- Refuse to delete the DataModel itself, a top-level service (direct child of game), or an instance
-- already detached from the tree. Returns an error string when protected, else nil.
local function protectedReason(inst: Instance): string?
	if inst == game then
		return "refusing to destroy the DataModel (game)"
	end
	if inst.Parent == game then
		return "refusing to destroy a top-level service: " .. inst.Name
	end
	if inst.Parent == nil then
		return "instance is already detached (no parent)"
	end
	return nil
end

local function runDestroy(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.path) ~= "string" then
		return encodeResult({ ok = false, error = "destroy_instance requires { path = <string> }" }),
			true
	end

	local inst, err = Path.resolve(args.path)
	if inst == nil then
		return encodeResult({ ok = false, error = err }), true
	end
	local target = inst :: Instance

	local guard = protectedReason(target)
	if guard ~= nil then
		return encodeResult({ ok = false, error = guard }), true
	end

	-- Region guard (parallel writer): the target must be within the writer's region. No-op serially.
	local okRegion, regionErr = RegionGuard.check(target, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end

	-- Capture identity BEFORE destroying (the instance is locked/cleared afterward).
	local fullPath = Path.fullPath(target)
	local class = target.ClassName

	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("Destroy " .. class)
		-- nil = a recording is stuck open: proceed UNRECORDED rather than wedge the pipeline.
	end

	local okDestroy = pcall(function()
		target:Destroy()
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okDestroy
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okDestroy then
		return encodeResult({ ok = false, error = "Destroy() failed for " .. fullPath }), true
	end
	return encodeResult({ ok = true, destroyed = fullPath, class = class }), false
end

Destroy.descriptors = {
	{
		name = "destroy_instance",
		description = "Delete the instance at a case-sensitive dot path via Instance:Destroy(). Uses the "
			.. "engine API directly — NO loadstring — so it works DURING A PLAYTEST as well as in edit "
			.. "(undoable in edit). Use this to remove a build you no longer want instead of reparenting "
			.. "it elsewhere. Refuses to destroy game or a top-level service. Returns the destroyed path "
			.. "and class.",
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Dot-separated, case-sensitive path to the instance to delete.",
				},
			},
			required = { "path" },
		},
		destructive = true,
		run = runDestroy,
	},
} :: { Descriptor }

return Destroy
