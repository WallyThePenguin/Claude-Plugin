# Studio Agent — Procedural surface textures (`paint_texture`) design (2026-06-23)

**Status:** approved in brainstorming, ready for an implementation plan.
**Goal:** Give the agent a curated tool to author CUSTOM procedural surface textures in Luau (brick, planks,
tile, checker, grunge) and apply them durably to a Part or MeshPart — so it can make greybox Parts and
custom meshes look CRAFTED without Cube or external assets. Fills the environment rubric's "surface
depth/relief" and "tileables" criteria — a direct quality-ceiling lever, building on the EditableImage +
`CreateAssetAsync(Image)` machinery verified this session.

## 1. Background (verified live this session — see memory `roblox-bridge-mesh-creation`)

EditableImage AUTHORING is callable from the bridge at PluginSecurity in edit, and the full author →
persist → apply chain is proven:
- **Create:** `AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })` → an EditableImage `Object`.
- **Draw:** `DrawRectangle(position, size, color, transparency, combineType)`, `DrawCircle`, `DrawLine`,
  `DrawImage`, `DrawImageTransformed`, `WritePixelsBuffer`, `ReadPixelsBuffer` are all present. Draws are
  pixel-accurate (verified via `ReadPixelsBuffer` ground truth: a drawn `[190,60,50,255]` reads back
  exactly) and colors render true (a pure-primary panel matched reference Parts). `combineType` =
  `Enum.ImageCombineType.Overwrite` for opaque fills.
- **Persist:** `AssetService:CreateAssetAsync(em, Enum.AssetType.Image, { Name = ... })` →
  `(Success, imageId)` (same "CreateAssetAsync Lua API" beta flag as the mesh path).
- **Apply:** `Decal.TextureContent` / `Texture.TextureContent` (Texture is a Decal subclass) and
  `MeshPart.TextureContent` are all WRITABLE; `Content.fromUri("rbxassetid://"..imageId)` applies a durable
  texture, `Content.fromObject(em)` applies an in-session one.

## 2. Settled decisions (from brainstorming)

- **Persistence = persist at paint time.** `paint_texture` uploads the authored texture to an owned Image
  asset immediately and applies the durable `rbxassetid` — so a painted texture ALWAYS survives Play (no
  separate step, no risk of re-introducing the GREY bug). Cost: one `CreateAssetAsync` upload per paint
  (30/min cap; procedural textures moderate in seconds). `save_mesh` is NOT touched. (Alternatives —
  in-session + extend save_mesh, or MeshParts-only — were rejected; this one is self-contained and always
  durable.)
