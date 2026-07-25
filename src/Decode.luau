--!strict
-- FROZEN SERIALIZER TAG SCHEME (Serialize emits these; Decode consumes these; this comment
-- block must be BYTE-IDENTICAL at the top of both Serialize.luau and Decode.luau):
-- - primitives (nil/bool/string) and FINITE numbers: passthrough unchanged.
-- - non-finite number -> {__t="number", v="nan"|"inf"|"-inf"}  (JSONEncode SILENTLY emits invalid
--   JSON for raw nan/inf, so finite-only output is mandatory; there is NO encode-side backstop).
-- - Instance -> {__t="Instance", class=ClassName, name=Name, path=<ARRAY of child names from the
--   top-level DataModel child down to the instance>, display=GetFullName()}. Use an ORDERED ARRAY
--   of names, NOT a dotted string (GetFullName does not escape periods). display is human-only.
-- - Vector3 -> {__t="Vector3", x,y,z}; Vector2 -> {__t="Vector2", x,y}.
-- - CFrame -> {__t="CFrame", c={...12 floats from GetComponents() in its exact order...}}; Decode
--   rebuilds via CFrame.new(table.unpack(c)). The GetComponents order and the 12-arg constructor
--   order MUST match (verify against docs).
-- - Color3 -> {__t="Color3", r=v.R, g=v.G, b=v.B}  (components in 0..1).
-- - BrickColor -> {__t="BrickColor", name=v.Name, number=v.Number}. Decode rebuilds by name first,
--   then by palette number. BrickColor.new NEVER throws on an unknown name/number -- it warns and
--   silently returns Medium stone grey -- so Decode echo-verifies the produced entry against the
--   requested field (.Name/.Number must match) and treats a mismatch as a miss (nil).
-- - UDim2 -> {__t="UDim2", xs,xo,ys,yo}; UDim -> {__t="UDim", s,o}.
-- - EnumItem -> {__t="EnumItem", enum=<bare type name, e.g. "Material", strip a leading "Enum." via
--   gsub("^Enum%.","")>, item=v.Name, value=v.Value}. Decode resolves the EnumItem from enum+item.
-- - table -> recursively encoded, preserving array-vs-dict shape. ESCAPE user tables that
--   themselves carry a "__t" key: if rawget(t,"__t") ~= nil, emit {__t="table",
--   v=<recursively-encoded t>}; Decode unwraps {__t="table"} to decode(v.v) WITHOUT re-inspecting
--   the inner __t.
-- - Guards: depth>maxDepth(default 16) -> {__t="truncated", reason="maxDepth"}; a revisited table
--   identity -> {__t="cycle"}; total key count>maxTableKeys(default 5000) -> {__t="truncated",
--   reason="maxKeys"}. Non-string/number keys coerced via tostring. Tables with non-contiguous
--   integer keys normalize to dicts with stringified keys (deterministic across the JSON boundary).
-- - unsupported datatype (a typeof() outside the cases above) -> {__t="unsupported", typeof=<type>,
--   display=tostring(v)}; a JSON-safe last resort. Decode passes it through plainly (stays total).

local M = {}

-- Run a constructor under pcall, returning the produced value on success or nil on any error.
-- ENGINE NOTE (verified live 2026-07-25): the geometric constructors (Vector3/Vector2/Color3/
-- UDim/UDim2/CFrame .new) NO LONGER throw on non-number args -- numeric strings coerce ("1" -> 1)
-- and other garbage/missing args become 0 -- so for those try() rarely fires anymore. It REMAINS
-- the totality backstop: decode input is arbitrary proxy/agent JSON, some constructors still do
-- throw (e.g. BrickColor.new on a table), and the documented "decode is TOTAL (never throws)"
-- contract must hold regardless of engine behavior drift.
local function try<T>(fn: (...any) -> T, ...: any): T?
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	return nil
end

-- Rebuild a non-finite number from its sentinel token.
local function tokenToNumber(token: string): number
	if token == "nan" then
		return 0 / 0
	elseif token == "inf" then
		return math.huge
	elseif token == "-inf" then
		return -math.huge
	else
		-- Defensive: unknown token decodes to NaN rather than throwing.
		return 0 / 0
	end
end

-- Echo-verified BrickColor constructor from a palette name (string) or palette number (number).
-- BrickColor.new NEVER throws on an unknown name/number -- it warns and silently returns Medium
-- stone grey -- so a successful construction alone proves nothing. Verify the produced entry
-- echoes the requested field; a mismatch is a palette miss (nil), never a silently-wrong color.
-- Exposed as M.coerceBrickColor: set_property/create_instance also use it to promote a PLAIN
-- palette-name string (the natural spelling, e.g. "Bright red") for BrickColor-typed properties.
local function brickColorFrom(key: any): BrickColor?
	if type(key) == "string" then
		local bc = try(BrickColor.new, key)
		if bc ~= nil and (bc :: BrickColor).Name == key then
			return bc
		end
	elseif type(key) == "number" then
		local bc = try(BrickColor.new, key)
		if bc ~= nil and (bc :: BrickColor).Number == key then
			return bc
		end
	end
	return nil
