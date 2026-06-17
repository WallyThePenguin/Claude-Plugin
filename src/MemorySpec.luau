--!strict
-- MemorySpec: in-Studio self-test for the PURE Memory helpers (no DataModel, no SetSetting). Run via
-- temporarily adding `require(script.MemorySpec).run()` to init.server.luau, build, reopen Studio,
-- read Output.

local Memory = require(script.Parent.Memory)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalizeText trims and keeps a real string", function()
		return Memory.normalizeText("  hello  ") == "hello"
	end)

	add("normalizeText returns nil for empty / whitespace / non-string", function()
		return Memory.normalizeText("") == nil
			and Memory.normalizeText("   ") == nil
			and Memory.normalizeText(5) == nil
			and Memory.normalizeText(nil) == nil
			and Memory.normalizeText({}) == nil
	end)

	add("normalizeText truncates to MAX_TEXT codepoints (UTF-8 safe)", function()
		local long = string.rep("é", Memory.MAX_TEXT + 20)
		local out = Memory.normalizeText(long)
		return out ~= nil and utf8.len(out) == Memory.MAX_TEXT
	end)

	add("addTo appends with id = max+1, sets text + createdAt", function()
		local e1 = Memory.addTo({}, "first", 100)
		if #e1 ~= 1 or e1[1].id ~= 1 or e1[1].text ~= "first" or e1[1].createdAt ~= 100 then
			return false, "first add wrong"
		end
		local e2 = Memory.addTo(e1, "second", 200)
		return #e2 == 2 and e2[2].id == 2 and e2[2].text == "second"
	end)

	add("addTo rejects invalid text, leaving entries unchanged", function()
		local entries = Memory.addTo({}, "ok", 1)
		local after, note = Memory.addTo(entries, "   ", 2)
		return #after == 1 and string.find(note, "failed", 1, true) ~= nil
	end)

	add("addTo FIFO-drops the oldest past MAX_ENTRIES and reports it", function()
		local entries: { any } = {}
		for i = 1, Memory.MAX_ENTRIES do
			entries = Memory.addTo(entries, "t" .. i, i)
		end
		local after, note = Memory.addTo(entries, "overflow", 999)
		if #after ~= Memory.MAX_ENTRIES then
			return false, "kept " .. tostring(#after)
		end
		return after[1].id == 2
			and after[#after].text == "overflow"
			and string.find(note, "dropped", 1, true) ~= nil
	end)

	add("addTo ids keep climbing after a FIFO drop", function()
		local entries: { any } = {}
		for i = 1, Memory.MAX_ENTRIES + 1 do
			entries = Memory.addTo(entries, "t" .. i, i)
		end
		return entries[#entries].id == Memory.MAX_ENTRIES + 1
	end)

	add("forgetFrom removes by id (hit) and no-ops on a miss", function()
		local entries = Memory.addTo(Memory.addTo({}, "a", 1), "b", 2)
		local after, removed = Memory.forgetFrom(entries, 1)
		if not removed or #after ~= 1 or after[1].id ~= 2 then
			return false, "hit failed"
		end
		local after2, removed2 = Memory.forgetFrom(after, 99)
		return removed2 == false and #after2 == 1
	end)

	add("forgetFrom coerces a string id", function()
		local entries = Memory.addTo({}, "a", 1)
		local after, removed = Memory.forgetFrom(entries, "1")
		return removed == true and #after == 0
	end)

	add("renderBucket formats '#id text' and handles empty", function()
		if Memory.renderBucket({}) ~= "(none)" then
			return false, "empty render"
		end
		local entries = Memory.addTo(Memory.addTo({}, "alpha", 1), "beta", 2)
		local txt = Memory.renderBucket(entries)
		return string.find(txt, "#1 alpha", 1, true) ~= nil
			and string.find(txt, "#2 beta", 1, true) ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== MemorySpec: running " .. tostring(total) .. " cases ===")
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
