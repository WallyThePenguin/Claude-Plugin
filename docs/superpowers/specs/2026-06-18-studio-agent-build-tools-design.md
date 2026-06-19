# Studio Agent — Build-Quality Tools (destroy_instance + place_relative) — Design

**Date:** 2026-06-18
**Status:** Approved design (pending spec review) → implementation plan next.
**Motivation:** Two concrete failures from the live obby session (handoff §3): the agent could not
delete instances during a playtest (it flailed, reparenting old builds into ServerStorage), and it
repeatedly inverted `LookVector`'s sign trying to place a ball "in front of" the player.

## 1. Summary

Add two small main-agent tools that mirror the existing `create_instance` / `set_property` plumbing:

- **`destroy_instance`** — delete the instance at a path via `Instance:Destroy()` (works in edit AND
  playtest, no loadstring), with a safety guard against deleting `game`/top-level services.
- **`place_relative`** — position an existing instance relative to an anchor instance by a named,
  **anchor-local** direction + distance, so the agent never hand-computes facing/CFrame math.

## 2. Components

Two new `Tools/` submodules, each exporting a `descriptors` list that `init.luau`'s existing concat
loop registers (no dispatch change). Both reuse: `Path.resolve`/`Path.fullPath`, `RegionGuard.check`
(parallel-writer confinement; no-op for the serial parent), an edit-mode `ChangeHistoryService`
recording (direct apply in playtest), `Serialize`/JSON `{ok=...}` result contract, `destructive=true`
(the M11 confirm gate).

- **`src/Tools/Destroy.luau`** — `destroy_instance`.
- **`src/Tools/Place.luau`** — `place_relative` (+ a pure `offsetPoint` helper for the math).
- **`src/PlaceSpec.luau`** — in-Studio unit test for the pure offset math.
- Modified: `src/Tools/init.luau` (require + append + registry comment), `src/RelaySpec.luau`
  (`EXPECTED_RELAY` += both — DataModel-mutating, so they relay in client-view play; keeps the
  "no drift" test green), `src/SystemPrompt.luau` (tool list + a placement-guidance line).

Subagent/writer allowlists are unchanged — these are main-agent tools.

## 3. `destroy_instance`

- **Input:** `{ path: string }` (single; the agent loops for several — the confirm gate then fires
  per deletion).
- **Flow:** `Path.resolve(path)` → safety guard → `RegionGuard.check(target, context)` → capture
  `path`+`class` → in edit, `TryBeginRecording("Destroy <class>")` then `target:Destroy()` then
  `FinishRecording(Commit)` (undoable); in playtest, `target:Destroy()` directly.
- **Safety guard (refuse with `{ok=false,error}`):** the target is `game`; the target is a top-level
  service (`target.Parent == game`); or the target is already orphaned (`target.Parent == nil` and not
  `game`). This lets the agent delete its builds but not nuke Workspace/Players/etc.
- **Result:** `{ok=true, destroyed=<path>, class=<className>}`. `destructive=true`.

## 4. `place_relative`

- **Input:** `{ target: string, anchor: string, direction: string, distance: number }` where
  `direction ∈ {front, back, left, right, up, down}`.
- **Anchor CFrame:** `BasePart` → `.CFrame`; `Model` → `:GetPivot()`; otherwise
  `{ok=false,error="anchor has no position"}`.
- **Pure math (`offsetPoint(anchorCFrame, direction, distance) → Vector3`):** anchor-local unit
  vectors — `front=(0,0,-1)`, `back=(0,0,1)`, `right=(1,0,0)`, `left=(-1,0,0)`, `up=(0,1,0)`,
  `down=(0,-1,0)`; `point = (anchorCFrame * CFrame.new(unit * distance)).Position`. Distance is
  measured from the anchor's center.
- **Apply (position-only — keep target's rotation):** `BasePart` target → set `.Position = point`;
  `Model` target → `:PivotTo(CFrame.new(point) * target:GetPivot().Rotation)`; otherwise
  `{ok=false,error="target cannot be positioned"}`. `RegionGuard.check(target, context)`; undoable in
  edit, direct in playtest.
- **Result:** `{ok=true, target=<path>, position=<serialized Vector3>}`. `destructive=true`.

## 5. Error handling

Same `{ok=false, error}` + `isError=true` contract as the sibling tools: bad/missing args; path not
found; region-guard rejection; anchor/target not spatial; invalid `direction`; non-positive/NaN
`distance`; could-not-begin-recording. `place_relative` never partially applies (one CFrame/Position
write). `destroy_instance`'s guard runs before any recording.

## 6. Testing

- **`PlaceSpec.luau`** (pure, in-Studio; mirrors `CaptureSpec`): `offsetPoint` for each direction
  against an axis-aligned anchor AND a **yaw-rotated** anchor (e.g. anchor turned 90° → "front" points
  along world ±X, proving anchor-local correctness — the exact bug); distance scaling; bad direction
  returns nil/error.
- **`RelaySpec`** stays green (no-drift covers the two new names once added to `EXPECTED_RELAY`).
- **Live-verify** (fresh Baseplate): rotate an anchor part 90°, `create_instance` a small part,
  `place_relative` it `front`/`distance=8` of the anchor → confirm it lands in the direction the anchor
  faces (not world −Z); `destroy_instance` it → confirm gone + Ctrl+Z restores it; `destroy_instance`
  on `game.Workspace` → confirm the guard refuses.

## 7. Out of scope (YAGNI)

Batch destroy; an optional `face`/orient flag on `place_relative`; edge-aware spacing (half-size
offsets); adding these to the writer/subagent allowlists. Each a later follow-up if needed.
