--!strict
-- Session (M5a): the PERSISTENT REPL environment shared across every run_luau call.
--
-- run_luau chunks execute against ONE long-lived global table (Session.env) so that state set in
-- one call (locals promoted to globals, cached handles, helper functions) survives into the next.
-- The exposed Session.environment is what RunLuau setfenv's onto each compiled chunk: a thin table
-- whose __index resolves names against, in order, the persisted REPL globals, our print/warn
-- overrides, and finally the real script environment captured once at load.
--
-- DEPRECATION NOTE: this module is consumed via getfenv/setfenv in RunLuau. getfenv/setfenv are
-- deprecated and disable Luau script optimizations for the affected chunk. That is an ACCEPTED
-- trade-off here: a run_luau chunk is a one-shot, locally-installed plugin REPL eval, not hot code,
-- and a mutable shared environment is the entire point. We capture the real environment ONCE at
-- module load (NOT inline in the __index metamethod) so the metamethod stays a pure table lookup.

local Session = {}

-- The persistent REPL global store. Created ONCE at module load and NEVER recreated per call;
-- reset() clears it in place (table.clear) so the table identity — and any closures that captured
-- it via Session.environment's metatable — stays valid across resets.
Session.env = {} :: { [any]: any }

-- Re-entrancy guard. A yielding chunk holds the ChangeHistory recording open across the yield, so
-- RunLuau single-flights run() on this flag. Module-level: shared across all calls.
Session.busy = false

-- The REAL global environment of THIS module's thread, captured exactly once. getfenv(0) returns
-- the running thread's globals; we snapshot it here rather than calling getfenv inside __index
-- (which would run on every miss and defeats the "capture once" requirement).
local realEnv = getfenv(0)

-- A SINGLE ordered capture buffer of { stream, text } entries. One buffer (not two) preserves the
-- real chronological interleaving of print and warn within a single run.
type CaptureEntry = { stream: string, text: string }
local captureBuffer: { CaptureEntry } = {}

-- The real print/warn, captured at load so the shims can forward to them. Capturing them here (not
-- by name at call time) means a chunk that rebinds the global "print" cannot break forwarding, and
-- there is no recursion back through our own shims.
local realPrint = print
local realWarn = warn

-- tostring + tab-join a varargs list, matching how Roblox's own print renders multiple arguments.
local function joinArgs(...: any): string
	local n = select("#", ...)
	if n == 0 then
		return ""
	end
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, "\t")
end

-- Globals layered UNDER the persistent REPL store: our print/warn overrides live here so a chunk
-- sees captured I/O by default, while still being able to shadow them by assigning a new global
-- (which lands in Session.env and wins via the presence-ordered __index below).
local captureGlobals: { [any]: any } = {}

captureGlobals.print = function(...: any)
	table.insert(captureBuffer, { stream = "stdout", text = joinArgs(...) })
	realPrint(...)
end

captureGlobals.warn = function(...: any)
	table.insert(captureBuffer, { stream = "stderr", text = joinArgs(...) })
	realWarn(...)
end

-- The environment handed to each compiled chunk via setfenv. A fresh table (so chunk writes never
-- accidentally mutate realEnv) carrying a metatable that:
--   __index  : EXPLICIT presence checks, never `a or b` (so a persisted `false`/`0` REPL global
--               is returned, not shadowed by a falsy-fallthrough). Order: persisted REPL globals,
--               then our print/warn overrides, then the real script environment.
--   __newindex: every chunk-level global assignment is rawset into the persistent store, so it
--               survives into the next run_luau call.
-- FOOTGUN: a chunk that assigns the global `print` or `warn` persists that into Session.env, which
-- (being checked first) shadows our capture shims on EVERY subsequent run until Session.reset().
-- This is the intended consequence of "Session.env wins"; capture resumes after reset().
Session.environment = setmetatable({}, {
	__index = function(_, k: any): any
		if rawget(Session.env, k) ~= nil then
			return rawget(Session.env, k)
		end
		if captureGlobals[k] ~= nil then
			return captureGlobals[k]
		end
		return realEnv[k]
	end,
	__newindex = function(_, k: any, v: any)
		rawset(Session.env, k, v)
	end,
})

-- Start a fresh capture window. Clears the ordered buffer IN PLACE (preserving identity). Call once
-- immediately before invoking a chunk.
function Session.beginCapture()
	table.clear(captureBuffer)
end

-- Result of one capture window. stdout/stderr are the per-stream lines newline-joined; combined is
-- the full ordered interleaving (chronology across both streams) newline-joined.
export type Capture = {
	stdout: string,
	stderr: string,
	combined: string,
}

-- Drain the capture window: build {stdout, stderr, combined} from the ordered buffer, then reset.
-- Always resets, so a forgotten beginCapture cannot leak one run's output into the next.
function Session.takeCapture(): Capture
	local outLines: { string } = {}
	local errLines: { string } = {}
	local allLines: { string } = {}
	for _, entry in ipairs(captureBuffer) do
		if entry.stream == "stderr" then
			table.insert(errLines, entry.text)
		else
			table.insert(outLines, entry.text)
		end
		table.insert(allLines, entry.text)
	end
	table.clear(captureBuffer)
	return {
		stdout = table.concat(outLines, "\n"),
		stderr = table.concat(errLines, "\n"),
		combined = table.concat(allLines, "\n"),
	}
end

-- Wipe the persistent REPL store in place. The table identity is preserved (table.clear, not
-- reassignment) so Session.environment's metatable keeps pointing at the same store.
function Session.reset()
	table.clear(Session.env)
end

return Session
