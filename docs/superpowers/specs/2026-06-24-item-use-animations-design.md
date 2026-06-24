# Studio Agent — Item use-animations (`bind_animation`) design (2026-06-24)

**Status:** approved in brainstorming, ready for an implementation plan.
**Goal:** Make a handheld item ANIMATE WHEN USED — equip plays an idle-hold, activate plays a swing/use
animation, and the welded item moves with the arm. This is the "good merge of meshes + animations" — sub-
project #2 of the interactive-items roadmap (memory `studio-agent-interactive-items-roadmap`), building on
#1 (`make_tool`/`grip_tool`). It binds authored animations to a `Tool` so the item works in a playtest,
with NO publishing required for the build/test loop.

## 1. Background (verified this session via the bridge)

- **A welded item follows arm animations.** The item's Handle is welded to `RightHand` (the `RightGrip`
  weld from #1); arm animations move the hand via `Motor6D`, and a weld's part rigidly follows its anchor.
  PROVEN: posing the rig's right arm (`ik_reach`) swung the held sword forward with it (a rest→strike
  pose visibly moved the blade).
- **No-publish playback exists + is proven in edit.** `src/AnimationClip.luau`'s `register` uses
  `KeyframeSequenceProvider:RegisterKeyframeSequence(ks)` → a LOCAL content-hash AnimationId (no upload);
  `capture_animation` (`src/Tools/Capture.luau`) sets `Animation.AnimationId = <that id>` →
  `Animator:LoadAnimation(anim)` → plays. So an authored `KeyframeSequence` plays through the real
  `Animator` with NO published asset. (Runtime use of this path is confirmed at BUILD time below.)
- **Authoring already works.** The animation engine (`add_keyframe` flip-book → `KeyframeSequence` under
  `rig/AnimSaves`, `capture_animation` filmstrip) authors + previews clips; with the item equipped, the
  preview shows the item moving.

**Key reframe:** the new work is the BINDING (play the authored clip on Tool events at runtime), not the
authoring (done) or the follow-the-arm mechanism (proven). The playback reuses the proven no-publish
`RegisterKeyframeSequence` → `Animator` path.

## 2. Settled decisions (from brainstorming)

- **Playback = the no-publish Animator path** (recommended over both the raw-Motor6D-replay and the
  published-asset options): a generated Tool script REGISTERS the carried `KeyframeSequence`
  (`RegisterKeyframeSequence`, no upload) → `Animator:LoadAnimation` → `Play`. It uses the real Animator
  (priority/blending: an Action-priority swing overrides a Movement-priority idle) and avoids the publish
  wall. **Publishing the animations via Open Cloud is the robust upgrade for SHIPPED MULTIPLAYER** (noted,
  not required for the build/test loop).
- **The Tool is self-contained:** the authored `KeyframeSequence`(s) are COPIED into the Tool (as children
  under a `Anims` folder), so the item carries its own animations and the runtime script registers them
  locally.
