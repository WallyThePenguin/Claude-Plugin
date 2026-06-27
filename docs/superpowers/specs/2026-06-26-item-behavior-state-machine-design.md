# Item Behavior State Machine (roadmap #3) — design

**Date:** 2026-06-26
**Status:** design (autonomous, driven from the roadmap memory `studio-agent-interactive-items-roadmap`).
**Serves:** the FULL interactive-items vision — a handheld item with custom mesh (#1) that animates on use (#2),
runs a clean behavior **state machine** (#3, this), hits things (#4), used against PvE NPCs (#5).
**Builds on:** #1 `make_tool`/`grip_tool` (`src/ToolFactory.luau`, `src/Tools/Item.luau`), #2 `bind_animation`
(`src/Tools/ItemAnim.luau`, the client `ItemAnimRuntime`). #2 is now runtime-verified (see `HANDOFF.md`).

## Purpose

Give a Tool a clean, **authored behavior state machine**: equipped → **idle**, and on activate a timed
sequence **windup → active → cooldown → idle**. The machine drives WHEN the use-animation plays and WHEN the
effect fires, and exposes a defined **active window** that #4 (hit detection) hooks. It is the timing spine the
later sub-projects attach to.

## States

| State | Meaning | Animation | Accepts Activate? |
|---|---|---|---|
| **idle** | equipped, at rest | looped idle clip | YES → windup |
| **windup** | telegraph / swing start | use (swing) clip, from t=0 | no |
| **active** | THE EFFECT WINDOW (hitbox live) | (swing continues) | no |
| **cooldown** | recovery (the anti-spam gate) | (swing finishes / idle) | no |

Transitions: `idle --Activate--> windup --(windup s)--> active --(active s)--> cooldown --(cooldown s)--> idle`.
Only `idle→windup` is event-driven (Tool.Activated); the rest are time-driven by the item's authored durations.
The **active window** = the time interval `[windup, windup+active]` after activation.

## Approaches considered

1. **Attribute-driven generic runtime (CHOSEN).** `bind_behavior` writes the three durations as Tool
   **Attributes** and writes ONE generic state-machine LocalScript that reads them, gates Activate, plays the
   right clip per state, and exposes the current state. A pure `BehaviorFactory` validates the config + computes
   the timeline (unit-tested). Simplest, **inspectable** (attributes survive Play and show in Explorer),
   composes directly with #2's `Anims/idle`+`Anims/use`, and extends cleanly (more states later).
2. **ModuleScript config** returning a table with per-state callbacks. Richer, but heavier, less inspectable,
   and invites arbitrary per-item code. YAGNI for #3.
3. **Server-authoritative state machine now.** The "correct" netcode shape, but #3 is the in-Studio dev loop and
   server-authoritative validation is an explicit LATER concern (the user's "dev-loop now, ship later"). The
   chosen design exposes the state as a signal so #4 / netcode can add server authority WITHOUT a redesign.

## Data model

On the Tool, three numeric **Attributes** (seconds, ≥ 0): `BehaviorWindup`, `BehaviorActive`,
`BehaviorCooldown`. Defaults `0.15 / 0.15 / 0.40`. The runtime reads them at activate time (so re-tuning is just
a `set_property` on an attribute — no rebind). No extra config instances.

## Pure engine — `src/BehaviorFactory.luau` (+ `BehaviorFactorySpec.luau`)

Mirrors `ToolFactory`'s pure/impure split (pure logic is directly unit-testable):

- `BehaviorFactory.validate(cfg) -> ({windup, active, cooldown}, err?)` — coerce each to a number, clamp to
  `>= 0`, apply defaults for missing/invalid, require `windup+active+cooldown > 0` (else err).
- `BehaviorFactory.timeline(cfg) -> { {state, at, duration} }` — the cumulative timeline:
  `windup@0`, `active@windup`, `cooldown@windup+active`, `idle@windup+active+cooldown`. Used by the tool's
  human summary and to document the active window. Pure → spec-tested (defaults, clamping, cumulative offsets,
  active-window `[windup, windup+active]`).

## The runtime — client `ItemBehaviorRuntime` (a generated LocalScript, ASCII, like `ItemAnimRuntime`)

`bind_behavior` writes this and it **supersedes `ItemAnimRuntime`** (it does BOTH animation playback AND the
state machine; it reuses the `Anims/idle`+`Anims/use` clips #2 authored). Behavior:

- `Tool.Equipped` → enter **idle** (load+loop the idle clip).
- `Tool.Activated`, only when state==idle → run the sequence with a re-entrancy **token** (a fresh token per
  run; a stale token aborts mid-sequence on Unequip/replace):
  1. state=**windup**, set `ItemState` attribute + fire `StateChanged`; play the use clip once.
  2. `task.wait(windup)` → state=**active**, set attribute + fire `StateChanged` (**the effect window** — #4
     connects here; the hitbox is live for the active duration).
  3. `task.wait(active)` → state=**cooldown**, set attribute + fire `StateChanged`.
  4. `task.wait(cooldown)` → state=**idle**, set attribute + fire `StateChanged`; resume the looped idle.
- `Tool.Unequipped` → invalidate the token, stop tracks, reset state to idle.

**State exposed two ways** (so #4 has a clean, decoupled hook): the Tool **Attribute `ItemState`** (one of
idle/windup/active/cooldown) and a child **`BindableEvent` `StateChanged`** that fires the new state string on
each transition. #4 will `StateChanged.Event:Connect` and run a hitbox sweep while state==active.

Re-activation while not idle is IGNORED (that is exactly what windup/active/cooldown encode — no spam).

## Tool — `bind_behavior` (`src/Tools/ItemBehavior.luau`)

`bind_behavior(tool, windup?, active?, cooldown?)`:
1. Resolve the Tool (must be a `Tool`). If it lacks `Anims/use` (no #2 bind yet), still bind but WARN that the
   swing won't animate until `bind_animation(tool,'use',...)`.
2. `validate` the config.
3. Write the three Attributes.
4. Ensure a child `StateChanged` `BindableEvent`; write/replace the `ItemBehaviorRuntime` LocalScript (removing
   any prior `ItemAnimRuntime`, which it supersedes).
5. Return a summary: the timeline, the active window `[windup, windup+active]`, and a note that #4 hooks
   `StateChanged=='active'`. **Destructive** (DataModel writes, undoable in edit), **RELAY**, parent-only.

## Composition / authoring order

`build visual → make_tool → grip_tool → bind_animation(idle) + bind_animation(use) → bind_behavior(windup,active,cooldown)`.
`save_mesh` the Handle first if it is a custom mesh (same as #2). A SystemPrompt note extends the
"# Building handheld items" section.

## Verification

- `BehaviorFactorySpec` (pure: defaults, clamping, timeline offsets, active window) + `RelaySpec` (no-drift —
  `bind_behavior` is RELAY).
- **Live dogfood via the play bridge** (now that #2's avatar-rig fix renders animations): `bind_behavior` on
  `StarterPack.UseSword` → `play start` → `play act activate` → observe `ItemState` step
  idle→windup→active→cooldown→idle over the authored durations (read the attribute server-side, like `sdiag`),
  the use clip plays on activate, idle resumes after cooldown, and a second activate DURING cooldown is ignored.

## Scope / non-goals

- **IN:** the state-machine engine (`BehaviorFactory`), `bind_behavior`, the `ItemBehaviorRuntime`, and the
  active-window hook (`ItemState` attribute + `StateChanged` event).
- **OUT (= #4):** the actual hitbox/raycast + damage on the active window — #3 only EXPOSES the window.
- **OUT (later):** server-authoritative netcode / lag-comp; multi-step combos, charge/hold mechanics, resource
  costs (the timeline is extensible to these without redesign).
