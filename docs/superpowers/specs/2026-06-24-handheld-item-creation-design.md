# Studio Agent — Handheld item creation (`make_tool` + `grip_tool`) design (2026-06-24)

**Status:** approved in brainstorming, ready for an implementation plan.
**Goal:** Let the agent turn a built visual (a Part/Model made with `generate_mesh`/`author_mesh`/
`paint_texture`/primitives) into an equippable Roblox `Tool` that sits correctly in a character's hand —
the FOUNDATION of "full-fledged interactive items." The item's *look* is built with existing tools; this
makes it *held* and fits the grip via the build→capture→refine loop. This is sub-project #1 of the
interactive-items roadmap (→ #2 use-animations → #3 behavior state machine → #4 hit detection → #5 PvE NPCs).

## 1. Background (verified live this session via the bridge, edit context)

- **Edit-mode equip welds.** Parenting a `Tool` (with a child BasePart named `Handle`) to an R15 rig
  (Humanoid + `RightHand` + `RightHand.RightGripAttachment`) AUTO-creates the `RightGrip` `Weld`
  (Part0=RightHand, Part1=Handle) and snaps the Handle to the hand — verified: a probe Tool welded and the
  Handle sat 0.077 studs from the hand. So real equip works in EDIT (no manual welding needed for the
  preview loop).
- **`Tool.Grip` is live + iterable.** Setting `Tool.Grip` to a new CFrame after equip RE-positions the
  Handle without re-equipping (verified: a `(0,0,2)` grip moved the Handle 2.00 studs, still welded, 1.95
  from the hand). So the grip is fit by setting `Tool.Grip` + capturing + adjusting — the project's core
  loop. (`Tool.Grip` = the CFrame placing the Handle relative to the hand's grip attachment; identity puts
  the Handle CENTER in the palm.)

**Key reframe:** Roblox auto-equips and the grip is a single live CFrame, so #1 is not novel-API risk — it
is *curation*: a reliable toolify step + an intuitive, capture-iterated grip-fit (raw `Tool.Grip` CFrames
are exactly what the agent fumbles).

## 2. Settled decisions (from brainstorming)

- **Two tools** (single responsibility): `make_tool` (structure: build the Tool/Handle/welds) +
  `grip_tool` (fit: equip on a rig, set the grip from intuitive params, capture). Cleaner than one combined
  call.
- **Grip via intuitive params** — `offset {x,y,z}` (studs) + `rot {rx,ry,rz}` (degrees) → a Grip CFrame —
  NOT a raw CFrame the agent hand-builds. Iterated by LOOKING at the capture.
- **Visual built first, separately.** `make_tool` toolifies an EXISTING built Part/Model; it does not
  generate the item (compose with `generate_mesh`/`author_mesh`/`paint_texture`/primitives).
- **Rig is resolved, not owned.** `grip_tool` uses a provided rig, else the first workspace Humanoid rig;
  if none, it errors telling the agent to `spawn_rig` first (keeps `ToolFactory` decoupled from the Rig
  tool).

## 3. Behavior

### `make_tool(target, name?, handle?)`
- `target` (string, required) — path to the built Part or Model (the item's visual).
- `name` (string, optional) — the Tool's name (default the target's name, else "Item").
- `handle` (string, optional) — path/name of the part to use as the Handle (for a multi-part Model). If
  omitted: a single-Part target IS the Handle; a Model uses its `PrimaryPart`, else its first BasePart.

Behavior: collect the target's BaseParts (the Part itself, or all BaseParts under a Model). Resolve the
Handle part. Create a `Tool` (named); **unanchor every part**; rename the Handle part to `Handle` and parent
it to the Tool; **`WeldConstraint`** every other part to the Handle (Part0=Handle, Part1=part — preserves
their built relative positions) and parent them to the Tool; set `RequiresHandle=true`, `CanBeDropped=true`.
Parent the Tool to `workspace` (a placed, equippable item). Returns a summary: Tool path, Handle name, part
count. (If the target was a Model, its now-empty wrapper is destroyed; a single-Part target simply becomes
the Handle.)

Failure (total, pcall-wrapped): no target / no BaseParts under it / a named `handle` that isn't a BasePart
under the target → a clear `(string, isError=true)`.

### `grip_tool(tool, rig?, offset?, rot?)`
- `tool` (string, required) — path to the `Tool` (from `make_tool`).
- `rig` (string, optional) — path to a Humanoid rig; default the first workspace rig with a Humanoid +
  `RightHand`; if none → error ("spawn a rig first with spawn_rig").
- `offset` (`{x,y,z}`, optional, default `{0,0,0}`) — grip translation in studs.
- `rot` (`{rx,ry,rz}`, optional, default `{0,0,0}`) — grip rotation in degrees.

Behavior: resolve the Tool + rig; **equip** (parent the Tool to the rig → auto-weld); set
`Tool.Grip = ToolFactory.gripCFrame(offset, rot)` (live-repositions the Handle); frame the camera on the
held item (reuse `CaptureCore`) and **capture** → return the image so the agent SEES the grip. The agent
re-calls with adjusted `offset`/`rot` until the item sits right. Returns the framed image (a tool_result
image block, like `camera_focus`); requires the vision sidecar (degrades with a clear message if absent).

Failure (total): tool not a `Tool` / no Handle / no rig → clear error. Capture failure → the grip is still
applied; report the capture error (don't fail the grip).

## 4. Architecture / modules

### New
- **`src/ToolFactory.luau`** — the engine, one responsibility (parts → a held, gripped Tool):
  - PURE (unit-tested): `gripCFrame(offset: {x,y,z}?, rot: {rx,ry,rz}?) -> CFrame` =
    `CFrame.new(ox,oy,oz) * CFrame.Angles(rad(rx), rad(ry), rad(rz))`; missing fields default to 0.
  - IMPURE (live-verified): `toolify(target, handleHint, toolName) -> (Tool?, string?)` (collect parts,
    resolve Handle, unanchor + rename + WeldConstraint + assemble the Tool); `resolveRig(rigPath) ->
    (Model?, string?)` (path, else first Humanoid+RightHand rig); `equip(tool, rig)` (parent → auto-weld);
    `applyGrip(tool, grip)` (`tool.Grip = grip`).
- **`src/ToolFactorySpec.luau`** — in-Studio spec for `gripCFrame` (offset → position; a rotation applied;
  identity default). Mirrors `MeshFactorySpec`/`TextureFactorySpec`.
- **`src/Tools/Item.luau`** — the `make_tool` + `grip_tool` descriptors: validate input, call `ToolFactory`,
  ChangeHistory-record the structural edit, pcall-wrap; `grip_tool` returns the captured image via
  `CaptureCore`. Exports `descriptors`.

### Changed
- **`src/Tools/init.luau`** — `require(script.Item)` + append `ItemTool.descriptors`; add `make_tool`,
  `grip_tool` to the registry comment list.
- **`src/RelaySpec.luau`** — add `make_tool` + `grip_tool` to `EXPECTED_RELAY` (DataModel writes → relay by
  default; not LOCAL). Keeps the no-drift guard green.
- **`src/SystemPrompt.luau`** — a "# Building handheld items" note (build the visual with the mesh/texture
  tools → `make_tool` → `grip_tool` and ITERATE the grip by looking; an item is for the player to hold/use)
  + tool-index lines.

### Reused
- `WeldConstraint`/`Tool`/`Humanoid` (verified callable), `CaptureCore` (the framing + sidecar capture used
  by `camera_focus`), `Path.resolve`, the descriptor registry, the ChangeHistory-recorded-edit + RELAY
  patterns, the `{x,y,z}` param parsing.

## 5. Error handling, limits, edge cases

- **Total:** every tool path is pcall-wrapped → `(content, isError)`; never throws.
- **Anchored parts:** the built mesh/parts are Anchored; `toolify` unanchors them (a Tool's parts must be
  unanchored to weld + move with the hand). The WeldConstraints keep the assembly rigid.
- **Handle ambiguity:** a multi-part Model with no `handle` hint + no `PrimaryPart` falls back to the first
  BasePart (deterministic); the agent can re-run with an explicit `handle`.
- **Grip iteration:** `Tool.Grip` is live; re-running `grip_tool` with new `offset`/`rot` updates in place
  (no re-equip artifacts). Identity grip = Handle center in the palm (the starting point).
- **Rig reuse:** `grip_tool` equips on whatever rig it resolves; equipping a second Tool would stack — the
  agent unequips/destroys a prior preview Tool or uses a fresh rig (documented; not auto-managed in v1).
- **Capture:** needs the sidecar + a focused Studio (same constraint as `capture`); a capture failure still
  leaves the grip applied.

## 6. Testing & acceptance gate

- **Static, each task:** `stylua src` ; `selene src` (0/0) ; `rojo build default.project.json --output StudioAgent.rbxm` ;
  `RelaySpec` no-drift green (now covering `make_tool` + `grip_tool`).
- **`ToolFactorySpec` green** — via the bridge after the build + USER restart.
- **Bridge dogfood (verify by LOOKING):**
  1. Build a simple SWORD visual (a blade + a crossguard + a grip, from primitives or a generated mesh; a
     `paint_texture` metal/wood look optional).
  2. `make_tool {target:"<sword>", name:"Sword"}` → a `Tool` with a `Handle`, parts unanchored + welded.
  3. `spawn_rig`, then `grip_tool {tool:"Workspace.Sword", rig:"<rig>"}` → READ the capture: the rig holds
     the sword. Adjust `offset`/`rot` and re-call until the blade points OUT of the fist (grip near the
     hilt) — proving the capture-iterated grip-fit.
  4. Confirm the `RightGrip` weld exists and `Tool.Grip` reflects the final params (structural check).

## 7. Scope & non-goals

**In (v1):** `make_tool`, `grip_tool`, `ToolFactory` (+ spec), the SystemPrompt note, RelaySpec
classification, the bridge dogfood.

**Out (deferred — later roadmap sub-projects, stated honestly):**
- **Use-animations / the mesh⇄animation merge** (#2) — equip/activate-bound character animations.
- **Item behavior state machine** (#3) — equip→idle→activate→cooldown logic.
- **Hit detection / object interactions** (#4) and **PvE NPCs** (#5).
- **Auto-computed grip** — we iterate via capture instead (a heuristic grip from item geometry is unreliable
  across shapes; YAGNI unless the iteration proves slow).
- **Shipping deploy** — placing the finished Tool in `StarterPack`/a player's `Backpack` is a one-liner the
  agent can do with `run_luau`/`set_property`; a dedicated step can come with #3.
- **Multi-Tool preview management** on one rig (auto-unequip prior previews).

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). A plugin code change needs `.\build.ps1` + a USER
Studio restart. Drive the dogfood via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only; Studio
FOCUSED for captures). Execute with **superpowers:subagent-driven-development** (fresh implementer + spec +
code-quality review per task). Commit per task; don't push. Verify by LOOKING at captures.