- **Scope = idle-hold + one use/swing**, bound to Equipped/Activated. Combos, hit detection (#4), and the
  full behavior state machine (#3) are out.

## 3. Behavior

### Authoring (existing tools, item-aware)
The agent builds the item (#1: `generate_mesh`/`paint_texture` → `make_tool` → `grip_tool`), then authors
the animations on the rig WHILE it holds the item: `ik_reach`/`pose_joint` the arm per keypose →
`add_keyframe {clip}` → `capture_animation {clip}` to preview (the held item moves in the filmstrip). Two
clips: an `idle` (a held-ready pose, looped) and a `use` (a swing/thrust, Action).

### `bind_animation(tool, event, clip, rig?)` — the new tool
- `tool` (required) — path to the `Tool` (from `make_tool`).
- `event` (required) — `"idle"` (plays on Equipped, looped) | `"use"` (plays on Activated, Action priority).
- `clip` (required) — the authored clip name under `rig/AnimSaves` (default rig = the one holding the tool,
  else a `rig` path).
- Behavior: resolve the `KeyframeSequence` for `clip`; COPY it into `tool/Anims/<event>` (replacing any
  prior); ensure the Tool has the generated runtime `Script` (`tool/ItemAnimRuntime`, written/updated
  idempotently) that wires the events. Returns a summary (which event→clip is bound, the clips present).
- The generated runtime `Script` (a Script or LocalScript in the Tool — whichever the build-time
  verification confirms `RegisterKeyframeSequence`+`Animator` plays in; runs in a playtest): on `Tool.Equipped`,
  resolve the character's `Humanoid`/`Animator`, register + `LoadAnimation` the `idle` KeyframeSequence,
  `:Play()` it (looped); on `Tool.Unequipped`, stop it; on `Tool.Activated`, register + play the `use`
  clip once (Action priority) — the Animator blends it over the idle, and the welded Handle follows.
  Reads the carried `KeyframeSequence`s from `tool/Anims/*`; uses `RegisterKeyframeSequence` (no asset id
  needed).

### Build-time verification of the runtime path
Before relying on it, VERIFY at build time (bridge probe) that `RegisterKeyframeSequence` →
`LoadAnimation` → `Play` actually animates the rig in a RunService-stepped context (it works in edit via
`capture_animation`; confirm the registered id loads + plays so the generated runtime script's mechanism
is sound). The full Tool.Activated-in-playtest behavior is confirmed by a USER playtest (the bridge is
edit-only; client-play script behavior can't be auto-captured).

## 4. Architecture / modules

### New
- **`src/Tools/ItemAnim.luau`** — the `bind_animation` descriptor: resolve tool + clip + rig, copy the
  KeyframeSequence into `tool/Anims/<event>`, write/refresh the runtime `Script` from a template string,
  return a summary. Destructive (DataModel writes); RELAY; parent-only.
- **The runtime `Script` template** (a Luau source string the tool writes into the Tool) — the
  Equipped/Activated/Unequipped handler using `RegisterKeyframeSequence` + `Animator`. Kept as a clearly-
  delimited multi-line string constant in `ItemAnim.luau` (one responsibility: the runtime behavior).

### Reused
- `src/AnimationClip.luau` (`register` = `RegisterKeyframeSequence`; clip lookup under `rig/AnimSaves`),
  the animation engine (`add_keyframe`/`capture_animation`), `make_tool`/`grip_tool` (#1), `Path.resolve`,
  the ChangeHistory-recorded edit + RELAY patterns.

### Changed
- **`src/Tools/init.luau`** — require + append `ItemAnimTool.descriptors`; comment-list entry.
- **`src/RelaySpec.luau`** — add `bind_animation` to `EXPECTED_RELAY`.
- **`src/SystemPrompt.luau`** — extend "# Building handheld items": after `grip_tool`, author idle + use
  clips on the held rig, then `bind_animation(tool, event, clip)` so the item animates on equip/use; note
  it plays unpublished (no upload) and that publishing is the multiplayer-ship upgrade.

## 5. Error handling, limits, edge cases

- **Total:** every `bind_animation` path is pcall-wrapped → `(string, isError)`; never throws.
- **Missing clip / not a Tool / no rig:** clear errors.
- **Re-bind:** copying a clip into `tool/Anims/<event>` replaces the prior; the runtime Script is rewritten
  idempotently (same template) so re-binding is safe.
- **Priority:** idle = `Movement`/`Idle` priority (looped); use = `Action` (overrides idle while playing).
  The authored clips carry their priority (`add_keyframe` sets `Action` by default — the idle clip may need
  a lower priority; the tool can set the looped/priority on the copied KeyframeSequence).
- **Runtime only:** the animations play in a PLAYTEST (scripts don't run in edit); the edit-mode
  `capture_animation` preview is the author-time check. A capture can't show the runtime Tool behavior.
- **Multiplayer:** `RegisterKeyframeSequence` is client/session-local; for replicated multiplayer the
  animations should be PUBLISHED (Open Cloud) — out of v1 scope, noted in the tool output + prompt.

## 6. Testing & acceptance gate

- **Static, each task:** `stylua src` ; `selene src` (0/0) ; `rojo build …` ; `RelaySpec` no-drift green
  (covering `bind_animation`).
- **Bridge build-time verification:** confirm `RegisterKeyframeSequence` → `LoadAnimation` → `Play` loads
  + advances an authored clip on the rig (it underpins the runtime script).
- **Bridge dogfood (author + bind):** build a sword → `make_tool`/`grip_tool`; author an `idle` + a `use`
  (swing) clip on the held rig; `capture_animation` each → READ the filmstrips (the sword moves with the
  arm); `bind_animation {tool, event:"idle", clip:...}` + `{event:"use", clip:...}` → confirm
  `tool/Anims/idle`+`use` KeyframeSequences exist and the `ItemAnimRuntime` Script is present + references
  them.
- **USER playtest (the runtime gate):** equip the Tool in Play → the idle-hold plays; click → the swing
  plays and the sword swings. (Can't be auto-captured — the user confirms, like the GREY-bug Play check.)

## 7. Scope & non-goals

**In (v1):** `bind_animation` (idle + use), the runtime Script template, the build-time + playtest
verification, RelaySpec + SystemPrompt.

**Out (deferred):**
- **Combo chains / multiple use animations / directional swings** — one `use` clip in v1.
- **Hit detection / damage on swing** (#4) and the **full behavior state machine** (#3 — v1 is the minimal
  equip→idle / activate→use wiring, not a general SM).
- **Open Cloud publishing** for replicated multiplayer (the robust ship upgrade; needs a scoped API key).
- **Animation authoring helpers** (curated swing-arc templates) — the existing keypose engine is used as-is.

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). A plugin code change needs `.\build.ps1` + a USER
Studio restart. Drive the dogfood via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; Studio
FOCUSED for captures). Execute with **superpowers:subagent-driven-development**. Commit per task; don't
push. Verify by LOOKING (edit) + a USER playtest (runtime).
