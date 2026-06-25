# Studio Agent — Item use-animations (`bind_animation`) design (2026-06-24, research-grounded rev)

**Status:** approved in brainstorming (revised after a playtest + a 103-agent deep-research pass), ready for
an implementation plan.
**Goal:** Make a handheld item ANIMATE CORRECTLY WHEN USED — equip plays a looping idle-hold, activate plays
a swing/use animation that moves ONLY the arm (the legs keep walking), and the welded item swings with it.
Sub-project #2 of the interactive-items roadmap (memory `studio-agent-interactive-items-roadmap`), on #1
(`make_tool`/`grip_tool`). Targets the in-Studio build/preview loop (no publishing); shipping/multiplayer
publishing is a flagged follow-up.

## 0. Why this rev — the playtest taught us two things

A first spike (a Tool that played an authored clip via `RegisterKeyframeSequence` on the client) was
playtested. RESULT: **the no-publish playback DID fire at runtime** (the core mechanism works in solo
Studio), but (a) the clip **stiffened the WHOLE body** (it keyed every joint), and (b) the Cube Handle mesh
**broke in Play** (transient mesh). A deep-research pass (cited Roblox docs, adversarially verified) then
established the correct approach below.

## 1. Background — verified facts (deep-research, 2026-06-24; cited to create.roblox.com + DevForum)

- **The Animator blends PER JOINT, high-to-low by priority** (same priority blends by weight, per-joint sum
  &lt;1.0). An "arm-only" clip = **OMIT the Pose for the leg/torso joints** in the `KeyframeSequence`; a
  higher-priority swing then overrides only the keyed arm joints while lower-priority locomotion drives the
  unkeyed legs. **This is the supported partial-body path** — the research explicitly REFUTED needing
  per-frame `Motor6D.Transform` hacks. (Source: AnimationPriority enum docs; "how to not allow animation on
  a specific limb".)
- **Seven priority levels, low→high:** `Core`(value 1000, lowest-effective, Roblox defaults), `Idle`(0),
  `Movement`, `Action`, `Action2`, `Action3`, `Action4`. Higher overrides lower per joint. **Tool: idle-hold
  at `Idle` (looping); swing at `Action`; combos `Action2-4`.**
- **`Animator:LoadAnimation`** is the API — `Humanoid:LoadAnimation` / `AnimationController:LoadAnimation`
  are DEPRECATED (staff, 2020). The `Animator` handles playback AND replication.
- **Where to play (replication):** for the PLAYER'S OWN character, **start tool animations on the CLIENT
  (a LocalScript)** — client-started animations on an `Animator` under the server-spawned `Character`'s
  `Humanoid` auto-replicate to the server and all clients. (NPCs/objects must be started on the SERVER.)
  Priority changes don't auto-replicate.
- **No-publish playback is STUDIO-ONLY.** `KeyframeSequenceProvider:RegisterKeyframeSequence(ks)` returns a
  TEMPORARY ContentId usable as `Animation.AnimationId`, but it does NOT replicate to other players and
  **does NOT work outside Studio**. Great for the in-Studio build/preview loop; a SHIPPED item needs a
  PUBLISHED `AnimationId` (Open Cloud / KeyframeSequence upload).
- **Tool events:** `Equipped` (play idle), `Unequipped` (stop idle; also fires on death/drop/destroy),
  `Activated` (fire swing; does NOT fire if Ctrl is held), `Deactivated` (on release).
- **Custom Handle mesh persistence:** a Cube/EditableMesh Handle is TRANSIENT until uploaded —
  `AssetService:CreateAssetAsync(em, Enum.AssetType.Mesh)` persists it to a permanent AssetId (the existing
  `save_mesh` path; BETA, local-plugin only, ~30/min). Persist the Handle so it doesn't go blank/break in
  Play.
- **`Tool.Grip`** is one CFrame (GripUp/Right/Forward basis + GripPos offset) that adjusts the `RightGrip`
  weld IN PLACE — confirms #1's `grip_tool` is correct.

## 2. Settled decisions

- **Arm-only (joint-scoped) authoring** — the fix for "stiffens my whole body": the use/idle clips key ONLY
  a scoped joint set (default the right-arm chain: `RightShoulder`/`RightElbow`, optionally the `Waist` for
  a body twist), OMITTING legs/left-arm/head. So `add_keyframe`'s all-joints snapshot gains a **joint
  scope**.
- **Priorities:** idle = `Idle` (looping); use = `Action`.
- **Runtime = a LocalScript on the client** (player tools), using `Animator:LoadAnimation`.
- **Dev-loop no-publish; shipping-publish is a flagged follow-up.** v1 plays via `RegisterKeyframeSequence`
  (works in the in-Studio loop). A SHIPPED/multiplayer item needs published AnimationIds (Open Cloud) — OUT
  of v1, flagged as the next sub-project (needs a scoped API key).
- **Persist the Handle:** `save_mesh` the item's custom-mesh Handle so it survives Play (or the item breaks
  like the spike did).
- **Self-contained Tool:** the authored `KeyframeSequence`(s) are copied INTO the Tool (under `Anims/`); the
  runtime LocalScript registers + plays them.

## 3. Behavior

### 3a. Joint-scoped authoring (animation-engine change)
`add_keyframe` gains an optional **`scope`** (a joint-set preset — `"rightArm"` default for use-anims, or an
explicit joint-name list). When set, the snapshot includes Poses ONLY for those joints (+ the minimal
parent chain needed for the hierarchy), OMITTING the rest, so the resulting `KeyframeSequence` drives only
the scoped joints. The agent poses the arm (`ik_reach`/`pose_joint`) per keypose and `add_keyframe
{clip, scope:"rightArm"}`; `capture_animation` previews (the legs/body stay at rest in the filmstrip —
the arm-only proof). Two clips: `idle` (a held-ready arm pose, looped, `Idle` priority) and `use` (a swing,
`Action`).

