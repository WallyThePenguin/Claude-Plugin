# Self-improving factory — design

**Date:** 2026-07-04 · **Status:** approved by user ("full autonomy no restrictions but it
should have auto revert incase you need to step in")

## Why (charter change)

The factory learned WHAT makes content good (per-category quality learnings) but not HOW to
work better, and every tooling defect (grip weld missing, stuck ChangeHistory recording,
zombie playtests) needed a human session to diagnose and patch. The user's directive: the
factory's goal now includes SELF-IMPROVEMENT — learn better methods AND edit its own tools —
and testing must be EDIT-MODE FIRST ("check ~9 times how to test in edit mode before falling
back to play mode").

This supersedes the propose-only charter clause for tooling: the mechanic MAY edit any code
(no protected paths, per user), balanced entirely by revertibility:
- every mechanic change is a separate `[mechanic]`-tagged git commit;
- a fix that cannot PROVE itself (live before/after repro) is auto-reverted immediately;
- a regression in the next same-family cycle auto-reverts the last mechanic commit;
- the human can step in with `git revert` at any time.

## Components

### 0. Recording fallback (enabler)
`TryBeginRecording` returning nil currently makes every mutating tool REFUSE — and since the
hot-reload host plugin never unloads, one orphaned recording wedges the whole pipeline until
Studio restarts. New shared `src/Tools/Recording.luau`: begin() returns (rid?, warn?) — when
nil, tools RUN UNRECORDED and prepend a "(no undo recording — a stale recording is stuck)"
warning instead of refusing. Availability of the automated pipeline beats undo purity.

### 1. RETRO stage — method learning (every cycle)
After each factory cycle, forever runs a short reflection loop over the cycle's result +
transcript tail. Output line `FACTORY_RETRO_JSON: {"methodLessons": ["..."],
"toolingIssues": [{"title": "...", "symptom": "...", "suspectFiles": ["src/..."],
"repro": "..."}]}`.
- methodLessons append to the existing learnings store, bucket `factory-methods`
  (same schema as weapons.json etc.), deduped by exact text, capped.
- BUILD/VERIFY prompts inject the newest K=8 `factory-methods` lessons plus the newest K=6
  lessons of the family's quality bucket (weapons/npc/environment/gui) as a
  "LEARNED METHODS (apply first)" block.

### 2. MECHANIC stage — autonomous tool edits (on tooling defects)
Trigger: retro reports toolingIssues, or the factory run ends BLOCKED with a tool-shaped
reason. The mechanic is a loop run with EXTRA LOCAL TOOLS dispatched sidecar-side (not over
the bridge): read_source / edit_source (repo files), reload_plugin (POST /reload wait),
run_pytests (sidecar test suites), git_commit (tagged `[mechanic]`), git_revert_last.
Bridge tools stay available for live repro (run_luau, captures...).
Contract in its prompt: reproduce the defect in EDIT mode first → minimal edit → hot-reload →
re-run the repro to PROVE the fix → run pytests → commit `[mechanic] <what/why>`. If it
cannot prove the fix, it must git-revert its own edits before finishing; the harness ALSO
force-reverts uncommitted changes if the run ends without a proof marker
(`FACTORY_MECHANIC_JSON: {"fixed": bool, "files": [...], "proof": "..."}`).
Auto-revert on regression: forever records the last mechanic commit per family; if the next
cycle of the SAME family drops from PASSED to FAILED/UNVERIFIED/BLOCKED, forever
`git revert --no-edit` that commit and files the revert as a new learning.

### 3. Edit-mode-first doctrine (verify wrapper)
Before any playtest_start, VERIFY must enumerate and attempt the edit-mode routes to the
oracle evidence — captures/filmstrips, rig scrubbing, run_luau probes, direct handler
invocation, RunService:Run() server-sim — aiming for ~9 distinct edit-mode checks, and may
playtest only evidence that is provably runtime-only, in-and-out. The mechanic's standing
goals include BUILDING new edit-mode test paths so playtest dependence shrinks over time.

## Testing
- Recording fallback: (Luau, live) a stuck recording no longer blocks run_luau.
- Retro: unit — lessons appended + deduped; prompts carry the LEARNED METHODS block.
- Mechanic: unit — local tools dispatched sidecar-side; unproven fix auto-reverted;
  regression triggers revert of the tagged commit. Live — first real defect.

## Out of scope
- Self-editing of the sidecar's own running process (edits to sidecar/*.py take effect next
  restart; the mechanic may still make them, flagged in its report).
