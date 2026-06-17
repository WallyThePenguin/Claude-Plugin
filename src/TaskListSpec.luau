--!strict
-- TaskListSpec: in-Studio self-test for the PURE TaskList surface (no DataModel, no network). Run via
-- temporarily adding `require(script.TaskListSpec).run()` to init.server.luau, build, reopen Studio,
-- read Output.

local TaskList = require(script.Parent.TaskList)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("normalize parses {tasks=[...]} keeping valid statuses + order", function()
		local out = TaskList.normalize({
			tasks = {
				{ content = "a", status = "completed" },
				{ content = "b", status = "in_progress" },
				{ content = "c", status = "pending" },
			},
		})
		if #out ~= 3 then
			return false, "got " .. tostring(#out)
		end
		return out[1].status == "completed"
			and out[2].status == "in_progress"
			and out[3].content == "c"
	end)

	add("normalize coerces missing/unknown status to pending", function()
		local out = TaskList.normalize({
			tasks = { { content = "a" }, { content = "b", status = "bogus" } },
		})
		return out[1].status == "pending" and out[2].status == "pending"
	end)

	add("normalize drops empty / whitespace-only content", function()
		local out = TaskList.normalize({
			tasks = { { content = "  " }, { content = "" }, { content = "real" } },
		})
		return #out == 1 and out[1].content == "real"
	end)

	add("normalize drops non-table items", function()
		local out = TaskList.normalize({ tasks = { "nope", 5, { content = "ok" } } })
		return #out == 1 and out[1].content == "ok"
	end)

	add("normalize drops items with missing / non-string content (no junk coercion)", function()
		local out = TaskList.normalize({
			tasks = {
				{ status = "pending" }, -- missing content (must NOT become "nil")
				{ content = 5, status = "pending" }, -- numeric content (must NOT become "5")
				{ content = {}, status = "pending" }, -- table content (must NOT become "table: ...")
				{ content = "ok", status = "pending" },
			},
		})
		return #out == 1 and out[1].content == "ok"
	end)

	add("normalize truncates content to MAX_CONTENT codepoints", function()
		local long = string.rep("x", TaskList.MAX_CONTENT + 50)
		local out = TaskList.normalize({ tasks = { { content = long, status = "pending" } } })
		return #out == 1 and #out[1].content == TaskList.MAX_CONTENT
	end)

	add("normalize caps at MAX_TASKS and reports dropped", function()
		local items = {}
		for i = 1, TaskList.MAX_TASKS + 5 do
			items[i] = { content = "t" .. i, status = "pending" }
		end
		local out, summary = TaskList.normalize({ tasks = items })
		if #out ~= TaskList.MAX_TASKS then
			return false, "kept " .. tostring(#out)
		end
		return string.find(summary, "dropped", 1, true) ~= nil
	end)

	add("normalize cap-dropped counts only valid tasks, not junk past the cap", function()
		local items = {}
		for i = 1, TaskList.MAX_TASKS do
			items[i] = { content = "t" .. i, status = "pending" }
		end
		-- Junk past the cap must NOT be reported as a cap-drop.
		table.insert(items, "junk")
		table.insert(items, { content = "" })
		local out, summary = TaskList.normalize({ tasks = items })
		return #out == TaskList.MAX_TASKS and string.find(summary, "dropped", 1, true) == nil
	end)

	add("normalize truncate counts UTF-8 codepoints, not bytes", function()
		local long = string.rep("é", TaskList.MAX_CONTENT + 10) -- 2 bytes per codepoint
		local out = TaskList.normalize({ tasks = { { content = long, status = "pending" } } })
		if #out ~= 1 then
			return false, "got " .. tostring(#out)
		end
		-- Exactly MAX_CONTENT codepoints kept, on a valid UTF-8 boundary.
		return utf8.len(out[1].content) == TaskList.MAX_CONTENT
	end)

	add("normalize tolerates a bare array", function()
		local out = TaskList.normalize({ { content = "a", status = "pending" } })
		return #out == 1 and out[1].content == "a"
	end)

	add("normalize on non-table input returns empty (no throw)", function()
		local out = TaskList.normalize("garbage")
		return #out == 0
	end)

	add("counts computes done / in_progress / pending", function()
		local c = TaskList.counts({
			{ content = "a", status = "completed" },
			{ content = "b", status = "completed" },
			{ content = "c", status = "in_progress" },
			{ content = "d", status = "pending" },
		})
		return c.total == 4 and c.completed == 2 and c.inProgress == 1 and c.pending == 1
	end)

	add("set replaces in place + snapshot is isolated", function()
		local tl = TaskList.new()
		tl:set({ tasks = { { content = "a", status = "pending" } } })
		local snap = tl:snapshot()
		snap[1].status = "completed" -- mutate the snapshot
		-- The snapshot mutation must not leak into the live list, and a later set() must not be
		-- visible in the OLD snapshot.
		if tl:snapshot()[1].status ~= "pending" then
			return false, "snapshot mutation leaked into the live list"
		end
		tl:set({ tasks = {} })
		return #snap == 1 and #tl:snapshot() == 0
	end)

	add("clear empties the list", function()
		local tl = TaskList.new()
		tl:set({ tasks = { { content = "a", status = "pending" } } })
		tl:clear()
		return #tl:snapshot() == 0
	end)

	add("load re-normalizes a persisted array (defensive)", function()
		local tl = TaskList.new()
		tl:load({ { content = "good", status = "weird" }, { content = "" }, "junk" })
		local snap = tl:snapshot()
		return #snap == 1 and snap[1].content == "good" and snap[1].status == "pending"
	end)

	add("render formats a numbered, tagged list and handles empty", function()
		if TaskList.render({}) ~= "(no tasks)" then
			return false, "empty render"
		end
		local txt = TaskList.render({
			{ content = "build", status = "in_progress" },
			{ content = "wire", status = "pending" },
		})
		return string.find(txt, "1. [in_progress] build", 1, true) ~= nil
			and string.find(txt, "2. [pending] wire", 1, true) ~= nil
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== TaskListSpec: running " .. tostring(total) .. " cases ===")
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
