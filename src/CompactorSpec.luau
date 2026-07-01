--!strict
-- CompactorSpec: in-Studio self-test for the PURE compaction logic (MessageUtil + Compactor). Run
-- via: temporarily add `require(script.CompactorSpec).run()` to init.server.luau, build, reopen
-- Studio, read Output. Cases use only plain tables/strings (no Roblox datatypes).

local MessageUtil = require(script.Parent.MessageUtil)
local Compactor = require(script.Parent.Compactor)

local M = {}

-- Build a synthetic VALID history of `pairsCount` tool exchanges after the opening user text turn:
--   user(text), [assistant(tool_use), user(tool_result)] * pairsCount
-- Always ends on a user(tool_result) turn (like the loop at a Send). withImageAt: list of exchange
-- indices (1-based) whose tool_result carries an image block.
local function buildHistory(pairsCount: number, withImageAt: { number }?): { any }
	local imageSet: { [number]: boolean } = {}
	for _, idx in ipairs(withImageAt or {}) do
		imageSet[idx] = true
	end
	local m: { any } = { { role = "user", content = "build a thing" } }
	for k = 1, pairsCount do
		table.insert(m, {
			role = "assistant",
			content = { { type = "tool_use", id = "t" .. k, name = "get_tree", input = {} } },
		})
		local resultContent: any
		if imageSet[k] then
			resultContent = {
				{
					type = "image",
					source = { type = "base64", media_type = "image/png", data = "AAAA" },
				},
			}
		else
			resultContent = "ok " .. k
		end
		table.insert(m, {
			role = "user",
			content = {
				{
					type = "tool_result",
					tool_use_id = "t" .. k,
					content = resultContent,
					is_error = false,
				},
			},
		})
	end
	return m
end

type Case = { name: string, fn: () -> (boolean, string?) }

local function countImages(messages: { any }): number
	return #Compactor.collectImageSlots(messages)
end

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("buildHistory is itself valid", function()
		local ok, reason = MessageUtil.isValidHistory(buildHistory(3))
		return ok, reason
	end)

	add("isValidHistory rejects starting on assistant", function()
		local bad = { { role = "assistant", content = "x" }, { role = "user", content = "y" } }
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("isValidHistory rejects non-alternating", function()
		local bad = { { role = "user", content = "a" }, { role = "user", content = "b" } }
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("isValidHistory rejects dangling tool_result", function()
		local bad = {
			{ role = "user", content = "a" },
			{ role = "assistant", content = "plain text, no tool_use" },
			{
				role = "user",
				content = { { type = "tool_result", tool_use_id = "z", content = "x" } },
			},
		}
		local ok = MessageUtil.isValidHistory(bad)
		return ok == false
	end)

	add("promptTokensFromUsage sums components", function()
		local got = MessageUtil.promptTokensFromUsage({
			input_tokens = 10,
			cache_read_input_tokens = 5,
			cache_creation_input_tokens = 2,
		})
		return got == 17, "got " .. tostring(got)
	end)

	add("promptTokensFromUsage tolerates missing fields", function()
		return MessageUtil.promptTokensFromUsage({ input_tokens = 4 }) == 4
			and MessageUtil.promptTokensFromUsage(nil) == 0
	end)

	add("pruneImagesKeepingLast keeps exactly the last image", function()
		local m = buildHistory(4, { 1, 2, 4 })
		local dropped = Compactor.pruneImagesKeepingLast(m)
		if dropped ~= 2 then
			return false, "dropped " .. tostring(dropped) .. " expected 2"
		end
		if countImages(m) ~= 1 then
			return false, "images left " .. tostring(countImages(m))
		end
		local ok, reason = MessageUtil.isValidHistory(m)
		return ok, reason
	end)

	add("pruneImagesKeepingLast is a no-op at 0 or 1 image", function()
		local m0 = buildHistory(3)
		local m1 = buildHistory(3, { 2 })
		return Compactor.pruneImagesKeepingLast(m0) == 0
			and Compactor.pruneImagesKeepingLast(m1) == 0
			and countImages(m1) == 1
	end)

	add("pruneImagesKeepingLast honors keep=K (before/after comparison)", function()
		local m = buildHistory(6, { 1, 2, 4, 6 })
		local dropped = Compactor.pruneImagesKeepingLast(m, 3)
		if dropped ~= 1 or countImages(m) ~= 3 then
			return false, "dropped " .. tostring(dropped) .. " left " .. tostring(countImages(m))
		end
		-- Idempotent at K, and a bad keep clamps to >= 1.
		if Compactor.pruneImagesKeepingLast(m, 3) ~= 0 then
			return false, "not idempotent at K"
		end
		local m2 = buildHistory(6, { 1, 2, 4 })
		if Compactor.pruneImagesKeepingLast(m2, 0) ~= 2 or countImages(m2) ~= 1 then
			return false, "keep=0 should clamp to 1"
		end
		local ok, reason = MessageUtil.isValidHistory(m)
		return ok, reason
	end)

	add("chooseBoundary lands on an assistant turn", function()
		local m = buildHistory(10) -- length 21, ends on user
		local j = Compactor.chooseBoundary(m, 6)
		return m[j] ~= nil and m[j].role == "assistant", "j=" .. tostring(j)
	end)

	add("compacted history is API-valid and starts with the summary", function()
		local m = buildHistory(10)
		local j = Compactor.chooseBoundary(m, 6)
		local rebuilt = Compactor.rebuildWithSummary(m, j, "[summary] goal: build a thing")
		if rebuilt[1].role ~= "user" or type(rebuilt[1].content) ~= "string" then
			return false, "first turn is not the user summary"
		end
		if rebuilt[#rebuilt].role ~= "user" then
			return false, "must end on a user turn"
		end
		local ok, reason = MessageUtil.isValidHistory(rebuilt)
		return ok, reason
	end)

	add("rebuild of a non-alternating tail is detected invalid (compact's guard)", function()
		-- Simulate an upstream pause_turn double-assistant in the kept region.
		local m = {
			{ role = "user", content = "go" },
			{ role = "assistant", content = { { type = "text", text = "A1" } } },
			{ role = "assistant", content = { { type = "text", text = "A2" } } },
			{
				role = "user",
				content = { { type = "tool_result", tool_use_id = "x", content = "r" } },
			},
		}
		local rebuilt = Compactor.rebuildWithSummary(m, 2, "[summary]")
		-- rebuilt = user(summary), A1, A2, user(tr) -> non-alternating -> must be rejected.
		return MessageUtil.isValidHistory(rebuilt) == false
	end)

	add("isContextLengthError matches a prompt-too-long 400", function()
		local hit = Compactor.isContextLengthError({
			kind = "http",
			status = 400,
			message = "prompt is too long: 1.2M tokens",
		})
		local miss = Compactor.isContextLengthError({
			kind = "http",
			status = 429,
			message = "overloaded",
		})
		return hit == true and miss == false
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== CompactorSpec: running " .. tostring(total) .. " cases ===")
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
