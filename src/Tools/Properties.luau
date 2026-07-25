--!strict
-- Properties: two structured tools — get_properties (read) and set_property (write).
--
-- Both build a result TABLE and JSONEncode it into the contentText, returning isError per outcome
-- (the uniform structured-tool contract).
--
-- This is a Tools/ submodule. It reaches the top-level Serialize/Decode via script.Parent.Parent and
-- its Tools siblings (Path, PropertyCatalog) via script.Parent.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Serialize = require(script.Parent.Parent.Serialize)
local Decode = require(script.Parent.Parent.Decode)
local Path = require(script.Parent.Path)
local PropertyCatalog = require(script.Parent.PropertyCatalog)
local RegionGuard = require(script.Parent.RegionGuard)

local Properties = {}

-- Mirror the registry's Descriptor shape (init.luau owns the canonical type).
export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

-- Encode a result table into compact JSON. Total via pcall fallback.
local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

-- get_properties: read every catalogued property for the instance's IsA chain, serialize each value.
local function runGetProperties(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.path) ~= "string" then
		return encodeResult({ ok = false, error = "get_properties requires { path = <string> }" }),
			true
	end

	local inst, err = Path.resolve(args.path)
	if inst == nil then
		return encodeResult({ ok = false, error = err }), true
	end
	local target = inst :: Instance

	local catalog = PropertyCatalog.get(target)
	local props: { [string]: any } = {}
	local shadowed: { string } = {}

	for name, valueType in catalog do
		-- Read under pcall: some catalogued names may not exist on this exact subclass, or reading
		-- may yield (rare). A failed read is simply omitted.
		local okRead, value = pcall(function(): any
			return (target :: any)[name]
		end)
		if okRead then
			-- Shadow guard: the catalog says this property is a NON-Instance, but a child sharing the
			-- property's name shadows it via instance indexing sugar, so the read returned that child
			-- (an Instance). Skip it — serializing it would misreport a child as the property value.
			if valueType ~= "Instance" and typeof(value) == "Instance" then
				table.insert(shadowed, name)
			else
				props[name] = Serialize.encode(value)
			end
		end
	end

	local payload: { [string]: any } = {
		ok = true,
		class = target.ClassName,
		path = Path.fullPath(target),
		properties = props,
	}
	if #shadowed > 0 then
		-- Surface which names were skipped because a same-named child shadowed the property.
		payload.shadowed = shadowed
	end
	return encodeResult(payload), false
end

-- Does the supplied raw value carry a serializer tag whose decode is a best-effort LOOKUP that
-- can legitimately return nil on a miss (an Instance reference, an EnumItem, or a BrickColor
-- palette entry)? Such a value decoding to nil means the lookup DID NOT RESOLVE, not that nil was
-- the intended assignment — assigning that nil would either silently deparent/clear the target
-- (Parent, PrimaryPart) and commit a surprising "success", or throw the engine's cryptic
-- type-mismatch error (BrickColor). set_property refuses the case up front with a clear message.
local function isUnresolvableReference(rawValue: any, decoded: any): boolean
	if decoded ~= nil then
		return false
	end
	if type(rawValue) ~= "table" then
		return false
	end
	local tag = rawValue.__t
	return tag == "Instance" or tag == "EnumItem" or tag == "BrickColor"
end

