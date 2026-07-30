--!strict
-- Specs for Validate. Run: lune run scripts/test.luau forge-guard
--
-- The bulk of these are hostile inputs, not happy paths. That is the point: a validator
-- that only gets tested with the values it expects is untested.

local Validate = require("../src/Validate")

local NAN = 0 / 0
local INF = math.huge

return function(t)
	-- ---------------------------------------------------------------- number

	t.test("number accepts a plain number", function(expect)
		local ok = Validate.number()(5)
		expect(ok).toBe(true)
	end)

	t.test("number rejects non-numbers, including numeric strings", function(expect)
		local v = Validate.number()
		expect((v("5"))).toBe(false)
		expect((v(true))).toBe(false)
		expect((v(nil))).toBe(false)
		expect((v({}))).toBe(false)
	end)

	-- The headline case. A naive bounds check `n < 1 or n > 100` passes NaN, because
	-- BOTH comparisons are false. Everything downstream then silently poisons.
	t.test("number rejects NaN by default", function(expect)
		local ok, reason = Validate.number()(NAN)
		expect(ok).toBe(false)
		expect(reason).toBe("NaN")
	end)

	t.test("NaN would slip past a bounds check, proving the guard is load-bearing", function(expect)
		-- Both of these are false, which is exactly why NaN needs its own check.
		expect(NAN > 100).toBe(false)
		expect(NAN <= 100).toBe(false)
		local ok = Validate.number({ min = 1, max = 100 })(NAN)
		expect(ok).toBe(false)
	end)

	t.test("number rejects both infinities by default", function(expect)
		local v = Validate.number()
		local ok, reason = v(INF)
		expect(ok).toBe(false)
		expect(reason).toBe("infinite")
		expect((v(-INF))).toBe(false)
	end)

	t.test("NaN and infinity can be opted back in explicitly", function(expect)
		expect((Validate.number({ allowNaN = true })(NAN))).toBe(true)
		expect((Validate.number({ allowInfinite = true })(INF))).toBe(true)
	end)

	t.test("number enforces min and max inclusively", function(expect)
		local v = Validate.number({ min = 1, max = 10 })
		expect((v(1))).toBe(true)
		expect((v(10))).toBe(true)
		expect((v(0))).toBe(false)
		expect((v(11))).toBe(false)
		expect((v(-0.0001))).toBe(false)
	end)

	t.test("integer rejects fractions and accepts negative zero", function(expect)
		local v = Validate.integer(-10, 10)
		expect((v(3))).toBe(true)
		expect((v(3.5))).toBe(false)
		expect((v(-0.0))).toBe(true) -- -0 % 1 == 0, and -0 == 0
	end)

	t.test("number rejects values past the exactly-representable integer range", function(expect)
		local v = Validate.number()
		expect((v(2 ^ 53))).toBe(true) -- exactly 2^53 is the boundary, still allowed
		expect((v(2 ^ 54))).toBe(false)
		expect((v(-(2 ^ 54)))).toBe(false)
	end)

	-- ---------------------------------------------------------------- string

	t.test("string bounds length, with a default ceiling", function(expect)
		local v = Validate.string()
		expect((v("hello"))).toBe(true)
		expect((v(string.rep("a", 256)))).toBe(true)
		-- An unbounded string is a bandwidth and storage attack, so there is a
		-- default even when the caller asks for nothing.
		expect((v(string.rep("a", 257)))).toBe(false)
	end)

	t.test("string honours minLength, maxLength and pattern", function(expect)
		local v = Validate.string({ minLength = 3, maxLength = 8, pattern = "^%a+$" })
		expect((v("abc"))).toBe(true)
		expect((v("ab"))).toBe(false)
		expect((v("abcdefghi"))).toBe(false)
		expect((v("abc1"))).toBe(false)
	end)

	t.test("string rejects non-strings", function(expect)
		expect((Validate.string()(5))).toBe(false)
	end)

	-- ---------------------------------------------------------------- misc scalars

	t.test("boolean is strict", function(expect)
		local v = Validate.boolean()
		expect((v(true))).toBe(true)
		expect((v(false))).toBe(true)
		expect((v(0))).toBe(false)
		expect((v("true"))).toBe(false)
		expect((v(nil))).toBe(false)
	end)

	t.test("literal allows only the listed values", function(expect)
		local v = Validate.literal("sword", "bow")
		expect((v("sword"))).toBe(true)
		expect((v("bow"))).toBe(true)
		expect((v("Sword"))).toBe(false)
		expect((v(nil))).toBe(false)
	end)

	t.test("optional accepts nil but still validates a present value", function(expect)
		local v = Validate.optional(Validate.integer(1, 5))
		expect((v(nil))).toBe(true)
		expect((v(3))).toBe(true)
		expect((v(9))).toBe(false)
		expect((v("3"))).toBe(false)
	end)

	-- ---------------------------------------------------------------- array

	t.test("array validates every element", function(expect)
		local v = Validate.array(Validate.integer(0, 10))
		expect((v({ 1, 2, 3 }))).toBe(true)
		expect((v({ 1, 99 }))).toBe(false)
		expect((v({}))).toBe(true)
	end)

	-- A client can trivially send a sparse table or one with mixed keys. `#t` is
	-- undefined on those, so the length check has to be done by counting.
	t.test("array rejects sparse tables and mixed keys", function(expect)
		local v = Validate.array(Validate.number())
		expect((v({ [1] = 1, [3] = 3 }))).toBe(false)
		expect((v({ [1] = 1, foo = 2 }))).toBe(false)
	end)

	t.test("array bounds length", function(expect)
		local v = Validate.array(Validate.number(), { maxLength = 2, minLength = 1 })
		expect((v({ 1, 2 }))).toBe(true)
		expect((v({ 1, 2, 3 }))).toBe(false)
		expect((v({}))).toBe(false)
	end)

	t.test("array has a default length ceiling", function(expect)
		local big = table.create(65, 1)
		expect((Validate.array(Validate.number())(big))).toBe(false)
	end)

	-- ---------------------------------------------------------------- shape

	t.test("shape validates each declared field", function(expect)
		local v = Validate.shape({
			slot = Validate.integer(1, 9),
			name = Validate.string({ maxLength = 16 }),
		})
		expect((v({ slot = 1, name = "axe" }))).toBe(true)
		expect((v({ slot = 0, name = "axe" }))).toBe(false)
		expect((v({ slot = 1 }))).toBe(false)
	end)

	-- Extra fields are rejected rather than ignored: a client that can add keys can
	-- smuggle one past a future refactor that starts reading it.
	t.test("shape rejects unexpected fields", function(expect)
		local v = Validate.shape({ slot = Validate.integer(1, 9) })
		local ok, reason = v({ slot = 1, admin = true })
		expect(ok).toBe(false)
		expect(reason).toContain("admin")
	end)

	t.test("shape reports the failing field by name", function(expect)
		local v = Validate.shape({ slot = Validate.integer(1, 9) })
		local _, reason = v({ slot = NAN })
		expect(reason).toContain("slot")
		expect(reason).toContain("NaN")
	end)

	-- ---------------------------------------------------------------- map

	t.test("map validates keys and values and bounds entry count", function(expect)
		local v = Validate.map(Validate.string({ maxLength = 8 }), Validate.integer(0, 5), 2)
		expect((v({ a = 1, b = 2 }))).toBe(true)
		expect((v({ a = 9 }))).toBe(false)
		expect((v({ a = 1, b = 2, c = 3 }))).toBe(false)
		expect((v({ [1] = 1 }))).toBe(false)
	end)

	-- ---------------------------------------------------------------- tuple

	t.test("tuple validates an argument list positionally", function(expect)
		local v = Validate.tuple({ Validate.integer(1, 10), Validate.string({ maxLength = 4 }) })
		expect((v(5, "abc"))).toBe(true)
		expect((v(50, "abc"))).toBe(false)
		expect((v(5, "abcde"))).toBe(false)
	end)

	-- Arity is the check people forget. A client can call a three-argument handler with
	-- zero arguments, or with thirty.
	t.test("tuple rejects too many arguments", function(expect)
		local v = Validate.tuple({ Validate.integer(1, 10) })
		local ok, reason = v(5, "extra")
		expect(ok).toBe(false)
		expect(reason).toContain("got 2")
	end)

	t.test("tuple treats missing arguments as nil and rejects them", function(expect)
		local v = Validate.tuple({ Validate.integer(1, 10), Validate.integer(1, 10) })
		expect((v(5))).toBe(false)
		expect((v())).toBe(false)
	end)

	t.test("tuple allows omitted trailing optionals", function(expect)
		local v = Validate.tuple({ Validate.integer(1, 10), Validate.optional(Validate.boolean()) })
		expect((v(5))).toBe(true)
		expect((v(5, true))).toBe(true)
		expect((v(5, "yes"))).toBe(false)
	end)

	t.test("tuple reports which argument failed", function(expect)
		local v = Validate.tuple({ Validate.integer(1, 10), Validate.integer(1, 10) })
		local _, reason = v(5, INF)
		expect(reason).toContain("arg 2")
	end)
end
