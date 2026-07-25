--!strict
-- SerializeSpec: a self-test that runs INSIDE Studio (it cannot run outside Studio because the
-- samples use live Roblox datatypes). M.run() does, per sample:
--   encode -> HttpService:JSONEncode -> JSONDecode -> Decode.decode -> deepEqual
-- printing PASS/FAIL per sample plus a summary, and returns {passed, total, failed}.

local HttpService = game:GetService("HttpService")

local Serialize = require(script.Parent.Serialize)
local Decode = require(script.Parent.Decode)

local M = {}

local EPS = 1e-5

-- Compare two numbers, special-casing non-finite values (NaN~=NaN in Lua) and treating 0==-0.
local function numbersEqual(a: number, b: number, eps: number): boolean
	-- Both NaN.
	if a ~= a and b ~= b then
		return true
	end
	-- One NaN, one not.
	if a ~= a or b ~= b then
		return false
	end
	-- Infinities must match sign exactly.
	if a == math.huge or a == -math.huge or b == math.huge or b == -math.huge then
		return a == b
	end
	-- Finite comparison with epsilon; 0 == -0 holds naturally under math.abs.
	return math.abs(a - b) <= eps
end

-- Compare two equal-length lists of numbers component-wise with the non-finite-aware comparison.
local function componentsEqual(xs: { number }, ys: { number }, eps: number): boolean
	if #xs ~= #ys then
		return false
	end
	for i = 1, #xs do
		if not numbersEqual(xs[i], ys[i], eps) then
			return false
		end
	end
	return true
end

local deepEqual: (a: any, b: any, eps: number) -> boolean

-- Compare two plain tables (arrays or dicts) for deep structural equality.
local function tablesEqual(a: { [any]: any }, b: { [any]: any }, eps: number): boolean
	local seenKeys: { [any]: boolean } = {}
	for k, va in pairs(a) do
		seenKeys[k] = true
		if not deepEqual(va, b[k], eps) then
			return false
		end
	end
	for k in pairs(b) do
		if not seenKeys[k] then
			-- Key present in b but not a; if a[k] was nil we'd have skipped it above.
			if a[k] == nil and b[k] ~= nil then
				return false
			end
		end
	end
	return true
end

function deepEqual(a: any, b: any, eps: number): boolean
	local ta = typeof(a)
	local tb = typeof(b)

	-- Numbers: epsilon + non-finite special-casing (must run before the type-mismatch gate so
	-- NaN-vs-NaN is handled, though both will be "number" here anyway).
	if ta == "number" and tb == "number" then
		return numbersEqual(a :: number, b :: number, eps)
	end

	if ta ~= tb then
		return false
	end

	if ta == "Vector3" then
		local x = a :: Vector3
		local y = b :: Vector3
		return componentsEqual({ x.X, x.Y, x.Z }, { y.X, y.Y, y.Z }, eps)
	elseif ta == "Vector2" then
		local x = a :: Vector2
		local y = b :: Vector2
		return componentsEqual({ x.X, x.Y }, { y.X, y.Y }, eps)
	elseif ta == "CFrame" then
		local x = a :: CFrame
		local y = b :: CFrame
		return componentsEqual({ x:GetComponents() }, { y:GetComponents() }, eps)
	elseif ta == "Color3" then
		local x = a :: Color3
		local y = b :: Color3
		return componentsEqual({ x.R, x.G, x.B }, { y.R, y.G, y.B }, eps)
	elseif ta == "BrickColor" then
		-- The palette number fully determines the entry; compare it directly rather than relying
		-- on userdata __eq.
		return (a :: BrickColor).Number == (b :: BrickColor).Number
	elseif ta == "UDim2" then
		local x = a :: UDim2
		local y = b :: UDim2
		return numbersEqual(x.X.Scale, y.X.Scale, eps)
			and numbersEqual(x.X.Offset, y.X.Offset, eps)
			and numbersEqual(x.Y.Scale, y.Y.Scale, eps)
			and numbersEqual(x.Y.Offset, y.Y.Offset, eps)
	elseif ta == "UDim" then
		local x = a :: UDim
		local y = b :: UDim
		return numbersEqual(x.Scale, y.Scale, eps) and numbersEqual(x.Offset, y.Offset, eps)
	elseif ta == "EnumItem" then
		-- Same EnumItem identity is exact equality.
		return a == b
	elseif ta == "Instance" then
		return a == b
	elseif ta == "table" then
		return tablesEqual(a :: { [any]: any }, b :: { [any]: any }, eps)
	else
		-- boolean, string, nil, and anything else: direct equality.
		return a == b
	end
