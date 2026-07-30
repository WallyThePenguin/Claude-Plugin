--!strict
-- Validate: composable runtime validators for anything that crosses the client/server
-- boundary.
--
-- Pure Luau. No `game`, no `script`, no services - which is the point: a package whose
-- whole value is correctly-validated boundaries must have those boundaries under test,
-- and that means running under Lune. (See docs/superpowers/notes/2026-07-30-mirror-vs-
-- ours-decision.md for why this is written here rather than delegated to osyrisrblx/t.)
--
-- A validator is a plain function: (value: unknown) -> (boolean, string?). It returns
-- `true` or `false, reason`. The reason is for YOUR logs, never for the client - telling
-- an attacker exactly which check they failed is free reconnaissance.
--
-- THE DEFAULTS ARE THE SECURITY. `Validate.number()` rejects NaN and both infinities
-- without being asked, because:
--   * NaN defeats every comparison. `NaN > 0` is false AND `NaN <= 0` is false, so a
--     naive `if amount < 1 or amount > MAX then reject end` lets NaN straight through.
--   * NaN poisons arithmetic silently and persists into saved data.
--   * math.huge passes any upper bound expressed as `< math.huge`.
-- Opting back in takes an explicit flag, so it is visible in review.

export type Validator = (value: unknown) -> (boolean, string?)

local Validate = {}

-- 2^53: past this, integer arithmetic in a 64-bit float stops being exact, so any
-- bound built on it is a lie. Numeric validators refuse to exceed it unless told to.
local MAX_SAFE_INTEGER = 9007199254740992

export type NumberOptions = {
	min: number?,
	max: number?,
	integer: boolean?,
	allowNaN: boolean?,
	allowInfinite: boolean?,
}

function Validate.number(options: NumberOptions?): Validator
	local opts: NumberOptions = options or {}
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "number" then
			return false, `expected number, got {typeof(value)}`
		end
		local n = value :: number

		-- NaN first: it is the only value that is not equal to itself, and every
		-- comparison below would silently succeed-by-failing on it.
		if n ~= n then
			if not opts.allowNaN then
				return false, "NaN"
			end
			return true
		end

		if n == math.huge or n == -math.huge then
			if not opts.allowInfinite then
				return false, "infinite"
			end
			return true
		end

		if opts.integer and n % 1 ~= 0 then
			return false, `expected an integer, got {n}`
		end

		-- Beyond 2^53 the value may not be the integer the caller thinks it is.
		if math.abs(n) > MAX_SAFE_INTEGER then
			return false, "outside the exactly-representable integer range"
		end

		if opts.min ~= nil and n < opts.min then
			return false, `{n} < min {opts.min}`
		end
		if opts.max ~= nil and n > opts.max then
			return false, `{n} > max {opts.max}`
		end
		return true
	end
end

-- The common case, named so it is hard to get wrong: a bounded whole number.
function Validate.integer(min: number, max: number): Validator
	return Validate.number({ min = min, max = max, integer = true })
end

export type StringOptions = {
	minLength: number?,
	maxLength: number?,
	pattern: string?,
}

-- maxLength is not optional in practice: an unbounded string is a memory and bandwidth
-- attack, and it will end up in a DataStore. Default it rather than trust the caller.
local DEFAULT_MAX_STRING = 256

function Validate.string(options: StringOptions?): Validator
	local opts: StringOptions = options or {}
	local maxLength = opts.maxLength or DEFAULT_MAX_STRING
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "string" then
			return false, `expected string, got {typeof(value)}`
		end
		local s = value :: string
		if #s > maxLength then
			return false, `length {#s} > max {maxLength}`
		end
		if opts.minLength ~= nil and #s < opts.minLength then
			return false, `length {#s} < min {opts.minLength}`
		end
		if opts.pattern ~= nil and not string.match(s, opts.pattern) then
			return false, "failed pattern"
		end
		return true
	end
end

function Validate.boolean(): Validator
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "boolean" then
			return false, `expected boolean, got {typeof(value)}`
		end
		return true
	end
end

-- One of a fixed set. The right shape for anything the client "chooses" - a weapon slot,
-- a team, a shop tab - because it cannot be widened by accident later.
function Validate.literal(...: unknown): Validator
	local allowed = table.pack(...)
	return function(value: unknown): (boolean, string?)
		for index = 1, allowed.n do
			if allowed[index] == value then
				return true
			end
		end
		return false, "not an allowed value"
	end
end

function Validate.optional(inner: Validator): Validator
	return function(value: unknown): (boolean, string?)
		if value == nil then
			return true
		end
		return inner(value)
	end
end

export type ArrayOptions = {
	maxLength: number?,
	minLength: number?,
}

