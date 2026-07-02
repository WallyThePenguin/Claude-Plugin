--!strict
-- StoreClientSpec: the pure surface (slug). The HTTP half is total-by-construction and live-verified.

local StoreClient = require(script.Parent.StoreClient)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("slug: lowercase + separators collapse to dashes", function()
		return StoreClient.slug("My Cool Skill!  v2") == "my-cool-skill-v2"
	end)

	add("slug: leading/trailing junk trimmed", function()
		return StoreClient.slug("--Shop GUI--") == "shop-gui" and StoreClient.slug("  a  ") == "a"
	end)

	add("slug: nothing left / non-string -> nil", function()
		return StoreClient.slug("!!!") == nil
			and StoreClient.slug("") == nil
			and StoreClient.slug(42) == nil
	end)

	add("slug: capped at 64", function()
		local long = string.rep("ab", 100)
		local s = StoreClient.slug(long)
		return s ~= nil and #(s :: string) == 64
	end)

	add("slug: already-clean ids pass through", function()
		return StoreClient.slug("locomotion") == "locomotion"
			and StoreClient.slug("wave-3") == "wave-3"
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== StoreClientSpec: running " .. tostring(total) .. " cases ===")
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
