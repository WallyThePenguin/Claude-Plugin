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
-- Roblox geometric constructors (Vector3.new, Vector2.new, Color3.new, UDim.new, UDim2.new,
-- CFrame.new) raise a type error when handed a non-number argument, and JSONDecode never coerces
-- JSON strings to numbers. Decode input is arbitrary proxy/agent JSON, so a malformed payload such
-- as {__t="Color3", r="x"} would otherwise escape M.decode. Routing every reconstructor through
-- this helper preserves the documented "decode is TOTAL (never throws)" contract.
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

return M
