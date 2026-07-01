--!strict
-- ScriptEdit: the PURE engine for the script tools (get_script / edit_script / grep_source) —
-- line splitting/windowing, uniqueness-guarded plain find/replace, line-range splicing, per-source
-- grep, and first-diff location. No Instances, no services: strings in, strings/tables out, so the
-- whole surface is unit-testable (ScriptEditSpec). The impure half (path resolution, the
-- ScriptEditorService reads/writes, the loadstring compile check, the ChangeHistory recording)
-- lives in Tools/Scripts.luau.

local ScriptEdit = {}

-- How many lines get_script shows when the caller gives no window.
ScriptEdit.DEFAULT_WINDOW = 200

export type Window = {
	total: number,
	startLine: number,
	endLine: number,
	truncated: boolean,
}

export type GrepHit = { line: number, text: string }

-- Split source into lines on "\n", tolerating "\r\n" (the "\r" is stripped so numbering and
-- reassembly are stable). A trailing "\n" does NOT produce a phantom empty last line; "" -> {}.
function ScriptEdit.splitLines(source: string): { string }
	local lines: { string } = {}
	local start = 1
	local n = #source
	while start <= n do
		local nl = string.find(source, "\n", start, true)
		local line: string
		if nl == nil then
			line = string.sub(source, start)
			start = n + 1
		else
			line = string.sub(source, start, nl - 1)
			start = nl + 1
		end
		if string.sub(line, -1) == "\r" then
			line = string.sub(line, 1, -2)
		end
		table.insert(lines, line)
	end
	return lines
end

-- Render a 1-based [startLine, endLine] window of the source with "  N| " prefixes. Bounds are
-- clamped into range; endLine defaults to startLine + DEFAULT_WINDOW - 1. Returns the numbered
-- text plus the effective window (truncated = lines exist past endLine).
function ScriptEdit.numberLines(source: string, startLine: number?, endLine: number?): (string, Window)
	local lines = ScriptEdit.splitLines(source)
	local total = #lines
	if total == 0 then
		return "", { total = 0, startLine = 0, endLine = 0, truncated = false }
	end
	local s = math.clamp(math.floor(startLine or 1), 1, total)
	local e = math.clamp(math.floor(endLine or (s + ScriptEdit.DEFAULT_WINDOW - 1)), s, total)
	local out: { string } = {}
	for i = s, e do
		table.insert(out, string.format("%4d| %s", i, lines[i]))
	end
	return table.concat(out, "\n"), { total = total, startLine = s, endLine = e, truncated = e < total }
end

-- Count non-overlapping PLAIN (no Lua patterns) occurrences of `find` in `source`.
function ScriptEdit.countOccurrences(source: string, find: string): number
	if find == "" then
		return 0
	end
	local count = 0
	local init = 1
	while true do
		local s, e = string.find(source, find, init, true)
		if s == nil then
			break
		end
		count += 1
		init = (e :: number) + 1
	end
	return count
end

-- Plain-text find/replace. `find` and `replace` are both LITERAL (no Lua-pattern or %-capture
-- semantics on either side). Exactly one match is required unless `all` — the uniqueness guard
-- that keeps a small anchor from silently editing the wrong site.
--   success -> (newSource, nil, replacedCount)
--   failure -> (nil, errMessage, nil)
function ScriptEdit.applyFind(
	source: string,
	find: string,
	replace: string,
	all: boolean?
): (string?, string?, number?)
	if find == "" then
		return nil, "find must be a non-empty string", nil
	end
	if find == replace then
		return nil, "find and replace are identical — nothing to change", nil
	end
	local count = ScriptEdit.countOccurrences(source, find)
	if count == 0 then
		return nil,
			"no match for the find text — get_script the current source first (it may differ from what you remember)",
			nil
	end
	if count > 1 and all ~= true then
		return nil,
			tostring(count)
				.. " matches for the find text — include more surrounding lines to make it unique, or pass all=true to replace every occurrence",
			nil
	end
	local parts: { string } = {}
	local init = 1
	while true do
		local s, e = string.find(source, find, init, true)
		if s == nil then
			table.insert(parts, string.sub(source, init))
			break
		end
		table.insert(parts, string.sub(source, init, s - 1))
		init = (e :: number) + 1
	end
	return table.concat(parts, replace), nil, count
end

-- Replace lines [startLine, endLine] (1-based, inclusive) with `replacement` (may be multiline;
-- "" deletes the range). endLine = startLine - 1 INSERTS before startLine without replacing
-- anything (so startLine = total + 1, endLine = total appends at the end).
--   success -> (newSource, nil) ; failure -> (nil, errMessage)
function ScriptEdit.applyRange(
	source: string,
	startLine: number,
	endLine: number,
	replacement: string
): (string?, string?)
	local lines = ScriptEdit.splitLines(source)
	local total = #lines
	local s = math.floor(startLine)
	local e = math.floor(endLine)
	if s < 1 or s > total + 1 then
		return nil, "startLine " .. tostring(s) .. " out of range (1.." .. tostring(total + 1) .. ")"
	end
	if e < s - 1 or e > total then
		return nil,
			"endLine "
				.. tostring(e)
				.. " out of range ("
				.. tostring(s - 1)
				.. ".."
				.. tostring(total)
				.. "); endLine = startLine-1 inserts before startLine"
	end
	local out: { string } = {}
	for i = 1, s - 1 do
		table.insert(out, lines[i])
	end
	if replacement ~= "" then
		for _, l in ScriptEdit.splitLines(replacement) do
			table.insert(out, l)
		end
	end
	for i = e + 1, total do
		table.insert(out, lines[i])
	end
	return table.concat(out, "\n"), nil
end

-- Per-source grep. plain=true (the default posture) treats `pattern` literally; plain=false
-- enables Lua patterns (a malformed pattern returns an error instead of throwing).
--   success -> (hits, nil) ; failure -> (nil, errMessage)
function ScriptEdit.grep(source: string, pattern: string, plain: boolean): ({ GrepHit }?, string?)
	if pattern == "" then
		return nil, "pattern must be non-empty"
	end
	local lines = ScriptEdit.splitLines(source)
	local hits: { GrepHit } = {}
	for i, line in lines do
		local ok, found = pcall(string.find, line, pattern, 1, plain)
		if not ok then
			return nil, "bad pattern: " .. tostring(found)
		end
		if found ~= nil then
			table.insert(hits, { line = i, text = line })
		end
	end
	return hits, nil
end

-- 1-based line number of the first differing line between two sources (used to window an edit's
-- result view). If one is a line-prefix of the other, the first extra line; identical -> 1.
function ScriptEdit.firstDiffLine(old: string, new: string): number
	local a = ScriptEdit.splitLines(old)
	local b = ScriptEdit.splitLines(new)
	local n = math.min(#a, #b)
	for i = 1, n do
		if a[i] ~= b[i] then
			return i
		end
	end
	if #a ~= #b then
		return n + 1
	end
	return 1
end

return ScriptEdit
