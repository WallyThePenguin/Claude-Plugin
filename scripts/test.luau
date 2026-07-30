--!strict
-- forge test runner: runs every packages/*/tests/*.spec.luau outside Roblox Studio.
--
--   lune run scripts/test.luau                 -- everything
--   lune run scripts/test.luau forge-signal    -- one package
--   lune run scripts/test.luau -- --verbose     -- name every passing test
--
-- WHY A CUSTOM RUNNER: TestEZ and friends assume a Roblox datamodel. Lune has no
-- `script`, no `game`, no instance tree - so a spec here requires plain relative
-- paths and the modules under test must not touch Roblox globals.
--
-- THE LAYERING RULE THIS ENFORCES: a package's `init.luau` is a thin aggregator
-- (`return require(script.Thing)`) using Roblox require syntax, which Lune cannot
-- resolve. So specs require the SIBLING modules directly - `../src/Signal`, never
-- `../src/init`. Keep logic in siblings and the untestable surface stays one line.

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

type Matchers = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	toContain: (needle: any) -> (),
	toBeCloseTo: (expected: number, tolerance: number?) -> (),
	toThrow: (substring: string?) -> (),
}

type TestContext = {
	test: (name: string, fn: (expect: (value: any) -> Matchers) -> ()) -> (),
}

local GREEN = "\27[32m"
local RED = "\27[31m"
local DIM = "\27[2m"
local BOLD = "\27[1m"
local RESET = "\27[0m"

local args = process.args
local verbose = false
local filters: { string } = {}
for _, arg in args do
	if arg == "--verbose" or arg == "-v" then
		verbose = true
	elseif arg:sub(1, 1) ~= "-" then
		table.insert(filters, arg)
	end
end

local function matches(name: string): boolean
	if #filters == 0 then
		return true
	end
	for _, f in filters do
		if string.find(name, f, 1, true) then
			return true
		end
	end
	return false
end

-- Deep structural comparison, so toEqual is useful on tables.
local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a :: any do
		if not deepEqual(v, (b :: any)[k]) then
			return false
		end
	end
	for k in b :: any do
		if (a :: any)[k] == nil then
			return false
		end
	end
	return true
end

local function render(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local parts = {}
	for k, v in value :: any do
		table.insert(parts, string.format("%s = %s", tostring(k), tostring(v)))
	end
	table.sort(parts)
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function makeExpect(value: any): Matchers
	local function fail(message: string): ()
		error(message, 0)
	end
	return {
		toBe = function(expected)
			if value ~= expected then
				fail(`expected {render(expected)} but got {render(value)}`)
			end
		end,
		toEqual = function(expected)
			if not deepEqual(value, expected) then
				fail(`expected {render(expected)} (deep) but got {render(value)}`)
			end
		end,
		toBeTruthy = function()
			if not value then
				fail(`expected a truthy value but got {render(value)}`)
			end
		end,
		toBeFalsy = function()
			if value then
				fail(`expected a falsy value but got {render(value)}`)
			end
		end,
		toBeNil = function()
			if value ~= nil then
				fail(`expected nil but got {render(value)}`)
			end
		end,
		toContain = function(needle)
			if type(value) == "string" then
				if not string.find(value, needle :: string, 1, true) then
					fail(`expected {render(value)} to contain {render(needle)}`)
				end
				return
			end
			if type(value) == "table" then
				for _, item in value :: any do
					if item == needle then
						return
					end
				end
				fail(`expected a table containing {render(needle)}`)
			end
			fail(`toContain needs a string or table, got {type(value)}`)
		end,
		toBeCloseTo = function(expected, tolerance)
			local limit = tolerance or 1e-6
			if type(value) ~= "number" then
				fail(`toBeCloseTo needs a number, got {type(value)}`)
			end
			if math.abs((value :: number) - expected) > limit then
				fail(`expected {expected} +/- {limit} but got {value}`)
			end
		end,
		toThrow = function(substring)
			if type(value) ~= "function" then
				fail(`toThrow needs a function, got {type(value)}`)
			end
			local ok, err = pcall(value :: any)
			if ok then
				fail("expected the call to throw, but it returned")
			end
			if substring then
				local text = tostring(err)
				if not string.find(text, substring, 1, true) then
					fail(`expected the error to contain {render(substring)}, got {render(text)}`)
				end
			end
		end,
	}
end

-- Discover spec files under packages/*/tests/ and game/tests/.
local specs: { { package: string, path: string, requirePath: string } } = {}

