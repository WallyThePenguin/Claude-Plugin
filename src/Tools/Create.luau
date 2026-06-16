--!strict
-- Create: the create_instance tool — make and configure an Instance through the engine API, with NO
-- loadstring. This is what lets the agent build during a PLAYTEST (where loadstring is unavailable),
-- and it works in edit too. Wrapped in an undoable recording in edit; applied directly during play.
--
-- This is a Tools/ submodule. It reaches top-level Serialize/Decode via script.Parent.Parent and its
-- Tools sibling Path via script.Parent.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Decode = require(script.Parent.Parent.Decode)
local Path = require(script.Parent.Path)

local Create = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any) -> (string, boolean),
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

local function runCreate(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.className) ~= "string" then
		return encodeResult({
			ok = false,
			error = "create_instance requires { className = <string>, parent = <path>, "
				.. "name? = <string>, properties? = { [name] = <json value> } }",
		}),
			true
	end

	local parentPath = if type(args.parent) == "string" then args.parent else "game.Workspace"
	local parent, perr = Path.resolve(parentPath)
	if parent == nil then
		return encodeResult({ ok = false, error = "parent: " .. tostring(perr) }), true
	end

	-- Create the instance. Instance.new throws on an unknown/uncreatable class name.
	local okCreate, inst = pcall(Instance.new, args.className)
	if not okCreate or typeof(inst) ~= "Instance" then
		return encodeResult({
			ok = false,
			error = "cannot create '" .. args.className .. "': " .. tostring(inst),
		}),
			true
	end
	local instance = inst :: Instance

	-- In edit, wrap the whole create+configure+parent in one undoable recording; during a playtest
	-- apply directly.
	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("Create " .. args.className)
	end

	if type(args.name) == "string" then
		pcall(function()
			instance.Name = args.name
		end)
	end

	-- Apply properties (structured JSON values, decoded). Each is best-effort; report which landed.
	local applied: { string } = {}
	local failed: { string } = {}
	if type(args.properties) == "table" then
		for propName, rawValue in args.properties do
			local okDecode, decoded = pcall(Decode.decode, rawValue)
			if okDecode then
				local okSet = pcall(function()
					(instance :: any)[propName] = decoded
				end)
				if okSet then
					table.insert(applied, tostring(propName))
				else
					table.insert(failed, tostring(propName))
				end
			else
				table.insert(failed, tostring(propName))
			end
		end
	end

	-- Parent last so the instance is fully configured before it appears/replicates.
	local okParent = pcall(function()
		instance.Parent = parent
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okParent
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okParent then
		instance:Destroy()
		return encodeResult({ ok = false, error = "could not parent to " .. parentPath }), true
	end

	local payload: { [string]: any } = {
		ok = true,
		class = instance.ClassName,
		path = Path.fullPath(instance),
		applied = applied,
	}
	if #failed > 0 then
		payload.failed = failed
	end
	return encodeResult(payload), false
end

Create.descriptors = {
	{
		name = "create_instance",
		description = "Create a new Instance of className, optionally set its Name and a map of "
			.. "properties (structured JSON values, serializer tag scheme), and parent it to a "
			.. "case-sensitive dot path (default game.Workspace). Uses the engine API directly — NO "
			.. "loadstring — so it works during a playtest as well as in edit. In edit the creation is "
			.. "undoable. Returns the new instance's path and which properties applied.",
		inputSchema = {
			type = "object",
			properties = {
				className = { type = "string", description = "e.g. 'Part', 'Folder', 'ScreenGui'." },
				parent = {
					type = "string",
					description = "Dot path to the parent (default game.Workspace).",
				},
				name = { type = "string", description = "Optional Name for the new instance." },
				properties = {
					type = "object",
					description = "Optional map of propertyName -> structured JSON value, e.g. "
						.. '{ "Anchored": true, "Color": {"__t":"Color3","r":1,"g":0,"b":0}, '
						.. '"Size": {"__t":"Vector3","x":4,"y":1,"z":2} }.',
				},
			},
			required = { "className" },
		},
		destructive = true,
		run = runCreate,
	},
} :: { Descriptor }

return Create
