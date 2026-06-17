# Studio Agent — Parallel Writer Subagents (`dispatch_writers`) Design

- **Date:** 2026-06-17
- **Status:** Approved design (calls delegated to the implementer) — pending spec self-review, then
  implementation plan.
- **Relates to:** `HANDOFF.md`; the subagents design (`2026-06-16-studio-agent-subagents-design.md`)
  which this extends from read-only to partitioned writers.
- **Scope:** ONE feature. The remaining parity feature (skills) is a separate, later spec.

## Goal

Speed up large builds by running **multiple WRITER agents in parallel inside one Studio instance**,
each confined to a disjoint region of the DataModel. The plugin is an *inside* tool (in-process at
PluginSecurity, instant DataModel access) — measured ~100× faster + more accurate than the native
Roblox Assistant / official MCP for the same task — so parallelism stays inside the plugin, NOT via
Roblox's (slow) MCP or Team Create (which needs multiple accounts/instances).

The speedup comes from **overlapping LLM round-trips**: a single agent spends ~95% of its time
waiting on Claude over HTTP; the DataModel writes are instant. N partitioned writer loops put N
Claude round-trips in flight at once → ~N× throughput on big, partitionable builds.

## The core insight (why parallel writers are now safe)

The original subagents were read-only because "one DataModel + one ChangeHistory stream → parallel
writers corrupt undo grouping and race." With **structured, synchronous, partitioned** writes that
fear does not apply:

