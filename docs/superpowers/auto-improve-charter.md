# Auto-Improve Charter — the standing self-directed improvement loop

**Purpose.** A disciplined loop that keeps improving this plugin without a human in every turn,
WITHOUT degenerating into the failure this charter exists to prevent: a confident, fake "done."
The 2026-06-27 dogfood is the cautionary specimen — a build was declared "validated, 29/35" while
it (a) ran in the wrong DataModel and never rendered, and (b) had an empty body the structural
grader couldn't see. The human caught it by holding ground truth. This loop must hold ground truth
itself, or it is worthless.

## The non-negotiable discipline

1. **Oracle every turn.** A change is not "done" until a *machine-or-eye-checkable* signal says so:
   `selene` 0/0 · `rojo build` green · a Spec that asserts the behavior · and **for anything visual,
   a capture I actually open and look at**. The `GuiEvidence`/structural census is necessary but NEVER
   sufficient — it graded an empty UI 29/35. Evidence is the raw output/screenshot, never a summary.
2. **Check the run context FIRST.** Before any build/capture: confirm `RunService:IsEdit()` /
   `IsRunning()` / server-vs-client. A playtest's server DataModel silently swallows edit-style work
   (the plugin keeps `LoadStringEnabled=true`, so loadstring "works" and masks it). Iteration 1 builds
   a guard for exactly this.
3. **The director/critic is a hypothesis generator, not a boss.** Treat every instruction as a claim
   to verify against the environment. If it says "the bug is in X" and X doesn't say that, report what's
   real. The worker is the only node that touched reality; deferring to a blind planner is backwards.
4. **Adversarial verification.** After I claim a change is done, an independent critic gets the *raw
   evidence* and tries to refute it. A change survives only if the refutation fails.
5. **Commits stay local (`master`, never pushed).** Matches the project's established flow.
6. **Hard stop for the human at:** anything irreversible (push, publish/`CreateAssetAsync` of shippable
   content beyond test assets, spending, OAuth/secret changes) AND any **taste call** ("is this UI
   actually beautiful / does this game feel good") — these have no machine oracle and belong to the human.
7. **Honesty over momentum.** Report what breaks. A failed turn that says so is worth more than a
   confident turn that's wrong. Never round a partial up to a pass.

## Locked decisions (do NOT re-litigate; the loop forgets, this doc remembers)

- Knowledge system, not weight fine-tuning (settled; can't fine-tune Claude).
- Commit to `master`, NOT pushed. `main` is the PR branch.
- Dev bridge + sidecar run FROM SOURCE; beta flags ("Allow HTTP Requests", "CreateAssetAsync Lua API") ON.
- Work in the main checkout (NOT a worktree) — the live Studio bridge + hot-reload read this `src/`.
- Never delete the user's `Rig` / `UAL2_Standard`; leave the place clean after live tests.
- Quality bar that must stay green at all times: `selene` 0/0 · `rojo build` green · every Spec passes ·
  `RelaySpec` no-drift · every shipped tool live-verified IN THE CORRECT CONTEXT.

## The done-condition (because "perfect" is not checkable)

"Perfect, no stone unturned" has no oracle, so it is replaced by a checkable definition:

> **DONE = the backlog below is empty AND the quality bar is green AND the human has signed off on the
> taste dimensions (visual polish, game-feel) for each shipped capability.**

The loop drains the backlog. It STOPS for the human when it hits a taste call or an irreversible action,
or when the checkable backlog is empty. New stones get appended as they're discovered (this session's
run-context guard is one such discovery). The loop is "infinite" only in that the backlog is open-ended —
not in that it ever fakes completion.

## Backlog (prioritized; each item names its oracle)

1. ✅ **DONE (iter 1)** — **Run-context guard** — DevBridge `tool`/`luau`/`prompt` results prepend a
   `[WARN run-context]` banner when a real playtest is active (`IsRunning`) or it isn't the edit
   DataModel. *Loop receipts (this is what the honest loop looks like):* the adversarial critic caught
   that my `prompt` branch + comment were unguarded (fixed); then **the HUMAN caught that my signal was
   wrong** — I'd keyed it on `LocalPlayer` presence, which false-positives in **Team Create** (it
   connects as a CLIENT with a collaborator LocalPlayer in genuine edit). Corrected to key on
   `IsRunning`; verified live silent in this Team Create session. `DevBridgeSpec` 8/8; selene 0/0; rojo
   green. **Lesson: a worker confabulates plausible run-context stories; only the human can see it's
   Team Create vs play.** *Follow-up stones:* **(1b) DECLINED (worker, director-accepted)** — extending
   the banner to the PlayBridge `/play` path is low-value/high-cost: that path runs inside an INJECTED
   in-test script (`PlayBridge.luau` ~550-568) where `DevBridge.contextBanner` is out of scope (would
   need duplicate inlined logic), and `/play` is the DELIBERATE playtest channel (context already known;
   the stray-playtest blindness was the `/agent` path, already covered). Do not re-propose. (1c) the
   original 2026-06-27 capture failure was partly a **stale `capture` fetch** — the `capture` verb returns
   the last buffered image; it should trigger a fresh shot or flag staleness.