### 3b. `bind_animation(tool, event, clip, rig?)`
- `tool` (required) — the `Tool` (from `make_tool`); `event` — `"idle"` (Equipped, looped, Idle) | `"use"`
  (Activated, Action); `clip` — an authored clip under `rig/AnimSaves`.
- Copies the clip's `KeyframeSequence` into `tool/Anims/<event>` (setting `Loop`/`Priority` per event);
  writes/refreshes the runtime **LocalScript** (`tool/ItemAnimRuntime`, idempotent) that on the client:
  `Tool.Equipped` → register+`Animator:LoadAnimation`+`Play` the idle (looped); `Tool.Unequipped` → stop;
  `Tool.Activated` → register+play the use clip once (`Action`, overrides idle on the arm joints). Returns a
  summary + a reminder to `save_mesh` the Handle + that shipping needs published AnimationIds.

### Verification boundary
Edit: I author (arm-only) + `capture_animation`-preview (legs stay put) + confirm the Tool carries the
clips + the LocalScript. Runtime (equip→idle, click→swing, arm-only, item swings): the USER playtests (the
bridge is edit-only). Shipping/multiplayer: needs the Open Cloud publish follow-up.

## 4. Architecture / modules

### Changed
- **`src/AnimationClip.luau`** — `snapshotKeyframe` (and `add_keyframe`'s call) gain a `scope` (joint-name
  set): build the Pose subtree for only those joints, omitting the rest. A pure `scopedJointSet(preset)`
  helper (preset→joint names; e.g. `rightArm` = the R15 right-arm Motor6D names) is unit-tested in
  `AnimationClipSpec`.
- **`src/Tools/Animate.luau`** — `add_keyframe` gains a `scope` input (default unset = all joints, current
  behavior; `"rightArm"`/`"upperBody"`/a list for use-anims).

### New
- **`src/Tools/ItemAnim.luau`** — the `bind_animation` descriptor + the runtime LocalScript template
  (a delimited Luau source string: Equipped/Unequipped/Activated handlers, `Animator:LoadAnimation`,
  `RegisterKeyframeSequence`, Idle/Action priority). Destructive; RELAY; parent-only.

### Changed (wiring)
- `Tools/init.luau` (require+append), `RelaySpec.luau` (`bind_animation`→EXPECTED_RELAY + `add_keyframe`
  unchanged classification), `SystemPrompt.luau` (extend "# Building handheld items": author ARM-ONLY idle
  + use clips, `bind_animation`, `save_mesh` the Handle, note shipping needs published anims).

### Reused
- `AnimationClip.register` (`RegisterKeyframeSequence`), the animation engine + `capture_animation`,
  `make_tool`/`grip_tool`/`save_mesh` (#1 + mesh persistence), `Path.resolve`, ChangeHistory + RELAY.

## 5. Error handling, limits, edge cases

- **Total:** every path pcall-wrapped → `(string, isError)`.
- **Scope:** an unknown `scope` preset → error listing presets; an empty scope → falls back to all-joints
  (current behavior) with a note.
- **Idle vs use priority:** the copied `KeyframeSequence` gets `Priority` set per event (Idle vs Action) so
  the use overrides the idle ON THE ARM only (legs unaffected).
- **Handle not persisted:** `bind_animation` warns if the Tool's Handle is a session mesh (`MeshId==""`) —
  it will break in Play; tell the agent to `save_mesh` first.
- **Runtime-only:** scripts run in a PLAYTEST; the edit `capture_animation` is the author-time check.
- **Multiplayer/ship:** `RegisterKeyframeSequence` is Studio-solo-only — flagged; publishing (Open Cloud) is
  the follow-up.

## 6. Testing & acceptance gate

- **Static/spec:** `stylua`/`selene` 0/0; `rojo build`; `RelaySpec` no-drift (covers `bind_animation`);
  `AnimationClipSpec` covers `scopedJointSet`.
- **Bridge dogfood:** build + `save_mesh` a sword item; author an arm-only `use` swing (`scope:"rightArm"`)
  + an `idle` → `capture_animation` → READ: the arm swings while **the legs/torso stay at rest** (the
  arm-only proof, the fix for the stiffening); `bind_animation` both → confirm `tool/Anims/idle`+`use` +
  the `ItemAnimRuntime` LocalScript reference them, idle Loop=true/Idle priority, use Action.
- **USER playtest (runtime gate):** equip → idle-hold; walk → legs animate while the arm holds; click → the
  swing fires on the arm only and the sword swings; the Handle is NOT blank (persisted). (Confirmed by the
  user, like the GREY-bug Play check.)

## 7. Scope & non-goals

**In (v1):** joint-scoped `add_keyframe` (+ `scopedJointSet` spec), `bind_animation` + the runtime
LocalScript, the `save_mesh`-the-Handle reminder/guard, RelaySpec + SystemPrompt, the dogfood + playtest.

**Out (deferred):**
- **Open Cloud animation publishing** (shipped/multiplayer real AnimationIds) — the flagged NEXT follow-up
  (needs a scoped API key); v1 is the in-Studio loop.
- **Combos / multiple swings / directional attacks** — one `use` clip in v1.
- **Hit detection / damage** (#4) and the **full behavior state machine** (#3).
- **Additive layering** beyond per-joint priority (not needed; per-joint priority is the supported path).

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). Plugin code change → `.\build.ps1` + USER restart.
Drive via `scripts/studio-agent.ps1` (ASCII Luau; Studio FOCUSED). Execute with
**superpowers:subagent-driven-development**. Commit per task; don't push. Verify by LOOKING (edit) + a USER
playtest (runtime).
