--!strict
-- Scripts: script-native hands — list_scripts / get_script / grep_source / edit_script.
--
-- WHY: the agent's strongest skill is targeted edits over READABLE source, but until these tools
-- game code was write-only .Source strings (not even in the PropertyCatalog). These four give the
-- read/search/patch loop: read line-numbered source, grep the whole place, edit by unique
-- find/replace or line-range splice, with a loadstring COMPILE CHECK gating every write (a syntax
-- error is rejected and never applied; during a playtest, where loadstring is disabled, the write
-- degrades to apply-without-check and says so).
--
-- IO goes through ScriptEditorService: GetEditorSource sees open-editor drafts, and
-- UpdateSourceAsync works past the ~200K direct-.Source cap (same mechanism HotReload uses).
-- Edits are wrapped in an undoable ChangeHistory recording like every other mutating tool.
--
-- This is a Tools/ submodule: Path via script.Parent.Path, ScriptEdit via script.Parent.Parent.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local Path = require(script.Parent.Path)
local ScriptEdit = require(script.Parent.Parent.ScriptEdit)

local Scripts = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

-- Where list_scripts/grep_source look when no root is given: every container that can hold code
-- that matters to a game. (Lighting/SoundService rarely hold scripts but are cheap to include.)
local DEFAULT_CONTAINERS = {
	"Workspace",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Lighting",
	"SoundService",
}

local DEFAULT_LIST_LIMIT = 200
local DEFAULT_GREP_MAX = 50
local GREP_SNIPPET_MAX = 180
local EDIT_VIEW_RADIUS = 8

local function encodeResult(payload: { [string]: any }): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded
	end
	return '{"ok":false,"error":"result not JSON-encodable"}'
end

local function numberOr(value: any, fallback: number): number
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local parsed = tonumber(value)
		if parsed ~= nil then
			return parsed
		end
	end
	return fallback
end

local function pathOf(inst: Instance): string
	return "game." .. inst:GetFullName()
end

-- Read a script's source through the editor (sees unsaved editor drafts). Total.
local function readSource(container: LuaSourceContainer): (string?, string?)
	local ok, sourceOrErr = pcall(function(): string
		return ScriptEditorService:GetEditorSource(container)
	end)
	if ok then
		return sourceOrErr, nil
	end
	return nil, tostring(sourceOrErr)
end

-- Resolve `path` to a LuaSourceContainer or explain why not. Total.
local function resolveScript(pathArg: any): (LuaSourceContainer?, string?)
	if type(pathArg) ~= "string" or pathArg == "" then
		return nil, "path (string) is required"
	end
	local inst, err = Path.resolve(pathArg)
	if inst == nil then
		return nil, err
	end
	if not inst:IsA("LuaSourceContainer") then
		return nil,
			pathArg
				.. " is a "
				.. inst.ClassName
				.. ", not a Script/LocalScript/ModuleScript — use get_properties for instances"
	end
	return inst :: LuaSourceContainer, nil
end

-- Enumerate every LuaSourceContainer under `roots` (roots themselves included when they are one).
local function collectScripts(roots: { Instance }): { LuaSourceContainer }
	local out: { LuaSourceContainer } = {}
	local seen: { [Instance]: boolean } = {}
	local function take(inst: Instance)
		if not seen[inst] and inst:IsA("LuaSourceContainer") then
			seen[inst] = true
			table.insert(out, inst :: LuaSourceContainer)
		end
	end
	for _, root in roots do
		take(root)
		for _, desc in root:GetDescendants() do
			take(desc)
		end
	end
	return out
end

-- The roots to scan: an explicit root path, or the default containers.
local function resolveRoots(rootArg: any): ({ Instance }?, string?)
	if type(rootArg) == "string" and rootArg ~= "" then
		local inst, err = Path.resolve(rootArg)
		if inst == nil then
			return nil, err
		end
		return { inst }, nil
	end
	local roots: { Instance } = {}
	for _, name in DEFAULT_CONTAINERS do
		local ok, service = pcall(function(): Instance
			return game:GetService(name)
		end)
		if ok and service ~= nil then
			table.insert(roots, service)
		end
	end
	return roots, nil
end

-- Compile-check a source with loadstring WITHOUT executing it.
--   ("ok", nil)      -> compiles
--   ("syntax", err)  -> does not compile (err has the line)
--   ("skipped", why) -> loadstring unavailable here (playtest) — caller applies unchecked
local function compileCheck(source: string): (string, string?)
	if loadstring == nil then
		return "skipped", "loadstring unavailable in this context"
	end
	local okCall, chunk, compileErr = pcall(function()
		return loadstring(source, "=edit_script")
	end)
	if not okCall then
		return "skipped", tostring(chunk)
	end
	if chunk == nil then
		local msg = tostring(compileErr)
		if string.find(string.lower(msg), "disabled", 1, true) then
			return "skipped", "loadstring disabled (playtest)"
		end
		return "syntax", msg
	end
	return "ok", nil
end

-- ---- list_scripts ----

