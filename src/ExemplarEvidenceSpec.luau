--!strict
-- ExemplarEvidenceSpec: in-Studio self-test for the PURE ExemplarEvidence.buildExemplarBlocks (no
-- DataModel / HTTP). Run via temporarily adding `require(script.ExemplarEvidenceSpec).run()` to
-- init.server.luau, like GuiEvidenceSpec.

local ExemplarEvidence = require(script.Parent.ExemplarEvidence)

local M = {}
type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("empty/absent payload -> {}", function()
		return #ExemplarEvidence.buildExemplarBlocks(nil) == 0
			and #ExemplarEvidence.buildExemplarBlocks({}) == 0
			and #ExemplarEvidence.buildExemplarBlocks({ exemplars = {} }) == 0
	end)

	add("one exemplar -> a text label + an image block", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({
			exemplars = {
				{ caption = "crafted slope", tier = "exceptional", source = "own", image = "QUJD" },
			},
		})
		if #blocks ~= 2 then
			return false, "want 2 blocks, got " .. #blocks
		end
		if blocks[1].type ~= "text" then
			return false, "block1 not text"
		end
		if string.find(blocks[1].text, "exceptional", 1, true) == nil then
			return false, "tier missing: " .. blocks[1].text
		end
		if string.find(blocks[1].text, "crafted slope", 1, true) == nil then
			return false, "caption missing"
		end
		if blocks[2].type ~= "image" or blocks[2].source.data ~= "QUJD" then
			return false, "image block wrong"
		end
		return true
	end)

	add("entry without an image is skipped", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({
			exemplars = {
				{ caption = "no image", tier = "good" },
				{ caption = "ok", image = "QQ" },
			},
		})
		return #blocks == 2 and blocks[2].source.data == "QQ"
	end)

	add("missing tier defaults to 'reference'", function()
		local blocks = ExemplarEvidence.buildExemplarBlocks({ exemplars = { { image = "QQ" } } })
		return #blocks == 2 and string.find(blocks[1].text, "reference", 1, true) ~= nil
	end)

	return cases
end

function M.run(): boolean
	local cases = buildCases()
	local passed = 0
	for _, c in ipairs(cases) do
		local ok, err = c.fn()
		if ok then
			passed += 1
			print("[ExemplarEvidenceSpec] PASS " .. c.name)
		else
			warn("[ExemplarEvidenceSpec] FAIL " .. c.name .. (if err then " — " .. err else ""))
		end
	end
	print(("[ExemplarEvidenceSpec] %d/%d passed"):format(passed, #cases))
	return passed == #cases
end

return M