-- set_property: decode a structured JSON value and assign it under an undoable recording.
local function runSetProperty(input: any, context: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	if type(args.path) ~= "string" or type(args.name) ~= "string" then
		return encodeResult({
			ok = false,
			error = "set_property requires { path = <string>, name = <string>, value = <json> }",
		}),
			true
	end

	local name = args.name :: string

	-- Refuse never-settable names up front (no resolve, no recording).
	if PropertyCatalog.readOnly[name] then
		return encodeResult({ ok = false, error = "property is read-only: " .. name }), true
	end

	local inst, err = Path.resolve(args.path)
	if inst == nil then
		return encodeResult({ ok = false, error = err }), true
	end
	local target = inst :: Instance

	-- Region guard (parallel writer): the target must be within the writer's assigned region. No-op
	-- for the serial parent (no context.writeRegion).
	local okRegion, regionErr = RegionGuard.check(target, context)
	if not okRegion then
		return encodeResult({ ok = false, error = regionErr }), true
	end

	-- Decode the structured value BEFORE opening any recording (Decode is total but may resolve to
	-- nil; we guard with pcall regardless so nothing escapes). value is a structured JSON value such
	-- as {"__t":"Color3","r":1,"g":0,"b":0}.
	local okDecode, decoded = pcall(Decode.decode, args.value)
	if not okDecode then
		return encodeResult({ ok = false, error = "value decode failed" }), true
	end

	-- Guard the "decoded successfully TO nil" case for reference-typed tags: a tagged Instance or
	-- EnumItem value that resolves to nil means the reference did not resolve. Assigning that nil
	-- (e.g. Parent = nil, PrimaryPart = nil) would deparent/clear the target and commit a misleading
	-- {ok=true}; refuse instead. (Plain JSON nil for a non-reference value still passes through to
	-- the engine, which rejects type-mismatched nils via the pcall'd assignment below.)
	if isUnresolvableReference(args.value, decoded) then
		return encodeResult({ ok = false, error = "value reference did not resolve" }), true
	end

	-- Plain-spelling BrickColor coercion (parity with create_instance): the natural way to write a
	-- BrickColor is its palette name ("Bright red"), which the engine never accepts raw. Promote a
	-- resolving palette name/number when the catalog types this property as BrickColor; a
	-- non-palette string falls through so the engine's own rejection still surfaces the typo.
	if
		(type(decoded) == "string" or type(decoded) == "number")
		and PropertyCatalog.get(target)[name] == "BrickColor"
	then
		local coerced = Decode.coerceBrickColor(decoded)
		if coerced ~= nil then
			decoded = coerced
		end
	end

	-- Parent guard for a confined writer: a writer must not move an in-region instance OUT of its
	-- region (a new parent outside it) NOR orphan it (Parent = nil / non-Instance, which detaches it
	-- from the region tree). A reference property that merely POINTS outside (ObjectValue.Value,
	-- PrimaryPart) is fine — only Parent relocates. All no-ops for the serial parent (no writeRegion).
	if name == "Parent" then
		local hasRegion = type(context) == "table" and context.writeRegion ~= nil
		if typeof(decoded) == "Instance" then
			local okReparent = RegionGuard.check(decoded :: Instance, context)
			if not okReparent then
				return encodeResult({
					ok = false,
					error = "re-parent outside your assigned region is not permitted",
				}),
					true
			end
		elseif hasRegion then
			return encodeResult({
				ok = false,
				error = "Parent must be set to an instance inside your assigned region",
			}),
				true
		end
	end

	-- In EDIT mode, wrap the assignment in an undoable recording. During a playtest (Run/Play) there
	-- is no edit-history to record into, so assign directly against the running session.
	local rid: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("SetProperty " .. name)
		-- nil = a recording is stuck open: proceed UNRECORDED rather than wedge the pipeline.
	end

	local okSet, setErr = pcall(function()
		(target :: any)[name] = decoded
	end)

	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okSet
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	if not okSet then
		local msg = tostring(setErr)
		-- "lacking capability" is an ENGINE security gate (RobloxScriptSecurity+, e.g.
		-- Lighting.Technology / LightingStyle): NOTHING at plugin level can ever write it, so
		-- retrying is pointless. Say so plainly and name the only path that works (the user,
		-- via Studio's Properties pane).
		if string.find(msg, "lacking capability", 1, true) then
			msg = "property '"
				.. name
				.. "' is engine-locked above plugin security ("
				.. msg
				.. "). No plugin or script can set it; do not retry -- ask the user to set it "
				.. "manually in Studio's Properties pane."
		end
		return encodeResult({ ok = false, error = msg }), true
	end

	-- Echo the freshly-read value (re-serialized) so Claude sees exactly what landed (engine may
	-- normalize, e.g. Orientation wrapping).
	local okRead, readBack = pcall(function(): any
		return (target :: any)[name]
	end)
	local echoed: any = if okRead then Serialize.encode(readBack) else nil
	return encodeResult({ ok = true, name = name, value = echoed }), false
end

local STRUCTURED_VALUE_NOTE = "value is a structured JSON value matching the "
	.. "serializer tag scheme, e.g. a plain string/number/bool, or "
	.. '{"__t":"Color3","r":1,"g":0,"b":0}, '
	.. '{"__t":"Vector3","x":..,"y":..,"z":..}, '
	.. '{"__t":"EnumItem","enum":"Material","item":"Plastic"}, '
	.. '{"__t":"BrickColor","name":"Bright red"}. For a BrickColor-typed property a plain '
	.. "palette-name string is also accepted."

-- Exported descriptor list; init.luau concatenates it into the master registry.
Properties.descriptors = {
	{
		name = "get_properties",
		description = "Read the curated, type-tagged set of properties for the instance at a "
			.. "case-sensitive dot path (unioned across its IsA chain). Values are returned in the "
			.. "serializer tag scheme. Catalogued properties that are shadowed by a same-named child "
			.. "are skipped and listed under 'shadowed'.",
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Dot-separated, case-sensitive instance path.",
				},
			},
			required = { "path" },
		},
		destructive = false,
		run = runGetProperties,
	},
	{
		name = "set_property",
		description = "Set one property on the instance at a case-sensitive dot path. In edit mode the "
			.. "change is wrapped in an undoable ChangeHistory recording; during a playtest it applies "
			.. "to the running session. Read-only names (e.g. ClassName) are refused. "
			.. STRUCTURED_VALUE_NOTE,
		inputSchema = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Dot-separated, case-sensitive instance path.",
				},
				name = {
					type = "string",
					description = "The property name to set (exact casing, e.g. 'TextureID').",
				},
				value = {
					description = "Structured JSON value to assign (serializer tag scheme).",
				},
			},
			required = { "path", "name", "value" },
		},
		destructive = true,
		run = runSetProperty,
	},
} :: { Descriptor }

return Properties