- **Luau in Studio is cooperatively scheduled** — coroutines (`task.spawn`'d children) switch ONLY at
  `yield` points (HTTP `RequestAsync` awaits, `task.wait`). There is no preemption.
- **`create_instance`/`set_property` are synchronous** — each opens a `ChangeHistoryService`
  recording, writes, and finishes with NO yield in between (verified by reading the tools). So each
  tool call's recording is **atomic**: a child cannot be interrupted mid-call, so two children's
  recordings can never overlap. The children's *loops* interleave (at HTTP awaits); their *writes* do
  not.
- Therefore **per-call recordings are already safe under parallelism**. No parent-held recording (which
  would have to span the children's multi-second HTTP awaits — untested + risky), no overlap, no
  corruption. Undo granularity stays per-edit, exactly as it is for the single agent today.

## Key decisions (settled in brainstorming; design calls delegated)

1. **New tool `dispatch_writers`** (read-only `dispatch_subagents` is unchanged). Input:
   `{ writers: [ { region: <dot-path>, task: <self-contained prompt> } ] }`. Each child is a writer
   agent confined to `region`, running `task`. Capped at `writerMaxParallel`.
2. **Regions must already exist.** The parent creates the region containers (e.g. a `Folder` or
   `ScreenGui` at `game.StarterGui.Shop`) BEFORE dispatching; `dispatch_writers` errors a child whose
   `region` path doesn't resolve. (Keeps the guard simple: the region root is a live Instance the child
   is fenced inside.)
3. **Structured tools only for writers — NO `run_luau`, NO dispatch (depth-1).** Writers get
   `create_instance`, `set_property` (region-guarded writes) + `get_tree`/`search`/`get_properties`/
   `get_output`/`capture` (reads, unguarded — reading anywhere is safe). `run_luau` is excluded because
   arbitrary Luau cannot be region-guarded (it can index any instance) and could yield mid-recording.
   This covers the vast majority of building — GUIs, scenes, and even scripts (a writer makes a
   `Script`/`LocalScript`/`ModuleScript` and sets its `Source` property). The **serial parent keeps
   `run_luau`** for anything that genuinely needs loadstring/logic. Enforced by the SAME allowlist
   mechanism subagents use (`context.allowedTools` at `Tools.dispatch`).
4. **Region guard in the structured write tools.** `create_instance`/`set_property` gain a
   `context.writeRegion` check (a live Instance): the write target must be the region root or a
   descendant (`target == region or target:IsDescendantOf(region)`), else the call returns an
   is_error result ("write outside your assigned region <path> is not permitted"). When
   `context.writeRegion` is absent (normal parent use), there is NO guard — behavior is unchanged.
   - `create_instance`: the resolved `parent` must be within the region. (The instance is parented to
     `parent` LAST in Create, so the final location is guarded; a stray `Parent` in `properties` is
     overwritten by `parent`.)
   - `set_property`: the resolved target must be within the region, AND — to close the **re-parent
     escape** — if `name == "Parent"`, the decoded new-parent Instance must ALSO be within the region
     (else an in-region instance could be moved OUT). Reference-typed properties that merely POINT
     outside (e.g. `ObjectValue.Value`, `PrimaryPart`) are allowed — they don't structurally move
     anything; only `Parent` relocates.
5. **Reuse `Subagent.run`** for writer children (ephemeral loop, no rollback/compaction/persistence —
   the same runner the read-only subagents use). Differences for a writer child: the writer toolset +
   allowlist, a `buildWriter(region, task)` system prompt (OUTPUT CONTRACT included, delivered via the
   message preamble — the proxy strips `system`), and `writeRegion` threaded in the child's tool
   context. The parent fans out via `task.spawn` and **yields during the join** (so the parent is NOT
   writing — quiescent — while children write), exactly like `dispatch_subagents`.
6. **Model = `writerModel` (default `claude-sonnet-4-6`).** Focused, partitioned tasks are simpler;
   Sonnet is cheaper and lighter on the subscription window with N in parallel. Configurable to Opus
   when build accuracy matters more than cost/speed.

## Non-goals (YAGNI)

- No one-undo-for-the-whole-batch (would need a parent recording held across HTTP awaits — untested
  Studio behavior + would require harmonizing `set_property`, which currently errors when a recording
  is already open). Per-edit undo (today's granularity) is fine. Possible future enhancement.
- No automatic region/partition inference — the model decides the split (like it decides read fan-out).
- No cross-child shared state / messaging — children are independent and partitioned; the parent does
  any cross-region wiring AFTER the batch.
- No nested parallelism (depth-1): writers can't dispatch writers or subagents.
- No `run_luau` for writers (decision 3).

## Architecture

### New modules
- **`src/Tools/Writers.luau`** — the `dispatch_writers` tool (mirrors `Tools/Subagents.luau`).
  `run(input, context)`:
  - Validate `{ writers = [...] }` (non-empty array; each `{ region: string, task: string }`).
  - Lazily require `Tools` + `Subagent` + `Path` (break the load cycle, as Subagents does).
  - Cap to `config:getWriterMaxParallel()`; report `dropped` if exceeded.
  - For each writer: resolve `region` via `Path.resolve` → must be a live Instance (else that child
    returns an error result). Build the writer context `{ config, anthropic, allowedTools = WRITE_SET,
    writeRegion = regionInstance, shouldCancel }`.
  - `task.spawn` each child running `Subagent.run({ ..., systemPrompt = SystemPrompt.buildWriter(region,
    task), taskPrompt = task, toolSchemas = Tools.schemasFor(WRITE_TOOL_NAMES), allowedTools, model =
    writerModel, maxIterations = writerMaxIterations, writeRegion = regionInstance })`. Whole worker
    pcall-wrapped so `done` always increments (join can't hang) — same hardening as Subagents.
  - Join (`while done < n do task.wait() end`), return one JSON tool_result `{ ok, count, results:
    [{ region, ok, capped, text }], dropped? }`.
  - `WRITE_TOOL_NAMES = { create_instance, set_property, get_tree, search, get_properties, get_output,
    capture }`. `destructive = true` (it builds).
- **`src/WritersSpec.luau`** — in-Studio self-test (mirrors `SubagentsSpec`) over the PURE/structural
  surface: input validation/normalization; that `schemasFor(WRITE_TOOL_NAMES)` returns exactly the
  writer set and EXCLUDES `run_luau`/`dispatch_subagents`/`dispatch_writers`; that the allowlist at
  `Tools.dispatch` rejects `run_luau` for a writer context; and the region-guard helper (see below) for
  within/outside cases using throwaway `Instance.new` trees (no network).

### Touched modules
- **`src/Tools/Create.luau`** — `runCreate(input, context)`: if `context.writeRegion` is set, after
  resolving `parent`, reject unless `parent == region or parent:IsDescendantOf(region)`. Factor the
  check into a shared helper (below) so both write tools and the spec use it.
- **`src/Tools/Properties.luau`** — `set_property`: same guard on the resolved target.
- **`src/Tools/RegionGuard.luau`** (new, tiny) — `RegionGuard.within(target: Instance, region:
  Instance): boolean` = `target == region or target:IsDescendantOf(region)`; and a convenience
  `RegionGuard.check(target, context) -> (ok, errMsg)` returning `(true)` when `context.writeRegion`
  is nil. Pure-ish (uses only `IsDescendantOf`), shared by Create/Properties and exercised by the spec.
- **`src/Tools/init.luau`** — require + register `Writers.descriptors` (after `Memory`).
- **`src/Subagent.luau`** — thread `opts.writeRegion` into the child's tool `context` (alongside
  `config`/`anthropic`/`allowedTools`). No other change (the loop is identical).
- **`src/SystemPrompt.luau`** — add `SystemPrompt.buildWriter(region, task)` (a writer-child prompt:
  confined to `region`, structured-tools-only, no run_luau, the OUTPUT CONTRACT, value-encoding + GUI/
  build patterns) and a parent-facing "# Parallel building" section + the `dispatch_writers` tool line.
- **`src/Config.luau`** — `writerModel` (default `claude-sonnet-4-6`), `writerMaxParallel` (3),
  `writerMaxIterations` (20), with getters + validation mirroring the subagent knobs.

### Data flow
```
model: (1) create region containers (create_instance: StarterGui.Shop, Workspace.Lobby, ...)
       (2) dispatch_writers({ writers = [ {region:"game.StarterGui.Shop", task:"build the shop UI"},
                                          {region:"game.Workspace.Lobby", task:"build the lobby"} ] })
  → Writers.run: resolve each region → spawn N Subagent.run children (writerModel), each with
      allowedTools = WRITE_SET and context.writeRegion = <region instance>
  → children build IN PARALLEL (N Claude round-trips overlap); each create_instance/set_property is
      region-guarded + records atomically (cooperative scheduling → no overlap)
  → join (parent yields, quiescent) → returns each child's terse report
  → parent synthesizes + does cross-region wiring + verifies (capture / get_tree)
```

## Correctness rules / edge cases
- **Total dispatch:** `Writers.run` never throws; a missing/garbage region or a child error becomes an
  is_error entry in the results, never aborts the parent. Whole worker pcall-wrapped so the join can't
  hang (Subagents' join-hang lesson).
- **Region guard is mandatory for writes:** a writer's `create_instance`/`set_property` ALWAYS carries
  `context.writeRegion`, so it cannot write outside its region. Reads are unguarded (safe).
- **No `run_luau` escape:** `run_luau` is not in `WRITE_TOOL_NAMES`, so the allowlist at `Tools.dispatch`
  rejects it for a writer (defence: even if a writer tried, it's blocked structurally, like the
  read-only subagents block writers).
- **Cooperative-atomicity invariant:** the region-guarded write tools must remain SYNCHRONOUS (no
  `yield`/`RequestAsync`/`task.wait` between `TryBeginRecording` and `FinishRecording`). They are today;
  the guard adds only synchronous checks. (A yield there would let recordings overlap — do not add one.)
- **Empty-object encoding:** `dispatch_writers` always carries a non-empty `{writers=...}`; no `[]`
  hazard.
- **ChangeHistory:** per-call atomic recordings (unchanged tools); undo is per-edit, interleaved across
  regions but functional. No parent recording (decision / non-goal).
- **Quiescent parent:** the parent yields inside `dispatch_writers` during the join, so it isn't
  writing while children write (same DataModel-safety story as `dispatch_subagents`).

## System prompt additions (summary)
- Tool line: `dispatch_writers(writers)` — fan out PARALLEL writer children, each confined to a region,
  to build independent parts at once; see "# Parallel building".
- "# Parallel building" (parent): for a large build with INDEPENDENT parts, (1) create the region
  containers yourself, (2) call `dispatch_writers` with one `{region, task}` per part — children build
  in parallel and are FENCED to their region (structured tools only, no run_luau), (3) after they
  return, do any cross-region wiring and verify. Use it only when parts are genuinely independent;
  for a small or tightly-coupled build, just build it yourself.
- `buildWriter(region, task)`: the child is a writer confined to `region`; only `create_instance`/
  `set_property` (+ reads); write scripts via a `Script`'s `Source` property; OUTPUT CONTRACT (terse
  report of what it built, with paths).

## Testing
- **Static:** `selene src` (0 errors), `stylua --check src`, `rojo build`.
- **`WritersSpec`** (in-Studio): input validation; `schemasFor(WRITE_TOOL_NAMES)` exactly the writer set
  + excludes run_luau/dispatch; allowlist rejects run_luau for a writer context; `RegionGuard.within`
  for within/outside/self cases (throwaway `Instance.new` trees).
- **Adversarial review** (Workflow): focus on the region guard (can a writer escape its region — via
  create_instance parent, set_property target, a re-parent, or a reference-typed property pointing
  outside?), the cooperative-atomicity assumption (any yield in the write path?), the allowlist
  (run_luau/dispatch truly blocked), the join (can't hang), and ChangeHistory behavior under parallel
  per-call recordings.
- **Live-verify in Studio** (computer-use, in a NEW Baseplate per the test-session preference): ask for
  a build with 2–3 independent parts; confirm the parent creates the containers + `dispatch_writers`
  fans out; confirm the parts build IN PARALLEL and FASTER than serial; confirm each writer stayed in
  its region (nothing built outside); confirm a writer that tries to write outside its region is
  rejected; confirm undo works.

## Rollout / ordering
1. `Tools/RegionGuard.luau` + region guard in `Create.luau`/`Properties.luau` (context-gated; no-op
   when `writeRegion` absent) + a spec for the guard.
2. `Config.luau` writer knobs.
3. `Subagent.luau` thread `writeRegion` into context.
4. `Tools/Writers.luau` (`dispatch_writers`) + register in `Tools/init.luau` + `WritersSpec`.
5. `SystemPrompt.luau` `buildWriter` + parent "# Parallel building" section + tool line.
6. Build + lint, adversarial-review Workflow, fix, rebuild, hand off for live-verify.
