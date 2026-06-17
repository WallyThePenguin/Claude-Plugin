--!strict
-- WebSpec: in-Studio self-test for the PURE web pieces (no network): the HTML->text stripper and the
-- DuckDuckGo result parser. Run via temporarily adding `require(script.WebSpec).run()` to
-- init.server.luau, build, reopen Studio, read Output.

local Web = require(script.Parent.Tools.Web)

local M = {}

type Case = { name: string, fn: () -> (boolean, string?) }

local SAMPLE_HTML = "<!doctype html><html><head><style>.x{color:red}</style>"
	.. "<script>alert(1)</script></head><body><h1>Title</h1>"
	.. "<p>Hello &amp; welcome to <b>Roblox</b> &lt;docs&gt;.</p></body></html>"

-- Mimics DuckDuckGo's html.duckduckgo.com result markup.
local SAMPLE_DDG = '<div class="result"><a rel="nofollow" class="result__a" '
	.. 'href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fcreate.roblox.com%2Fdocs%2Fproximityprompt&rut=z">'
	.. "ProximityPrompt | Documentation</a>"
	.. '<a class="result__snippet" href="x">The ProximityPrompt object prompts a player to interact.</a>'
	.. "</div>"

local function buildCases(): { Case }
	local cases: { Case } = {}
	local function add(name: string, fn: () -> (boolean, string?))
		table.insert(cases, { name = name, fn = fn })
	end

	add("stripHtml removes script/style content", function()
		local out = Web.stripHtml(SAMPLE_HTML)
		if string.find(out, "alert", 1, true) then
			return false, "script content leaked"
		end
		if string.find(out, "color:red", 1, true) then
			return false, "style content leaked"
		end
		return true
	end)

	add("stripHtml strips tags and decodes entities", function()
		local out = Web.stripHtml(SAMPLE_HTML)
		if not string.find(out, "Title", 1, true) then
			return false, "lost heading text"
		end
		if not string.find(out, "Hello & welcome to Roblox <docs>.", 1, true) then
			return false, "tags not stripped / entities not decoded: " .. out
		end
		if string.find(out, "<b>", 1, true) or string.find(out, "<p>", 1, true) then
			return false, "tags remain"
		end
		return true
	end)

	add("stripHtml passes through non-HTML (markdown) unchanged", function()
		local md = "# Heading\n\nSome **markdown** text with a list:\n- one\n- two\n"
		return Web.stripHtml(md) == md
	end)

	add("parseDdg extracts title, decoded url, and snippet", function()
		local r = Web.parseDdg(SAMPLE_DDG, 5)
		if #r ~= 1 then
			return false, "got " .. tostring(#r) .. " results"
		end
		if r[1].url ~= "https://create.roblox.com/docs/proximityprompt" then
			return false, "url not decoded: " .. tostring(r[1].url)
		end
		if r[1].title ~= "ProximityPrompt | Documentation" then
			return false, "title: " .. tostring(r[1].title)
		end
		if not string.find(r[1].snippet, "prompts a player to interact", 1, true) then
			return false, "snippet: " .. tostring(r[1].snippet)
		end
		return true
	end)

	add("parseDdg returns nothing on a non-result page (no throw)", function()
		local r = Web.parseDdg("<html><body>nothing here</body></html>", 5)
		return #r == 0
	end)

	add("parseDdg respects the maxResults cap", function()
		local two = SAMPLE_DDG .. SAMPLE_DDG .. SAMPLE_DDG
		local r = Web.parseDdg(two, 2)
		return #r == 2, "got " .. tostring(#r)
	end)

	return cases
end

function M.run(): { passed: boolean, total: number, failed: number }
	local cases = buildCases()
	local total = #cases
	local failed = 0
	print("=== WebSpec: running " .. tostring(total) .. " cases ===")
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