local DEFAULT_MAX_ARRAY = 64

function Validate.array(inner: Validator, options: ArrayOptions?): Validator
	local opts: ArrayOptions = options or {}
	local maxLength = opts.maxLength or DEFAULT_MAX_ARRAY
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		local t = value :: { [unknown]: unknown }

		-- Count keys the hard way. `#t` is undefined on a table with holes, and a
		-- client can absolutely send `{[1]=x, [3]=y}` or `{[1]=x, foo=y}`.
		local count = 0
		for _ in t do
			count += 1
		end

		local length = 0
		while t[length + 1] ~= nil do
			length += 1
		end
		if length ~= count then
			return false, "not a dense array"
		end

		if length > maxLength then
			return false, `length {length} > max {maxLength}`
		end
		if opts.minLength ~= nil and length < opts.minLength then
			return false, `length {length} < min {opts.minLength}`
		end

		for index = 1, length do
			local ok, reason = inner(t[index])
			if not ok then
				return false, `[{index}]: {reason}`
			end
		end
		return true
	end
end

-- An exact table shape. Extra fields are REJECTED, not ignored: a client that can add
-- keys can smuggle a field past a later refactor that starts reading it.
function Validate.shape(fields: { [string]: Validator }): Validator
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		local t = value :: { [unknown]: unknown }
		for key, validator in fields do
			local ok, reason = validator(t[key])
			if not ok then
				return false, `{key}: {reason}`
			end
		end
		for key in t do
			if typeof(key) ~= "string" or fields[key :: string] == nil then
				return false, `unexpected field {tostring(key)}`
			end
		end
		return true
	end
end

function Validate.map(
	keyValidator: Validator,
	valueValidator: Validator,
	maxEntries: number?
): Validator
	local limit = maxEntries or DEFAULT_MAX_ARRAY
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "table" then
			return false, `expected table, got {typeof(value)}`
		end
		local count = 0
		for key, entry in value :: { [unknown]: unknown } do
			count += 1
			if count > limit then
				return false, `more than {limit} entries`
			end
			local keyOk, keyReason = keyValidator(key)
			if not keyOk then
				return false, `key {tostring(key)}: {keyReason}`
			end
			local valueOk, valueReason = valueValidator(entry)
			if not valueOk then
				return false, `value at {tostring(key)}: {valueReason}`
			end
		end
		return true
	end
end

-- A Roblox Instance of a given class. `typeof` returns "Instance" for any instance, and
-- the IsA call is pcall-guarded so a table pretending to be an instance cannot throw.
--
-- IMPORTANT: this proves the value is an instance of that class. It proves NOTHING about
-- whether the caller may act on it. A player can pass any instance they can see,
-- including another player's character. Ownership is a separate check, and it is yours.
function Validate.instanceOf(className: string): Validator
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return false, `expected Instance, got {typeof(value)}`
		end
		local ok, isA = pcall(function()
			return (value :: any):IsA(className)
		end)
		if not ok then
			return false, "IsA threw"
		end
		if not isA then
			return false, `expected a {className}`
		end
		return true
	end
end

export type Vector3Options = {
	maxMagnitude: number?,
}

-- A finite Vector3. Every component is checked for NaN and infinity independently,
-- because a single poisoned component is enough to break downstream distance maths.
function Validate.vector3(options: Vector3Options?): Validator
	local opts: Vector3Options = options or {}
	return function(value: unknown): (boolean, string?)
		if typeof(value) ~= "Vector3" then
			return false, `expected Vector3, got {typeof(value)}`
		end
		local v = value :: any
		for _, axis in { "X", "Y", "Z" } do
			local component = v[axis]
			if component ~= component then
				return false, `{axis} is NaN`
			end
			if component == math.huge or component == -math.huge then
				return false, `{axis} is infinite`
			end
		end
		if opts.maxMagnitude ~= nil and v.Magnitude > opts.maxMagnitude then
			return false, `magnitude > {opts.maxMagnitude}`
		end
		return true
	end
end

-- An argument list, arity included. This is the entry point forge-net uses, and arity is
-- the check people forget: a client can send zero arguments to a handler expecting three,
-- or thirty to one expecting none.
export type TupleValidator = (...unknown) -> (boolean, string?)

function Validate.tuple(validators: { Validator }): TupleValidator
	local expected = #validators
	return function(...: unknown): (boolean, string?)
		local received = select("#", ...)
		if received > expected then
			return false, `expected {expected} argument(s), got {received}`
		end
		for index = 1, expected do
			local ok, reason = validators[index]((select(index, ...)))
			if not ok then
				return false, `arg {index}: {reason}`
			end
		end
		return true
	end
end

return Validate