end

-- Best-effort resolution of an EnumItem from its bare enum type name and item name. Returns nil
-- on any miss. Defensively strips a leading "Enum." in case the encoder ever stored the dotted
-- form. pcall-guarded since Enum[...] indexing throws on an unknown enum type.
local function resolveEnumItem(enumName: string, itemName: string): EnumItem?
	local bare = (enumName:gsub("^Enum%.", ""))
	local ok, result = pcall(function(): EnumItem?
		local enumObject = (Enum :: any)[bare]
		if enumObject == nil then
			return nil
		end
		return enumObject:FromName(itemName)
	end)
	if ok then
		return result
	end
	return nil
end

-- Best-effort resolution of a live Instance from its name-array path. Uses FindFirstChild for the
-- FIRST segment (NOT GetService, which errors on garbage and can create services), then walks down
-- the array via FindFirstChild. All pcall-guarded. Returns the live Instance or nil. This is
-- documented as a best-effort lookup, NOT true reconstruction.
local function resolveInstance(path: { any }?): Instance?
	if type(path) ~= "table" then
		return nil
	end
	local ok, result = pcall(function(): Instance?
		local current: Instance? = nil
		for index, segment in ipairs(path :: { any }) do
			if type(segment) ~= "string" then
				return nil
			end
			if index == 1 then
				current = game:FindFirstChild(segment)
			else
				if current == nil then
					return nil
				end
				current = (current :: Instance):FindFirstChild(segment)
			end
			if current == nil then
				return nil
			end
		end
		return current
	end)
	if ok then
		return result
	end
	return nil
end

-- Forward declaration.
local decodeValue: (value: any) -> any

-- Decode a plain (untagged) table, preserving array-vs-dict shape by recursing per entry.
local function decodePlainTable(t: { [any]: any }): any
	local result: { [any]: any } = {}
	for k, v in pairs(t) do
		result[k] = decodeValue(v)
	end
	return result
end

function decodeValue(value: any): any
	if type(value) ~= "table" then
		-- primitives (nil/bool/string) and finite numbers pass through unchanged.
		return value
	end

	local tag = rawget(value, "__t")
	if tag == nil then
		return decodePlainTable(value)
	end

	if tag == "number" then
		return tokenToNumber(tostring(value.v))
	elseif tag == "Vector3" then
		-- Guarded: non-number fields from hostile JSON would otherwise throw.
		return try(Vector3.new, value.x, value.y, value.z)
	elseif tag == "Vector2" then
		return try(Vector2.new, value.x, value.y)
	elseif tag == "CFrame" then
		local c = value.c
		if type(c) == "table" then
			return try(function(): CFrame
				return CFrame.new(table.unpack(c :: { number }))
			end)
		end
		return CFrame.new()
	elseif tag == "Color3" then
		return try(Color3.new, value.r, value.g, value.b)
	elseif tag == "BrickColor" then
		-- Name first (unique + human-readable), then palette number; nil when neither resolves.
		if type(value.name) == "string" then
			local byName = brickColorFrom(value.name)
			if byName ~= nil then
				return byName
			end
		end
		return brickColorFrom(value.number)
	elseif tag == "UDim2" then
		return try(UDim2.new, value.xs, value.xo, value.ys, value.yo)
	elseif tag == "UDim" then
		return try(UDim.new, value.s, value.o)
	elseif tag == "EnumItem" then
		-- Returns the resolved EnumItem, or nil on miss (best-effort).
		return resolveEnumItem(tostring(value.enum), tostring(value.item))
	elseif tag == "Instance" then
		-- Best-effort live lookup; nil if the path no longer resolves.
		return resolveInstance(value.path)
	elseif tag == "table" then
		-- Unwrap an escaped user table: decode v.v WITHOUT re-inspecting its inner __t.
		local inner = value.v
		if type(inner) ~= "table" then
			return inner
		end
		return decodePlainTable(inner)
	elseif tag == "cycle" then
		return { __decodeNote = "cycle" }
	elseif tag == "truncated" then
		local reason = value.reason
		if type(reason) == "string" then
			return { __decodeNote = reason }
		end
		return { __decodeNote = "truncated" }
	else
		-- Unknown tag (e.g. "unsupported" or future tags): decode the table plainly so the call
		-- remains total and the raw payload survives for inspection.
		return decodePlainTable(value)
	end
end

-- Public entry point. TOTAL: never throws. Inverse of Serialize.encode where reconstructible.
function M.decode(value: any): any
	return decodeValue(value)
end

-- Public echo-verified BrickColor coercion (palette name string or palette number). TOTAL: nil on
-- any miss or non-string/number input. The write tools use it to accept the plain palette-name
-- spelling for properties the catalog types as "BrickColor".
function M.coerceBrickColor(key: any): BrickColor?
	return brickColorFrom(key)
end

return M