end

-- Build a deliberately cyclic table for the cycle guard sample.
local function makeCyclic(): { [any]: any }
	local t: { [any]: any } = { name = "root" }
	t.self = t
	return t
end

-- Build a table deeper than the default maxDepth (16) for the truncation sample.
local function makeDeep(): { [any]: any }
	local root: { [any]: any } = {}
	local cursor = root
	for _ = 1, 20 do
		local child: { [any]: any } = {}
		cursor.child = child
		cursor = child
	end
	cursor.leaf = "bottom"
	return root
end

type Sample = {
	name: string,
	value: any,
	-- Optional custom expectation: when the round-trip cannot reproduce the original exactly
	-- (cycles, truncation, instances, enum misses), check the decoded output instead.
	expect: ((decoded: any) -> boolean)?,
	-- When true, SKIP encode/JSON and feed `value` straight into Decode.decode. Used for
	-- adversarial/malformed tagged payloads that the encoder would never emit (e.g. a Color3 tag
	-- carrying a string field), to assert Decode stays TOTAL (never throws) on hostile JSON.
	decodeOnly: boolean?,
}

-- The full sample set covering every supported type plus edges.
local function buildSamples(): { Sample }
	local samples: { Sample } = {}

	local function add(name: string, value: any, expect: ((decoded: any) -> boolean)?)
		table.insert(samples, { name = name, value = value, expect = expect })
	end

	-- Register a decode-only sample: the payload bypasses encode/JSON and is decoded directly,
	-- asserting Decode.decode is TOTAL (does not throw) on the given adversarial input.
	local function addDecodeOnly(name: string, payload: any, expect: (decoded: any) -> boolean)
		table.insert(samples, { name = name, value = payload, expect = expect, decodeOnly = true })
	end

	-- Primitives.
	add("nil", nil)
	add("bool-true", true)
	add("bool-false", false)
	add("string", "hello world")
	add("empty-string", "")
	add("finite-number", 42.5)
	add("zero", 0)
	add("negative-zero", -0)

	-- Non-finite numbers (deepEqual handles NaN/inf special-casing).
	add("nan", 0 / 0)
	add("inf", math.huge)
	add("-inf", -math.huge)

	-- Vectors.
	add("vector3", Vector3.new(1.5, -2.25, 3.0))
	add("vector2", Vector2.new(10.0, 20.0))

	-- CFrames: identity and a rotated one.
	add("cframe-identity", CFrame.new())
	add("cframe-rotated", CFrame.new(1, 2, 3) * CFrame.Angles(0.3, 0.4, 0.5))

	-- Colors: both constructors.
	add("color3-new", Color3.new(0.25, 0.5, 0.75))
	add("color3-fromRGB", Color3.fromRGB(128, 64, 200))

	-- BrickColors: by palette name and by palette number.
	add("brickcolor-name", BrickColor.new("Bright red"))
	add("brickcolor-number", BrickColor.new(26))

	-- UDim types.
	add("udim2", UDim2.new(0.5, 10, 0.25, -5))
	add("udim", UDim.new(0.75, 12))

	-- EnumItem: resolves back by identity if available, else nil (best-effort tolerated).
	add("enumitem-material", Enum.Material.Plastic, function(decoded: any): boolean
		return decoded == Enum.Material.Plastic or decoded == nil
	end)

	-- Nested array + dict mix.
	add("nested", {
		list = { 1, 2, 3, "four" },
		meta = { enabled = true, scale = 2.5, label = "x" },
		vectors = { Vector3.new(1, 0, 0), Vector3.new(0, 1, 0) },
	})

	-- Empty table.
	add("empty-table", {})

	-- Cyclic table: decoded inner reference should be the cycle placeholder.
	add("cyclic", makeCyclic(), function(decoded: any): boolean
		if type(decoded) ~= "table" then
			return false
		end
		if decoded.name ~= "root" then
			return false
		end
		return type(decoded.self) == "table" and decoded.self.__decodeNote == "cycle"
	end)

	-- Over-maxDepth table: somewhere down the chain we hit the truncation placeholder.
	add("over-maxdepth", makeDeep(), function(decoded: any): boolean
		local cursor: any = decoded
		for _ = 1, 25 do
			if type(cursor) ~= "table" then
				return false
			end
			if cursor.__decodeNote == "maxDepth" then
				return true
			end
			cursor = cursor.child
			if cursor == nil then
				return false
			end
		end
		return false
	end)

	-- Instance: workspace resolves back to the live instance.
	add("instance-workspace", workspace, function(decoded: any): boolean
		return decoded == workspace
	end)

	-- Instance with a dotted name. We create it under workspace, encode, then verify the live
	-- lookup resolves (the path array must NOT treat the dot as a separator). Pre-clean fixtures
	-- leaked by prior runs -- FindFirstChild returns the FIRST name match, so a stale duplicate
	-- would win the lookup and break the identity compare -- and destroy the fresh fixture inside
	-- expect once the comparison is made, so repeat runs stay clean.
	while true do
		local stale = workspace:FindFirstChild("weird.name.with.dots")
		if stale == nil then
			break
		end
		stale:Destroy()
	end
	local dotted = Instance.new("Folder")
	dotted.Name = "weird.name.with.dots"
	dotted.Parent = workspace
	add("instance-dotted", dotted, function(decoded: any): boolean
		local hit = decoded == dotted
		dotted:Destroy()
		return hit
	end)

	-- User table literally carrying a "__t" key: must round-trip via the {__t="table"} escape.
	add("user-table-with-__t", {
		__t = "Vector3",
		x = 999,
		note = "this is NOT a real Vector3, just a user table",
		nested = { __t = "fake", deep = true },
	}, function(decoded: any): boolean
		if type(decoded) ~= "table" then
			return false
		end
		return decoded.__t == "Vector3"
			and decoded.x == 999
			and decoded.note == "this is NOT a real Vector3, just a user table"
			and type(decoded.nested) == "table"
			and decoded.nested.__t == "fake"
			and decoded.nested.deep == true
	end)

	-- Adversarial/malformed tagged payloads. These mimic hostile proxy/agent JSON that the encoder
	-- would never produce: tagged geometric values whose numeric fields arrived as strings (or are
	-- missing). ENGINE DRIFT (verified live 2026-07-25): the geometric constructors NO LONGER throw
	-- on non-number args -- numeric strings coerce ("1" -> 1) and other garbage/missing args become
	-- 0 -- so constructor errors can no longer reject these; unguarded, {__t="Vector3",x="a",y=2,
	-- z=3} would decode to Vector3(0,2,3) and land in real properties as a silently-wrong value.
	-- Decode therefore STRICTLY pre-validates type(field)=="number" for every numeric field of the
	-- six geometric tags, restoring the original nil-on-malformed contract engine-side. The samples
	-- pin BOTH contracts: Decode stays TOTAL (the harness pcalls it), and every malformed payload
	-- decodes to nil, never a coerced value. (BrickColor reaches the same doctrine below via
	-- echo-verification, since ITS constructor's failure mode is a silently-wrong palette entry.)
	-- These run decode-only (no encode/JSON round-trip) since the encoder cannot emit them.
	local function isNil(decoded: any): boolean
		return decoded == nil
	end

	-- Even a NUMERIC string ("1") refuses: the encoder emits real JSON numbers, so a string here
	-- always means a malformed producer, and accepting it would pin decode to engine coercion.
	addDecodeOnly("malformed-vector3-string", { __t = "Vector3", x = "1", y = 2, z = 3 }, isNil)
	addDecodeOnly("malformed-vector2-string", { __t = "Vector2", x = "a", y = 2 }, isNil)
	addDecodeOnly("malformed-color3-string", { __t = "Color3", r = "x", g = 0.5, b = 0.5 }, isNil)
	addDecodeOnly("malformed-udim-string", { __t = "UDim", s = "scale", o = 0 }, isNil)
	addDecodeOnly("malformed-udim2-string", { __t = "UDim2", xs = 0, xo = 0, ys = 0, yo = "off" }, isNil)
	addDecodeOnly("malformed-cframe-string", { __t = "CFrame", c = { "x", 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, isNil)
	-- Missing fields refuse too (nil is not a number): no zero-filled phantom values.
	addDecodeOnly("malformed-vector3-missing", { __t = "Vector3" }, isNil)
	addDecodeOnly("malformed-udim2-partial", { __t = "UDim2", xs = 0.5 }, isNil)
	-- CFrame's container: a missing or non-table c is nil as well -- NOT the old identity-CFrame
	-- fallback, which could silently teleport a part to the world origin.
	addDecodeOnly("malformed-cframe-missing", { __t = "CFrame" }, isNil)
	addDecodeOnly("malformed-cframe-nontable", { __t = "CFrame", c = "garbage" }, isNil)

	-- BrickColor's constructor quirk: BrickColor.new NEVER throws on an unknown name/number -- it
	-- warns and silently returns Medium stone grey. Decode must echo-verify the produced entry and
	-- yield nil on a miss, NOT commit the silently-wrong grey.
	addDecodeOnly("malformed-brickcolor-unknown-name", { __t = "BrickColor", name = "Not A Color" }, isNil)
	addDecodeOnly("malformed-brickcolor-bad-number", { __t = "BrickColor", number = 424242 }, isNil)
	addDecodeOnly("malformed-brickcolor-missing", { __t = "BrickColor" }, isNil)

	-- A resolving name takes priority over a (valid, different) palette number...
	addDecodeOnly(
		"brickcolor-name-priority",
		{ __t = "BrickColor", name = "Bright red", number = 1 },
		function(decoded: any): boolean
			return typeof(decoded) == "BrickColor" and (decoded :: BrickColor).Name == "Bright red"
		end
	)
	-- ...and a name miss falls back to the palette number.
	addDecodeOnly(
		"brickcolor-number-fallback",
		{ __t = "BrickColor", name = "Not A Color", number = 21 },
		function(decoded: any): boolean
			return typeof(decoded) == "BrickColor" and (decoded :: BrickColor).Number == 21
		end
	)

	return samples
end

type RunResult = {
	passed: boolean,
	total: number,
	failed: number,
}

function M.run(): RunResult
	local samples = buildSamples()
	local total = #samples
	local failed = 0

	print("=== SerializeSpec: running " .. tostring(total) .. " samples ===")

	for _, sample in ipairs(samples) do
		local ok, result = pcall(function(): boolean
			if sample.decodeOnly then
				-- Decode the adversarial payload directly; the surrounding pcall catches any throw
				-- so a non-total Decode surfaces as a FAIL rather than crashing the whole run.
				local decoded = Decode.decode(sample.value)
				return (sample.expect :: (any) -> boolean)(decoded)
			end

			local encoded = Serialize.encode(sample.value)
			local json = HttpService:JSONEncode(encoded)
			local roundTripped = HttpService:JSONDecode(json)
			local decoded = Decode.decode(roundTripped)

			if sample.expect ~= nil then
				return (sample.expect :: (any) -> boolean)(decoded)
			end
			return deepEqual(sample.value, decoded, EPS)
		end)

		local pass = ok and result == true
		if pass then
			print("  PASS  " .. sample.name)
		else
			failed += 1
			local detail = ""
			if not ok then
				detail = " (error: " .. tostring(result) .. ")"
			end
			print("  FAIL  " .. sample.name .. detail)
		end
	end

	local passedCount = total - failed
	print(
		"=== Summary: "
			.. tostring(passedCount)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)

	return {
		passed = failed == 0,
		total = total,
		failed = failed,
	}
end

return M
