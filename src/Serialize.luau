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
-- - STRICT NUMERIC FIELDS (2026-07 engine drift): the geometric constructors no longer throw on
--   non-number args (numeric strings coerce, other garbage/missing args become 0), so Decode
--   itself validates type(field)=="number" for EVERY numeric field of the six geometric tags
--   (Vector3/Vector2/CFrame/Color3/UDim2/UDim) and decodes the whole tag to nil on any mismatch
--   -- numeric STRINGS included -- restoring the original nil-on-malformed contract engine-side.
--   For CFrame a missing/non-table c is likewise nil. A malformed payload can therefore never
--   land a silently-zero-coerced value in a real property (write tools refuse the nil up front).
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

export type Options = {
	maxDepth: number?,
	maxTableKeys: number?,
}

-- Internal recursion context: resolved limits, the visited-identity set for cycle detection, and
-- a running total key counter (boxed so it is shared by reference across recursive calls).
type Ctx = {
	maxDepth: number,
	maxKeys: number,
	seen: { [any]: boolean },
	count: number,
}

local DEFAULT_MAX_DEPTH = 16
local DEFAULT_MAX_TABLE_KEYS = 5000

-- Determine whether a number is finite (not nan/inf/-inf).
local function isFinite(n: number): boolean
	-- NaN is the only value not equal to itself; +/-inf are caught by the bound check.
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Encode a non-finite number into its sentinel string.
local function nonFiniteToken(n: number): string
	if n ~= n then
		return "nan"
	elseif n == math.huge then
		return "inf"
	else
		return "-inf"
	end
end

-- Decide whether a table is a contiguous array (1..n with no gaps and no extra keys).
local function isArray(t: { [any]: any }): boolean
	local count = 0
	for _ in pairs(t) do
		count += 1
	end
	if count == 0 then
		-- Empty tables are treated as arrays (encode to a JSON array); shape is moot.
		return true
	end
	for i = 1, count do
		if rawget(t, i) == nil then
			return false
		end
	end
	return true
end

-- Forward declarations.
local encodeValue: (value: any, depth: number, ctx: Ctx) -> any
local encodeTable: (t: { [any]: any }, depth: number, ctx: Ctx) -> any

-- Walk the entries of one table into a fresh array/dict, applying the key-count guard. Returns the
-- encoded container, or a truncation sentinel if the key budget is exceeded mid-walk. The caller is
-- responsible for clearing ctx.seen[t] before returning.
local function encodeEntries(t: { [any]: any }, depth: number, ctx: Ctx): any
	if isArray(t) then
		local arr: { any } = {}
		for i = 1, #t do
			ctx.count += 1
			if ctx.count > ctx.maxKeys then
				return { __t = "truncated", reason = "maxKeys" }
			end
			arr[i] = encodeValue(rawget(t, i), depth + 1, ctx)
		end
		return arr
	end

	local dict: { [string]: any } = {}
	for k, v in pairs(t) do
		ctx.count += 1
		if ctx.count > ctx.maxKeys then
			return { __t = "truncated", reason = "maxKeys" }
		end
		local key: string
		if type(k) == "string" then
			key = k
		else
			-- Non-string/number keys coerced via tostring; integer keys in a dict-shaped table
			-- are stringified for a deterministic JSON boundary.
			key = tostring(k)
		end
		dict[key] = encodeValue(v, depth + 1, ctx)
	end
	return dict
end

function encodeTable(t: { [any]: any }, depth: number, ctx: Ctx): any
	if depth > ctx.maxDepth then
		return { __t = "truncated", reason = "maxDepth" }
	end

	if ctx.seen[t] then
		return { __t = "cycle" }
	end
	ctx.seen[t] = true

	-- Escape user tables that themselves carry a "__t" key so Decode can round-trip them: the
	-- entries are encoded plainly and wrapped under {__t="table", v=...}.
	if rawget(t, "__t") ~= nil then
		local inner = encodeEntries(t, depth, ctx)
		ctx.seen[t] = nil
		return { __t = "table", v = inner }
	end

	local result = encodeEntries(t, depth, ctx)
	ctx.seen[t] = nil
	return result
end

-- Build the ordered array path of child names from the top-level DataModel child down to inst.
local function instancePath(inst: Instance): { string }
	local names: { string } = {}
	local current: Instance? = inst
	while current ~= nil and current.Parent ~= nil do
		table.insert(names, current.Name)
		current = current.Parent
	end
	-- names is currently leaf-first; reverse to top-level-child-first.
	local reversed: { string } = {}
	local count = #names
	for i = count, 1, -1 do
		reversed[count - i + 1] = names[i]
	end
	return reversed
end

function encodeValue(value: any, depth: number, ctx: Ctx): any
	local t = typeof(value)

	if value == nil or t == "boolean" or t == "string" then
		return value
	elseif t == "number" then
		local n = value :: number
		if isFinite(n) then
			return n
		end
		return { __t = "number", v = nonFiniteToken(n) }
	elseif t == "Instance" then
		local inst = value :: Instance
		return {
			__t = "Instance",
			class = inst.ClassName,
			name = inst.Name,
			path = instancePath(inst),
			display = inst:GetFullName(),
		}
	elseif t == "Vector3" then
		local v = value :: Vector3
		return { __t = "Vector3", x = v.X, y = v.Y, z = v.Z }
	elseif t == "Vector2" then
		local v = value :: Vector2
		return { __t = "Vector2", x = v.X, y = v.Y }
	elseif t == "CFrame" then
		local cf = value :: CFrame
		local c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11 = cf:GetComponents()
		return {
			__t = "CFrame",
			c = { c00, c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11 },
		}
	elseif t == "Color3" then
		local v = value :: Color3
		return { __t = "Color3", r = v.R, g = v.G, b = v.B }
	elseif t == "BrickColor" then
		local v = value :: BrickColor
		return { __t = "BrickColor", name = v.Name, number = v.Number }
	elseif t == "UDim2" then
		local v = value :: UDim2
		return { __t = "UDim2", xs = v.X.Scale, xo = v.X.Offset, ys = v.Y.Scale, yo = v.Y.Offset }
	elseif t == "UDim" then
		local v = value :: UDim
		return { __t = "UDim", s = v.Scale, o = v.Offset }
	elseif t == "EnumItem" then
		local v = value :: EnumItem
		local enumName = tostring(v.EnumType):gsub("^Enum%.", "")
		return { __t = "EnumItem", enum = enumName, item = v.Name, value = v.Value }
	elseif t == "table" then
		return encodeTable(value :: { [any]: any }, depth, ctx)
	else
		-- Unknown/unsupported datatype: coerce to a string sentinel so output stays JSON-safe.
		return { __t = "unsupported", typeof = t, display = tostring(value) }
	end
end

-- Public entry point. Returns JSON-safe values (no metatables, finite-only numbers).
function M.encode(value: any, opts: Options?): any
	local options: Options = opts or {}
	local ctx: Ctx = {
		maxDepth = options.maxDepth or DEFAULT_MAX_DEPTH,
		maxKeys = options.maxTableKeys or DEFAULT_MAX_TABLE_KEYS,
		seen = {},
		count = 0,
	}
	return encodeValue(value, 0, ctx)
end

return M