local function collectSpecs(dir: string, packageName: string)
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			collectSpecs(full, packageName)
		elseif string.match(entry, "%.spec%.luau?$") then
			-- Specs are required relative to THIS file, which lives in scripts/.
			local requirePath = "../" .. string.gsub(full, "%.luau?$", "")
			table.insert(specs, { package = packageName, path = full, requirePath = requirePath })
		end
	end
end

if fs.isDir("packages") then
	for _, pkg in fs.readDir("packages") do
		if fs.isDir(`packages/{pkg}`) then
			collectSpecs(`packages/{pkg}/tests`, pkg)
		end
	end
end
collectSpecs("game/tests", "game")

table.sort(specs, function(a, b)
	return a.path < b.path
end)

local totalPass = 0
local totalFail = 0
local failures: { string } = {}
local skippedFiles = 0

print(`{BOLD}forge test{RESET} {DIM}({#specs} spec file(s)){RESET}`)

for _, spec in specs do
	if not matches(spec.package) and not matches(spec.path) then
		skippedFiles += 1
		continue
	end

	local okRequire, moduleOrErr = pcall(require, spec.requirePath)
	if not okRequire then
		totalFail += 1
		local message = `{spec.path}: failed to load - {tostring(moduleOrErr)}`
		table.insert(failures, message)
		print(`{RED}x{RESET} {spec.path} {DIM}(load failed){RESET}`)
		continue
	end
	if type(moduleOrErr) ~= "function" then
		totalFail += 1
		local message = `{spec.path}: a spec must return function(t), got {type(moduleOrErr)}`
		table.insert(failures, message)
		print(`{RED}x{RESET} {spec.path} {DIM}(bad shape){RESET}`)
		continue
	end

	local filePass, fileFail = 0, 0
	local context: TestContext = {
		test = function(name, fn)
			local ok, err = pcall(fn, makeExpect)
			if ok then
				filePass += 1
				totalPass += 1
				if verbose then
					print(`  {GREEN}ok{RESET} {name}`)
				end
			else
				fileFail += 1
				totalFail += 1
				table.insert(failures, `{spec.path} > {name}: {tostring(err)}`)
				print(`  {RED}FAIL{RESET} {name}`)
				print(`       {DIM}{tostring(err)}{RESET}`)
			end
		end,
	}

	local okRun, runErr = pcall(moduleOrErr :: any, context)
	if not okRun then
		totalFail += 1
		table.insert(failures, `{spec.path}: threw outside a test - {tostring(runErr)}`)
		print(`{RED}x{RESET} {spec.path} {DIM}(threw outside a test){RESET}`)
		continue
	end

	local mark = if fileFail == 0 then `{GREEN}ok{RESET}` else `{RED}x{RESET}`
	print(`{mark} {spec.path} {DIM}({filePass} passed, {fileFail} failed){RESET}`)
end

print("")
if skippedFiles > 0 then
	print(`{DIM}{skippedFiles} file(s) skipped by filter{RESET}`)
end

if totalFail == 0 then
	if totalPass == 0 then
		print(`{DIM}no tests ran{RESET}`)
	else
		print(`{GREEN}{BOLD}{totalPass} passed{RESET}`)
	end
else
	print(`{RED}{BOLD}{totalFail} failed{RESET}, {totalPass} passed`)
	print("")
	for _, failure in failures do
		print(`{RED}-{RESET} {failure}`)
	end
	process.exit(1)
end
