--!strict
-- RunLuau (M5b): the exec spine for the run_luau tool — compile a code string, run it against the
-- persistent Session REPL environment inside a ChangeHistory recording, and return a textual result.
--
-- This module is a Tools/ submodule, so its top-level siblings (Serialize, Session) are reached via
-- script.Parent.Parent (Tools/ -> StudioAgent root), per the built-tree require convention.
--
-- DEPRECATION NOTE: setfenv (used to bind the chunk to Session.environment) and the loadstring path
-- are deprecated / disable optimizations. Accepted: a run_luau chunk is one-shot REPL eval in a
-- locally-installed plugin, and a shared mutable environment is the whole point (see Session.luau).

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

local Serialize = require(script.Parent.Parent.Serialize)
local Session = require(script.Parent.Parent.Session)

local RunLuau = {}

export type Input = {
	code: string,
}

export type Output = {
	text: string,
	error: boolean,
}

-- compile(): the ABSTRACTION POINT / seam. Today it is loadstring; a future FiOne (pure-Luau)
-- interpreter would slot in here behind the same contract, so the rest of run() never changes.
--
-- Contract — returns exactly one of:
--   chunk : a callable function ready to setfenv + xpcall.
--   error : a human/Claude-facing message string (caller surfaces it as a non-ChangeHistory error).
-- The two return slots are mutually exclusive: (chunk, nil) on success, (nil, message) on failure.
--
-- Failure cases handled here:
--   * loadstring is nil (unavailable in this plugin context) -> a CLEAR, actionable message naming
--     the not-yet-vendored FiOne fallback. We do NOT vendor an interpreter in this pass.
--   * loadstring returns nil (a syntax/compile error) -> a "compile error: <err>" message. No
--     ChangeHistory recording is ever opened for code that cannot compile.
local function compile(code: string): (((...any) -> ...any)?, string?)
	-- loadstring may be entirely absent (not nil-returning, but the global itself missing) depending
	-- on the plugin's security context; treat that as the FiOne-not-yet-vendored case.
	if loadstring == nil then
		return nil,
			"loadstring unavailable in this plugin context (FiOne fallback not yet vendored)"
	end

	local chunk, compileErr = loadstring(code, "=run_luau")
	if chunk == nil then
		local msg = tostring(compileErr)
		if string.find(string.lower(msg), "disabled", 1, true) then
			-- loadstring is gated off at runtime (typically during a playtest).
			return nil,
				"run_luau needs loadstring, which is disabled here (usually during a playtest). Enable "
					.. "ServerScriptService.LoadStringEnabled (Game Settings > Security), or work in edit "
					.. "mode. The structured tools (get_tree/get_properties/set_property/search/get_output) "
					.. "need no loadstring and work during a playtest."
		end
		-- Syntax error: loadstring returns nil plus a message. Surface it verbatim, no recording.
		return nil, "compile error: " .. msg
	end

	return chunk :: (...any) -> ...any, nil
end