local function runListScripts(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local roots, err = resolveRoots(args.root)
	if roots == nil then
		return encodeResult({ ok = false, error = err }), true
	end
	local limit = math.max(1, math.floor(numberOr(args.limit, DEFAULT_LIST_LIMIT)))
	local all = collectScripts(roots)
	local entries: { any } = {}
	for i, container in all do
		if i > limit then
			break
		end
		local source = readSource(container)
		local lines = if source ~= nil then #ScriptEdit.splitLines(source) else -1
		local entry: { [string]: any } = {
			path = pathOf(container),
			class = container.ClassName,
			lines = lines,
			chars = if source ~= nil then #source else -1,
		}
		if container:IsA("BaseScript") then
			entry.enabled = container.Enabled
		end
		if container:IsA("Script") then
			entry.runContext = container.RunContext.Name
		end
		table.insert(entries, entry)
	end
	return encodeResult({
		ok = true,
		count = #all,
		returned = #entries,
		truncated = #all > #entries,
		scripts = entries,
	}), false
end

-- ---- get_script ----

local function runGetScript(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local container, err = resolveScript(args.path)
	if container == nil then
		return "get_script: " .. tostring(err), true
	end
	local source, readErr = readSource(container)
	if source == nil then
		return "get_script: could not read source: " .. tostring(readErr), true
	end
	local startLine = if args.startLine ~= nil then numberOr(args.startLine, 1) else nil
	local endLine = if args.endLine ~= nil then numberOr(args.endLine, 0) else nil
	local numbered, window = ScriptEdit.numberLines(source, startLine, endLine)
	local header = pathOf(container)
		.. " ("
		.. container.ClassName
		.. ", "
		.. tostring(window.total)
		.. " lines"
	if window.total > 0 then
		header = header
			.. "; showing "
			.. tostring(window.startLine)
			.. "-"
			.. tostring(window.endLine)
	end
	header = header
		.. (if window.truncated then "; pass startLine/endLine for the rest" else "")
		.. ")"
	if window.total == 0 then
		return header .. "\n(empty source)", false
	end
	return header .. "\n" .. numbered, false
end

-- ---- grep_source ----

local function runGrepSource(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local pattern = args.pattern
	if type(pattern) ~= "string" or pattern == "" then
		return "grep_source: pattern (non-empty string) is required", true
	end
	local plain = args.plain ~= false -- literal by default; pass plain=false for Lua patterns
	-- Validate the pattern ONCE up front so a malformed Lua pattern errors cleanly, not per-script.
	local okPattern, patternErr = pcall(string.find, "", pattern, 1, plain)
	if not okPattern then
		return "grep_source: bad pattern: " .. tostring(patternErr), true
	end
	local roots, err = resolveRoots(args.root)
	if roots == nil then
		return "grep_source: " .. tostring(err), true
	end
	local maxResults = math.max(1, math.floor(numberOr(args.maxResults, DEFAULT_GREP_MAX)))
	local out: { string } = {}
	local scanned = 0
	local truncated = false
	for _, container in collectScripts(roots) do
		local source = readSource(container)
		if source == nil then
			continue
		end
		scanned += 1
		local hits = ScriptEdit.grep(source, pattern, plain)
		if hits == nil then
			continue
		end
		for _, hit in hits do
			if #out >= maxResults then
				truncated = true
				break
			end
			local text = hit.text
			if #text > GREP_SNIPPET_MAX then
				text = string.sub(text, 1, GREP_SNIPPET_MAX) .. "…"
			end
			table.insert(out, pathOf(container) .. ":" .. tostring(hit.line) .. ": " .. text)
		end
		if truncated then
			break
		end
	end
	if #out == 0 then
		return "grep_source: no matches in " .. tostring(scanned) .. " script(s)", false
	end
	local header = tostring(#out)
		.. " match(es)"
		.. (if truncated then " (capped at " .. tostring(maxResults) .. " — narrow the pattern or pass maxResults)" else "")
	return header .. "\n" .. table.concat(out, "\n"), false
end

-- ---- edit_script ----

local function runEditScript(input: any): (string, boolean)
	local args = if type(input) == "table" then input else {}
	local container, err = resolveScript(args.path)
	if container == nil then
		return "edit_script: " .. tostring(err), true
	end
	local old, readErr = readSource(container)
	if old == nil then
		return "edit_script: could not read source: " .. tostring(readErr), true
	end

	-- Exactly one edit mode: whole-source | find/replace | line-range.
	local new: string?
	local modeErr: string?
	local summary: string
	if type(args.source) == "string" then
		new = args.source
		summary = "whole-source write"
	elseif type(args.find) == "string" then
		if type(args.replace) ~= "string" then
			return "edit_script: find mode needs replace (string; may be empty)", true
		end
		local count: number?
		new, modeErr, count = ScriptEdit.applyFind(old, args.find, args.replace, args.all == true)
		summary = "find/replace ×" .. tostring(count or 0)
	elseif args.startLine ~= nil then
		if type(args.replace) ~= "string" then
			return "edit_script: range mode needs replace (string; \"\" deletes the range)", true
		end
		local s = numberOr(args.startLine, 0)
		local e = numberOr(args.endLine, s)
		new, modeErr = ScriptEdit.applyRange(old, s, e, args.replace)
		summary = "lines " .. tostring(s) .. "-" .. tostring(e)
	else
		return "edit_script: pass one mode — find+replace (unique-match), startLine(+endLine)+replace (range), or source (whole file)",
			true
	end
	if new == nil then
		return "edit_script: " .. tostring(modeErr), true
	end
	if new == old then
		return "edit_script: no change (result equals the current source)", false
	end

	-- Compile gate: refuse to apply a source that cannot compile.
	local verdict, detail = compileCheck(new)
	if verdict == "syntax" then
		return "edit_script: SYNTAX ERROR — edit NOT applied: " .. tostring(detail), true
	end

	local rid = ChangeHistoryService:TryBeginRecording("edit_script " .. container.Name)
	-- rid == nil (stuck recording): proceed UNRECORDED rather than wedge the pipeline.
	local okWrite, writeErr = pcall(function()
		ScriptEditorService:UpdateSourceAsync(container, function(_old: string): string
			return new :: string
		end)
	end)
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if okWrite
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not okWrite then
		return "edit_script: write failed: " .. tostring(writeErr), true
	end

	local diffLine = ScriptEdit.firstDiffLine(old, new)
	local numbered, window = ScriptEdit.numberLines(
		new,
		math.max(1, diffLine - EDIT_VIEW_RADIUS),
		diffLine + EDIT_VIEW_RADIUS
	)
	local note = if verdict == "skipped"
		then " [compile check skipped: " .. tostring(detail) .. "]"
		else " — compile check OK"
	return "edited "
		.. pathOf(container)
		.. " ("
		.. summary
		.. ")"
		.. note
		.. ". Lines "
		.. tostring(window.startLine)
		.. "-"
		.. tostring(window.endLine)
		.. " of "
		.. tostring(window.total)
		.. " now:\n"
		.. numbered, false
end

Scripts.descriptors = {
	{
		name = "list_scripts",
		description = "List every Script/LocalScript/ModuleScript under `root` (default: all game "
			.. "containers) with path, class, line/char counts, Enabled, and RunContext. Use it to map "
			.. "the code in a place before reading or editing.",
		inputSchema = {
			type = "object",
			properties = {
				root = {
					type = "string",
					description = "Path to scan under (e.g. game.ServerScriptService). Omit for all containers.",
				},
				limit = { type = "number", description = "Max entries returned (default 200)." },
			},
		},
		destructive = false,
		run = runListScripts,
	},
	{
		name = "get_script",
		description = "Read a script's source, line-numbered (sees open-editor drafts). Defaults to "
			.. "the first 200 lines; pass startLine/endLine to window. ALWAYS read before editing.",
		inputSchema = {
			type = "object",
			properties = {
				path = { type = "string", description = "Path to the Script/LocalScript/ModuleScript." },
				startLine = { type = "number", description = "First line to show (1-based)." },
				endLine = { type = "number", description = "Last line to show (inclusive)." },
			},
			required = { "path" },
		},
		destructive = false,
		run = runGetScript,
	},
	{
		name = "grep_source",
		description = "Search EVERY script's source under `root` (default: all game containers) and "
			.. "return path:line: snippet matches. `pattern` is literal text by default; pass "
			.. "plain=false for Lua patterns. Use it to find where things are defined/used instead of "
			.. "guessing.",
		inputSchema = {
			type = "object",
			properties = {
				pattern = { type = "string", description = "Text (default) or Lua pattern to find." },
				root = { type = "string", description = "Path to scan under. Omit for all containers." },
				plain = {
					type = "boolean",
					description = "true (default) = literal text; false = Lua pattern matching.",
				},
				maxResults = { type = "number", description = "Cap on matches returned (default 50)." },
			},
			required = { "pattern" },
		},
		destructive = false,
		run = runGrepSource,
	},
	{
		name = "edit_script",
		description = "PATCH a script's source. Modes (pass exactly one): find+replace — replace a "
			.. "UNIQUE literal snippet (pass all=true to replace every occurrence); startLine(+endLine)"
			.. "+replace — splice a line range (\"\" deletes; endLine=startLine-1 inserts before "
			.. "startLine); source — replace the whole file. The result is COMPILE-CHECKED with "
			.. "loadstring first: a syntax error is rejected and NOT applied. Prefer small find/replace "
			.. "edits over whole-source rewrites; get_script first so the find text matches exactly.",
		inputSchema = {
			type = "object",
			properties = {
				path = { type = "string", description = "Path to the Script/LocalScript/ModuleScript." },
				find = { type = "string", description = "Literal text to replace (must match uniquely unless all=true)." },
				replace = { type = "string", description = "Replacement text (find/range modes)." },
				all = { type = "boolean", description = "find mode: replace ALL occurrences (default false)." },
				startLine = { type = "number", description = "Range mode: first line (1-based)." },
				endLine = { type = "number", description = "Range mode: last line (inclusive; default startLine)." },
				source = { type = "string", description = "Whole-file mode: the complete new source." },
			},
			required = { "path" },
		},
		destructive = true,
		run = runEditScript,
	},
}

return Scripts
