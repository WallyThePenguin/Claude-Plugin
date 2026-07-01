--!strict
-- ScriptEditSpec: in-Studio self-test for the pure ScriptEdit engine (the script tools' logic).
-- Run via the bridge: luau 'return tostring(require(script.Parent.ScriptEditSpec).run().passed)'

local ScriptEdit = require(script.Parent.ScriptEdit)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local SRC = "local a = 1\nlocal b = 2\nprint(a + b)"

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("splitLines: basic / trailing newline / CRLF / empty", function()
		local basic = ScriptEdit.splitLines("a\nb")
		if #basic ~= 2 or basic[1] ~= "a" or basic[2] ~= "b" then
			return false, "basic split wrong"
		end
		if #ScriptEdit.splitLines("a\n") ~= 1 then
			return false, "trailing newline made a phantom line"
		end
		local crlf = ScriptEdit.splitLines("a\r\nb\r")
		if crlf[1] ~= "a" or crlf[2] ~= "b" then
			return false, "\\r not stripped"
		end
		if #ScriptEdit.splitLines("") ~= 0 then
			return false, "empty source should be 0 lines"
		end
		return true
	end)

	add("numberLines: window, clamp, truncated flag", function()
		local text, w = ScriptEdit.numberLines(SRC, 2, 2)
		if w.total ~= 3 or w.startLine ~= 2 or w.endLine ~= 2 or w.truncated ~= true then
			return false, "window meta wrong"
		end
		if string.find(text, "2| local b = 2", 1, true) == nil then
			return false, "numbered line missing: " .. text
		end
		local _, w2 = ScriptEdit.numberLines(SRC, -5, 99)
		if w2.startLine ~= 1 or w2.endLine ~= 3 or w2.truncated ~= false then
			return false, "clamping wrong"
		end
		local empty, w3 = ScriptEdit.numberLines("")
		return empty == "" and w3.total == 0
	end)

	add("countOccurrences: plain, non-overlapping", function()
		if ScriptEdit.countOccurrences(SRC, "local") ~= 2 then
			return false, "expected 2 'local'"
		end
		if ScriptEdit.countOccurrences("aaaa", "aa") ~= 2 then
			return false, "overlap handling wrong"
		end
		-- Plain: magic characters are literal.
		return ScriptEdit.countOccurrences("a+b a+b", "a+b") == 2
	end)

	add("applyFind: unique replace works and is literal", function()
		local new, err = ScriptEdit.applyFind(SRC, "print(a + b)", "print(a * b) -- %1")
		if new == nil then
			return false, tostring(err)
		end
		-- Replacement must be literal: %1 survives as text.
		return string.find(new, "print(a * b) -- %1", 1, true) ~= nil
	end)

	add("applyFind: zero matches / ambiguous / all=true / no-op guards", function()
		local _, errNone = ScriptEdit.applyFind(SRC, "nope", "x")
		if errNone == nil then
			return false, "0 matches should error"
		end
		local _, errMulti = ScriptEdit.applyFind(SRC, "local", "shared")
		if errMulti == nil or string.find(errMulti, "2 matches", 1, true) == nil then
			return false, "ambiguity guard missing: " .. tostring(errMulti)
		end
		local all, _, n = ScriptEdit.applyFind(SRC, "local", "shared", true)
		if all == nil or n ~= 2 or ScriptEdit.countOccurrences(all, "shared") ~= 2 then
			return false, "all=true replace wrong"
		end
		local _, errSame = ScriptEdit.applyFind(SRC, "local", "local", true)
		return errSame ~= nil
	end)

	add("applyRange: replace / delete / insert / append / bounds", function()
		local rep = ScriptEdit.applyRange(SRC, 2, 2, "local b = 20")
		if rep ~= "local a = 1\nlocal b = 20\nprint(a + b)" then
			return false, "replace wrong: " .. tostring(rep)
		end
		local del = ScriptEdit.applyRange(SRC, 2, 2, "")
		if del ~= "local a = 1\nprint(a + b)" then
			return false, "delete wrong"
		end
		local ins = ScriptEdit.applyRange(SRC, 2, 1, "-- inserted")
		if ins ~= "local a = 1\n-- inserted\nlocal b = 2\nprint(a + b)" then
			return false, "insert-before wrong: " .. tostring(ins)
		end
		local app = ScriptEdit.applyRange(SRC, 4, 3, "-- tail")
		if app ~= SRC .. "\n-- tail" then
			return false, "append wrong: " .. tostring(app)
		end
		local _, errLo = ScriptEdit.applyRange(SRC, 0, 1, "x")
		local _, errHi = ScriptEdit.applyRange(SRC, 1, 4, "x")
		return errLo ~= nil and errHi ~= nil
	end)

	add("grep: plain default posture and pattern mode", function()
		local hits = ScriptEdit.grep(SRC, "local", true)
		if hits == nil or #hits ~= 2 or hits[1].line ~= 1 or hits[2].line ~= 2 then
			return false, "plain grep wrong"
		end
		-- Plain: a magic-char pattern is literal (no matches for this literal).
		local none = ScriptEdit.grep(SRC, "%d", true)
		if none == nil or #none ~= 0 then
			return false, "plain grep treated pattern magically"
		end
		local patHits = ScriptEdit.grep(SRC, "%d", false)
		return patHits ~= nil and #patHits == 2
	end)

	add("grep: malformed pattern returns an error, never throws", function()
		local hits, err = ScriptEdit.grep(SRC, "%", false)
		return hits == nil and err ~= nil and string.find(err, "bad pattern", 1, true) ~= nil
	end)

	add("firstDiffLine: change / prefix / identical", function()
		if ScriptEdit.firstDiffLine(SRC, "local a = 1\nlocal b = 9\nprint(a + b)") ~= 2 then
			return false, "changed-line wrong"
		end
		if ScriptEdit.firstDiffLine(SRC, SRC .. "\n-- tail") ~= 4 then
			return false, "prefix case wrong"
		end
		return ScriptEdit.firstDiffLine(SRC, SRC) == 1
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== ScriptEditSpec: running " .. tostring(total) .. " cases ===")
	for _, case in ipairs(cases) do
		local ok, result, detail = pcall(case.fn)
		local pass = ok and result == true
		if pass then
			print("  PASS  " .. case.name)
		else
			failed += 1
			local why = if not ok then tostring(result) else tostring(detail)
			print("  FAIL  " .. case.name .. (if why ~= "nil" then " (" .. why .. ")" else ""))
		end
	end
	local passed = total - failed
	print(
		"=== Summary: "
			.. tostring(passed)
			.. "/"
			.. tostring(total)
			.. " passed, "
			.. tostring(failed)
			.. " failed ==="
	)
	return { passed = failed == 0, total = total, failed = failed }
end

return M