- **Curated, extensible kinds** (like `author_mesh`'s `KINDS` table): v1 = `bricks`, `planks`, `tiles`,
  `checker`, `noise`. Each is *tileable* (patterns wrap at the tile edge) and parametric.
- **Two-color params** (`primary`/`secondary`, per-kind meaning + defaults) keep the input schema simple;
  all five kinds are two-color.
- **Apply:** a **Part** → a tiling `Texture` on all six faces (`scale` → `StudsPerTileU/V`, reads as a
  material); a **MeshPart** → `TextureContent`. Re-painting REPLACES (clears prior agent Textures / overwrites
  TextureContent), it does not stack.

## 3. Behavior

### `paint_texture(kind, target?, scale?, primary?, secondary?)`

- `kind` (string, required) — `bricks` | `planks` | `tiles` | `checker` | `noise`.
- `target` (string, optional) — instance path to a BasePart; default the current Selection's first BasePart.
- `scale` (number, optional) — StudsPerTile for the Part tiling (default `4`); ignored for a MeshPart
  (TextureContent maps to the mesh UVs).
- `primary`/`secondary` (`{r,g,b}` 0-255, optional) — the two colors, per-kind meaning: bricks =
  brick/mortar, planks = plank/seam, tiles = tile/grout, checker = colorA/colorB, noise = base/speckle.
  Each defaults to a sensible value when omitted.

Flow: `TextureFactory.authorImage(kind, params)` builds a 256×256 EditableImage from the kind's pure
pattern → `TextureFactory.persistImage(em, name)` uploads it (`CreateAssetAsync(Image)`) → durable
`imageId` → `TextureFactory.applyTexture(target, imageId, scale)` applies it (Part: tiling Textures on the
six faces; MeshPart: `TextureContent`). The upload yields, so it happens BEFORE the ChangeHistory recording;
the apply (instance creation/edits) runs inside the recording so it is undoable. Returns
`(summary, isError)`: e.g. `"paint_texture OK: 'bricks' on Workspace.Wall (image rbxassetid://N; Texture x6
@ StudsPerTile=4). Survives Play."`.

Failure handling (total — pcall-wrapped, never throws): unknown kind → error listing valid kinds; no
BasePart target → error; an author/upload/apply failure → a clear `(errmsg, isError=true)` (e.g. the upload
error names the beta-flag dependency). A pending-moderation image still applies (the durable reference
renders once moderated — seconds), so it is reported success.

## 4. Architecture / modules

### New
- **`src/TextureFactory.luau`** — the engine, one responsibility (params → an applied durable texture):
  - PURE (unit-tested): a draw-op type `DrawOp = { pos: Vector2, size: Vector2, color: Color3 }` and one
    generator per kind returning a tileable `{ DrawOp }` list (a background fill first, then the pattern
    rects):
    - `checkerPattern(tile, cols, a, b)` — 1 bg(a) + the b cells of a `cols×cols` checker.
    - `bricksPattern(tile, rows, brick, mortar)` — 1 bg(mortar) + inset brick rects in running-bond rows
      (alternating half-brick horizontal offset per row, wrapping at the tile edge).
    - `planksPattern(tile, count, plank, seam)` — 1 bg(seam) + `count` vertical plank rects with seam gaps,
      each plank's color slightly varied deterministically (a pure `prand(seed, i)` like MeshFactory).
    - `tilesPattern(tile, cols, tileColor, grout)` — 1 bg(grout) + `cols×cols` tile rects inset by a grout gap.
    - `noisePattern(tile, cells, base, speckle, seed)` — 1 bg(base) + `cells` small speckle rects at
      deterministic `prand` positions (a fixed default seed → deterministic output).
  - IMPURE (live-verified): `authorImage(kind, params) -> EditableImage` (CreateEditableImage + draw each op
    via `DrawRectangle(op.pos, op.size, op.color, 0, Enum.ImageCombineType.Overwrite)`); `persistImage(em,
    name) -> (number?, string?)` (`CreateAssetAsync(Image)` → id or err); `applyTexture(target, imageId,
    scale) -> string` (MeshPart → set `TextureContent`; Part → clear existing Texture children, then add a
    tiling `Texture` per `Enum.NormalId` face with `StudsPerTileU/V = scale` and `TextureContent =
    Content.fromUri`; returns a mode descriptor).
- **`src/TextureFactorySpec.luau`** — in-Studio spec for the PURE generators (rect counts, the bg-first
  invariant, key cell positions, brick row-offset alternation, noise determinism by seed). Mirrors
  `MeshFactorySpec`.
- **`src/Tools/Texture.luau`** — the `paint_texture` descriptor: validate input, resolve the BasePart
  target, parse colors + per-kind defaults, call `TextureFactory`, ChangeHistory-record the apply,
  pcall-wrap, return `(summary, isError)`. Exports `descriptors`. (A new file keeps `Tools/Mesh.luau`
  focused.)

### Changed
- **`src/Tools/init.luau`** — `require(script.Texture)` + append `TextureTool.descriptors`.
- **`src/RelaySpec.luau`** — add `paint_texture` to `EXPECTED_RELAY` (DataModel + AssetService write → relays
  by default; not LOCAL). Keeps the no-drift guard green.
- **`src/SystemPrompt.luau`** — extend the "# Building with custom meshes" section: `paint_texture(kind,
  target)` paints crafted surfaces (brick/planks/tile/checker/grunge) beyond flat built-in materials;
  persists immediately so it survives Play; a tool-index one-liner.

### Reused
- `AssetService` + the `Content` global (verified callable from the bridge), the descriptor registry, the
  RELAY default, the ChangeHistory-recorded-apply pattern from `Tools/Mesh.luau`'s `placeRecorded`, the
  `{r,g,b}` color parsing + `{x,y,z}`-style param patterns.

## 5. Error handling, limits, edge cases

- **Total:** every tool path is pcall-wrapped → `(string, isError)`; never throws.
- **Rate / budget:** one `CreateAssetAsync` per paint (30/min). Acceptable for human-paced iteration;
  procedural textures moderate in seconds. No batching (YAGNI).
- **Re-paint:** applying to a Part clears existing Texture children first (replace, not stack); a MeshPart
  overwrites `TextureContent`. Idempotent-ish: a re-paint with the same params produces an equivalent result
  (a new asset id — acceptable; dedup is out of scope).
- **Tiling vs UV:** `scale` (StudsPerTile) only affects a Part's tiling Textures; a MeshPart's
  `TextureContent` maps to its UVs and ignores `scale` (noted in the tool description).
- **Moderation:** a pending image applies the durable reference and renders once moderated — reported
  success (no "pending, re-run" dance; unlike a mesh swap there is nothing to load back synchronously).
- **Non-BasePart / GUI targets:** out of scope — the tool errors on a non-BasePart target.

## 6. Testing & acceptance gate

- **Static, each task:** `stylua src` ; `selene src` (0/0) ; `rojo build default.project.json --output StudioAgent.rbxm` ;
  `RelaySpec` no-drift green (now covering `paint_texture`).
- **`TextureFactorySpec` green** — via the bridge
  (`luau 'return tostring(require(script.Parent.TextureFactorySpec).run())'`) after the build + USER restart.
- **Bridge dogfood (verify by LOOKING, not coordinates):**
  1. Build a wall Part; `paint_texture {kind:"bricks", target:"<wall>"}` → capture → READ: a recognizable
     brick surface (offset rows, mortar lines).
  2. Repeat for `planks`, `tiles`, `checker`, `noise` on parts → capture each → READ: each reads as the
     intended crafted surface (no garbage).
  3. `paint_texture {kind:"tiles", target:"<a MeshPart>"}` → capture → READ: the mesh shows the tile texture
     (TextureContent path).
  4. Confirm durability: the applied Texture/`TextureContent` references a `rbxassetid://…` (not an in-session
     Object) — so it survives Play; spot-check via the bridge that re-painting a Part REPLACES (no stacked
     Textures).

## 7. Scope & non-goals

**In (v1):** `paint_texture` (5 kinds), `TextureFactory` (+ spec), the `Tools/Texture.luau` descriptor,
RelaySpec classification, the SystemPrompt note, the bridge dogfood.

**Out (deferred, stated honestly):**
- **Text / glyph rendering** (signs, labels) — EditableImage has no font rasterizer; needs DrawImage glyph
  atlases. Separate feature.
- **Per-face targeting** — v1 textures all six faces of a Part; a `faces` param can come later.
- **Normal / roughness / PBR maps** (SurfaceAppearance) — `SurfaceAppearance.ColorMap` isn't writable at
  PluginSecurity, and Cube emits only a color texture; a SurfaceAppearance path is a separate investigation.
- **Decal-style stretched graphics** (one image fit to a face) — v1 is tiling materials; a stretch mode can
  come later.
- **More kinds** (cobblestone, fabric, metal-panel, hex-tile, …) — the generator table is extensible.

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). A plugin code change needs `.\build.ps1` + a USER
Studio restart. The **"CreateAssetAsync Lua API"** beta flag must stay ON. Drive the dogfood via
`scripts/studio-agent.ps1` (keep bridge Luau ASCII-only). Execute with
**superpowers:subagent-driven-development** (fresh implementer + spec + code-quality review per task).
Commit per task; don't push. Verify by LOOKING at captures.