2. **GUI image/icon authoring tool** — the one tool gap blocking the last 2 gui criteria
   (`gui-custom-asset-shapes`, `gui-unified-icon-set`): author a transparent-PNG icon via EditableImage →
   persist → apply to an ImageLabel. *Oracle:* `evaluate gui` moves those 2 to pass + a capture I look at.
3. ✅ **MEASURED (iter, 2026-06-29) — judge-tightening NOT needed for vfx; the "under-rejects" flag was a
   false alarm.** Ran `scripts/measure_judge.py vfx` via the 8319 proxy (4 calls): CURRENT judge survival
   **16/16 (100%)**, a deliberately TIGHTENED judge (reject best-practice-not-system / no-specific-mechanism
   / toggle-one-property / merely-exists) ALSO **16/16 (100%)**, and the back-test **mean 0.000 / great
   0.733 / gap 0.733 → PASS**. So the 100% survival is JUSTIFIED — the mean artifact fails all 16 criteria,
   a stricter judge rejects none, and the rubric discriminates strongly; the criteria are genuinely all
   above-generic. The back-test is the real gate (it passes); the survival-rate heuristic was overcautious.
   *Caveat:* measured vfx only (the flagged case); other categories could be spot-checked the same way but
   are lower-priority now. Outcome: stop treating high survival as a defect; trust the back-test.
4. **More guide+rubric categories** (e.g. audio/SFX, UI-motion, terrain, mounts/vehicles). *Oracle:* the
   factory's discrimination back-test passes + full criterion coverage in the generated guide.
5. **`save_build_guide` / user guides** (v1 is built-ins only; mirror the skills store). *Oracle:* a Spec
   + a live round-trip via the bridge.
6. **Netcode foundation** (the lightsaber vision: server-authoritative validation / lag-comp scaffolding
   on #4's client-request→server-execute seam). *Oracle:* a server-sim Spec asserting authority/rejection;
   this is large and partly a taste/design call → expect human checkpoints.
7. **Housekeeping** discovered along the way (schema/validator `order_index` parity, more `paint_texture`
   kinds, the pre-`/exemplars` sidecar exe rebuild, etc.). *Oracle:* per-item.

## Per-iteration protocol

1. Pick the top unblocked backlog item. 2. State the oracle up front. 3. Implement (TDD where logic;
verify-by-looking where visual). 4. Gather raw evidence. 5. Adversarial critic refutes against the
evidence. 6. If it survives: commit (local). If not: fix or report BLOCKED. 7. Append any new stone
discovered. 8. At a taste/irreversible boundary: stop and surface to the human.
