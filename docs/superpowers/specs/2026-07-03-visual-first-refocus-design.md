# Visual-first refocus of the factory loop — design

**Date:** 2026-07-03 · **Status:** approved by user ("Approve — build it")

## Why

The 50-cycle unattended run exposed two gaps against the standing mandates:

1. The reference-first / build-with-vision rules never executed (0 `get_references`
   calls all run) — fixed earlier today in `f82ea3c` (vision discipline in every
   BUILD prompt + `imagesKept` 6→10).
2. The rotation itself was combat-heavy (waves, hostile enemies) and verified by
   console logs only. The user directive: *"Clear the waves, the enemies killing
   us, etc. only focus on the map, the gui, the animations, and one training dummy
   that the player attacks so you can visually see the frame by frame of the
   animation and weapons from every angle."*

## Design

### 1. Focus rotation (clear waves + hostile enemies)

- `factory/curriculum.json` gains a top-level `"focus"` list:
  `["melee-weapon", "animation", "building", "environment", "gui"]`.
- `forever.py` uses that list as the default family filter when `start()` is
  called with `families=None` (an explicit `families` argument still overrides —
  the existing tests keep passing).
- `game-system`, `melee-enemy`, `ranged-enemy` rungs KEEP their proven status but
  drop out of rotation. Reversible by editing the focus list.
- Rejected alternatives: per-launch `families` args (forgettable — one default
  launch and the waves are back); deleting the rungs (destructive, loses proven
  status).

### 2. TrainingDummy — the persistent visual fixture

One anchored humanoid rig near spawn, a permanent part of the map:

- Named `TrainingDummy`, in `workspace`.
- God mode: on `Humanoid.HealthChanged` it prints
  `[TrainingDummy] HIT damage=<MaxHealth-health> hitcount=<n>` then resets
  `Health = MaxHealth`. Never dies, never fights back, no AI.
- Created in EDIT mode (so it is baked into every play snapshot). Verify uses it
  and does NOT destroy it. Replaces the clone-`VerifyDummy`-then-destroy flow.

### 3. Weapon verify: visual + functional evidence

Three evidence kinds (was: log-only):

- **(a) Every angle:** `capture_angles` of the built weapon Tool (3–4 angles),
  graded against `get_references` photos per the vision discipline.
- **(b) Damage (log):** playtest, walk to the TrainingDummy, attack; read
  `[TrainingDummy] HIT damage=` lines — damage must equal the configured value.
  Console logs remain the right instrument for numbers.
- **(c) Frame-by-frame:** 2–3 `playtest_capture` frames during swings so the
  attack animation is SEEN (windup/contact readable), not inferred.

Budget note: verify cap stays 36; the prompt orders evidence gathering so (b)
decides pass/fail and (a)/(c) are captured before `playtest_stop`.

### 4. Supervised first ascents (unlock map/GUI/animations)

- `FactoryRunner.start(rung_id, supervised=False)` — `supervised=True` permits a
  `proven=false` rung. The forever loop NEVER passes it (charter intact:
  autonomy remains proven-only). Only an interactive session uses it.
- This session runs four ascents, one at a time, in order:
  `env-arena-dress` → `structure-house` → `gui-main-menu` → `anim-idle-breathe`.
- Supervision = the operator (Claude, user present) reads the actual capture
  PNGs from the capture store and judges them against references BEFORE flipping
  `proven: true` in the curriculum. A FAILED/UNVERIFIED ascent does not flip.

### 5. Place cleanup (edit-mode, via bridge)

- `RoundLoop` (wave system): `Disabled = true` — not deleted.
- Hostile NPCs in `workspace`: removed. `ServerStorage.EnemyTemplate` stays.
- TrainingDummy created (idempotent — skip if present).

## Testing

- Unit: focus list read by forever (default) + explicit `families` override
  still honored; `supervised=True` admits an unproven rung, default still
  refuses; weapon verify prompt references TrainingDummy + capture evidence and
  no longer destroys the dummy; game-system/gui prompts unchanged re: vision.
- Live: the four ascents themselves, judged on real captures.

## Out of scope

- Ship-grade combat (waves/enemies) — parked, reversible via focus list.
- Weapon-attack animation *authoring* rungs (future proposals may add them);
  `anim-idle-breathe` is the animation ascent.