-- The actual run, factored out of run() so the public entry can wrap it in a pcall and guarantee
-- the busy single-flight flag is cleared even if anything in here throws unexpectedly.
local function execute(input: Input): Output
	local code = input.code

	-- 1. compile() seam.
	local chunk, compileErr = compile(code)
	if chunk == nil then
		return { text = compileErr :: string, error = true }
	end

	-- 2. Bind the chunk to the persistent REPL environment so its global reads/writes hit Session.
	setfenv(chunk, Session.environment)

	-- 3. Open the capture window BEFORE running so all print/warn during the chunk is recorded.
	Session.beginCapture()

	-- 4. In EDIT mode, wrap the run in an undoable ChangeHistory recording. nil means one is already
	--    open — historically we REFUSED, but the hot-reload host plugin never unloads, so ONE
	--    recording orphaned by an interrupted tool wedged every mutating tool until a Studio restart
	--    (observed live 2026-07-04). Availability beats undo purity for the automated pipeline: run
	--    UNRECORDED and say so in the result. During a playtest there is no edit history anyway.
	local rid: string? = nil
	local recWarn: string? = nil
	if RunService:IsEdit() then
		rid = ChangeHistoryService:TryBeginRecording("run_luau")
		if rid == nil then
			recWarn =
				"[no undo recording: a stale recording is stuck open; changes applied unrecorded]"
		end
	end

	-- 5. Run under xpcall with a traceback-capturing handler. level 2 makes debug.traceback walk from
	--    the handler's caller frame (the standard idiom); the error header (tostring(e)) plus all
	--    chunk frames are present in the returned text.
	local results = table.pack(xpcall(chunk, function(e)
		return debug.traceback(tostring(e), 2)
	end))
	local ok = results[1]

	-- 6. In edit mode, Commit on success / Cancel (auto-undo) on error. No recording during a playtest.
	if rid ~= nil then
		ChangeHistoryService:FinishRecording(
			rid,
			if ok
				then Enum.FinishRecordingOperation.Commit
				else Enum.FinishRecordingOperation.Cancel
		)
	end

	-- 7. Drain the captured I/O.
	local cap = Session.takeCapture()

	if not ok then
		-- Error: the traceback string is results[2]. Surface it verbatim, then append any stderr
		-- captured before the throw so warnings leading up to the error are not lost.
		local traceback = tostring(results[2])
		local text = traceback
		if cap.stderr ~= "" then
			text = text .. "\n" .. cap.stderr
		end
		return { text = text, error = true }
	end

	-- 8. Success: serialize the chunk's return values (results[2..results.n]) into JSON-safe form,
	--    bundled with the captured stdout/stderr, and JSON-encode the envelope into compact text.
	local returns: { any } = {}
	for i = 2, results.n do
		returns[i - 1] = results[i]
	end

	local payload = {
		returns = Serialize.encode(returns),
		stdout = cap.stdout,
		stderr = if recWarn ~= nil and recWarn ~= ""
			then (if cap.stderr ~= "" then recWarn .. "\n" .. cap.stderr else recWarn)
			else cap.stderr,
	}

	local okEncode, encoded = pcall(function()
		return game:GetService("HttpService"):JSONEncode(payload)
	end)
	if okEncode then
		return { text = encoded, error = false }
	end

	-- JSONEncode itself failed (should not happen — Serialize.encode emits JSON-safe values — but
	-- stay total): fall back to a readable, non-throwing textual summary.
	local fallback = "run_luau completed (result not JSON-encodable)"
	if cap.stdout ~= "" then
		fallback = fallback .. "\nstdout:\n" .. cap.stdout
	end
	if cap.stderr ~= "" then
		fallback = fallback .. "\nstderr:\n" .. cap.stderr
	end
	return { text = fallback, error = false }
end

-- Public entry. Defensive on two axes:
--   * Re-entrancy: Session.busy single-flights run(). A yielding chunk keeps the recording open
--     across the yield, so a second concurrent run() is refused outright.
--   * Totality: execute() runs under pcall so a thrown error (even from Serialize/encode) becomes a
--     safe {error=true} Output instead of propagating, and the busy flag is ALWAYS cleared
--     (pcall/finally pattern) so a throw can never wedge the tool permanently.
function RunLuau.run(input: Input): Output
	if Session.busy then
		return { text = "run_luau already running", error = true }
	end

	Session.busy = true
	local ok, result = pcall(execute, input)
	Session.busy = false

	if ok then
		return result :: Output
	end

	-- execute() threw before producing an Output. If a recording was left open by the throw, the
	-- next run()'s TryBeginRecording will return nil and refuse cleanly — we do not guess at rid
	-- ownership here. Return a safe textual fallback so the call never propagates an exception.
	return { text = "run_luau internal error: " .. tostring(result), error = true }
end

return RunLuau
