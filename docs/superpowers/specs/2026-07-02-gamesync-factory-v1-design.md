# GameSync v1 (path-C first increment) + Factory iteration v1 (2026-07-02)

Skeptic-panel-reshaped (3 hostile reviewers; artifact `tasks/w1qjnjw3z.output`). The panel's
binding re-scope: **pull-first**. GameSync v1 is the BANKING + big-refactor layer, not the inner
loop — `edit_script` (compile-checked, no sync step) remains the inner loop and this spec says so.
`game_pull` ships tonight (standalone value: the wave-game slice becomes versioned files);
`game_push` is DESIGNED here but deferred to its own session. The factory iteration does not
depend on either.

## game_pull { root? } — place scripts → git-versioned files

- Layout: `game/src/<Service>/<ancestor…>/<Name>.<kind>.luau` — the FULL ancestor chain as
  directories (the real Rojo convention; flat naming cannot round-trip a DataModel). kind =
  `server` (Script) | `client` (LocalScript) | *(none)* (ModuleScript).
- **Manifest is the source of truth** — `game/sync-manifest.json`:
  `{ relpath: { instancePath, baseHash, className, runContext?, enabled?, testSymbols? } }`.
  Filenames are sanitized for Windows (illegal chars, reserved names, case-insensitive NTFS
  collisions → refuse-and-report the twins rather than silent last-wins); the manifest's
  `instancePath` carries the true Roblox path.
- **Exclusion by IDENTITY, not header-sniffing** (two generated-header formats already coexist):
  the `StudioAgentRuntime` subtree; the hard NAME denylist {ItemBehaviorRuntime, ItemAnimRuntime,
  ItemHitClient, ItemHitServer, NpcAI, StudioAgentPlayServer, StudioAgentPlayClient}; Roblox
  default-fork subtrees {StarterPlayerScripts.PlayerModule, PlayerScriptsLoader,
  RbxCharacterSounds}; plus anything carrying the `StudioAgentGenerated` attribute (generators
  stamp it going forward). Excluded scripts are REPORTED by name, never silently skipped.
- Guards (lessons already paid for): refuses unless `RunService:IsEdit()` and no playtest is
  active (the 2026-06-27 wrong-DM failure mode); refuses when `game/` is git-dirty (commit
  first — pull must never clobber uncommitted file edits); **every pull auto-commits** via the
  sidecar (pull = a git commit; every synced state is recoverable forever — this is the FATAL
  fix's merge base: the file at the pull commit IS the baseHash-era text).
- Test-symbol flagging: pulled sources are scanned for the reserved `StudioAgentTest_` prefix +
  the legacy denylist {TestAutoKill}; hits land in the manifest `testSymbols` and the report
  (the factory gate is where they BLOCK; pull records honestly).
- Sidecar: `POST /game/write {files, manifest, message}` — writes under `game/`, refuses paths
  escaping it, auto-commits with the given message. (The sidecar owns filesystem+git IO.)

## game_push — DESIGNED, DEFERRED (next session)

Files → place. Guard = `hash(live source) == manifest.baseHash` (a pull the file-editor hasn't
ingested is a git-visible manifest change and blocks the push). `force` takes an explicit
relpath LIST (never global), and every displaced live source is staged to
`sidecar/store/staging/` before overwrite — nothing destroyed without a recoverable copy.
Push-create only when the parent instance EXISTS (never fabricate world instances); deletions
are not synced (orphans reported both ways); every write compile-checked + ChangeHistory-wrapped.

## Factory iteration v1 (attended)

- `factory/curriculum.json`: dependency-ordered rungs `{id, category, family, brief, proven,
  oracle}`. Curriculum edits are propose-only (human approves). v1 seeds the weapon family
  (sword=proven) + the near rungs.
- `docs/superpowers/workflows/factory-iteration.workflow.js`, stages SEQUENTIAL (one bridge
  client at a time; the bridge has a single-command queue):
  1. **BUILD** — the agent drives BOUNDED `studio-agent.ps1 tool …` RPCs directly (make_tool /
     bind_behavior / bind_hitbox …). **Never the in-plugin `prompt` path** (170s DevBridge cap →
     half-done builds reported as timeouts — panel FATAL).
  2. **GATE** — an ARTIFACT WALK via run_luau (not grep_source alone): every descendant's
     Source, `GetAttributes()` key names, and Instance.Name checked against `StudioAgentTest_`
     + {TestAutoKill}. Any hit ⇒ extraction BLOCKED.
  3. **VERIFY** — playtest_start/act/logs(+capture when Studio is focused) through the bridge;
     player-level probes; any unavailable oracle ⇒ status **UNVERIFIED** (never PASSED).
  4. **EXTRACT** (on PASSED only) — staging entry `sidecar/store/staging/<rung-id>.json`:
     `{rung, status: PASSED|FAILED|UNVERIFIED|BLOCKED, gateReport, playtestLog (the cursored
     slog2 lines showing the behavior events), captures (repo-relative paths), artifactTrace
     (instance paths + key attributes), recipe (draft, marked provisional), tokens, wallclock,
     interventions}` — everything a 2-minute human promotion pass needs.
- **Success criterion for tonight's attended validation (the panel's discrimination test):**
  run the spear rung TWICE, sequentially — once straight, once SABOTAGED (bind_hitbox omitted).
  The loop is validated only if the straight run lands PASSED with full evidence AND the
  sabotaged run lands FAILED/BLOCKED. A gate/oracle that has only ever said yes is unmeasured.
- Measured per run: tokens, wall-clock, human interventions (the economics baseline the
  flywheel decision needs).

## Oracles

selene 0/0 (src) · rojo green · sidecar suites + new game-write tests green · GameSync pure
helpers spec'd · live: game_pull banks RoundLoop+WaveConfig into `game/` with a git commit,
exclusions reported (StudioAgentRuntime, launchers, PlayerModule forks), TestAutoKill flagged ·
factory: the two attended runs land PASSED and FAILED respectively, with complete staging
evidence. Commits local `master`, never pushed. Adversarial review at the end.
