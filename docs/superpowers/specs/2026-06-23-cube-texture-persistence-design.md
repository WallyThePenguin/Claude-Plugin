# Studio Agent — Cube texture persistence in `save_mesh` design (2026-06-23)

**Status:** approved in brainstorming, ready for an implementation plan.
**Goal:** Make `save_mesh` persist a Cube-generated mesh's TEXTURE alongside its geometry, so a generated
prop survives Play / save / ship **fully textured**. Today `save_mesh` persists mesh GEOMETRY only — a
Cube barrel keeps Color/Material but its wood texture comes back GREY in a playtest (verified live). This
closes that gap, completing the persistence story for generated meshes.

## 1. Background (verified live this session — see memory `roblox-bridge-mesh-creation`)

A Cube `GenerateModelAsync` MeshPart carries its texture in **`MeshPart.TextureContent`** — a `Content`
whose `SourceType == Enum.ContentSourceType.Opaque` while session-backed (an opaque engine handle, exactly
like `MeshContent`). It is **NOT** a `SurfaceAppearance` child and **NOT** `TextureID` (the earlier
"separate SurfaceAppearance layer" framing in the handoff/memory was wrong — corrected this session).

All three persistence primitives were proven live via the dev bridge (PluginSecurity, edit context):
- **Extract:** `AssetService:CreateEditableImageAsync(mp.TextureContent)` → a real EditableImage (proven:
  1024×1024 off a Cube barrel; EditableImage is an `Object`, like EditableMesh).
- **Upload:** `AssetService:CreateAssetAsync(em, Enum.AssetType.Image, { Name = ... })` →
  `(Enum.CreateAssetResult.Success, imageId)` (proven: returned a real id `85093583335233`). Needs the
  same **"CreateAssetAsync Lua API"** Studio beta flag as the mesh path.
- **Repoint:** `mp.TextureContent` is **WRITABLE** (unlike `MeshContent`) — `mp.TextureContent =
  Content.fromUri("rbxassetid://"..imageId)` flips `SourceType` to `Uri`. So NO part-swap is needed for the
  texture. (`TextureID` is also writable; `SurfaceAppearance.ColorMap` is NOT writable at PluginSecurity =
  a dead end and unneeded.)
- **End-to-end:** a repointed barrel RENDERS its wood texture from the durable asset (the image moderated
  within seconds — visually confirmed in a capture).

**Interaction with the existing swap:** `save_mesh` SWAPS the geometry part (because `MeshContent` is not
writable) — it builds a fresh durable MeshPart `d` from the uploaded mesh asset. A fresh mesh-asset part
has `TextureContent.SourceType == None` (geometry-only) — **so the swap is exactly what drops the texture
(the GREY bug).** The durable `d` accepts `d.TextureContent = Content.fromUri(...)` (writable), so the fix
is to extract the texture from the ORIGINAL `mp` (before it is destroyed) and reattach it on `d`.

## 2. Settled decisions (from brainstorming)

- **Trigger = fold into `save_mesh` automatically (no new tool, no flag).** `save_mesh`'s contract is
  "make this build survive Play"; a half-persisted grey mesh is a footgun, so texture persistence belongs
  INSIDE that contract. A `persistTextures` flag was rejected as YAGNI — the rate-budget concern is
  speculative (Cube props are a handful per scene; `CreateAssetAsync` is 30/min), add it later only if
  proven. No `save_mesh` tool-surface change.
- **Degrade gracefully:** a texture-step failure still persists the GEOMETRY (same as today) and is
  reported — the feature never makes a build worse than the current behavior.
- **Texture classification by `SourceType`:** `Opaque` → persist (session texture); `Uri` → already
  durable, carry the reference across the swap; `None` → no texture (procedural `author_mesh` pine/rock,
  or a fresh asset part), skip.

## 3. Behavior (control flow inside `MeshFactory.persistMeshPart`)

Additions to the existing flow are in **bold**; the geometry path is unchanged.

1. Extract the mesh EditableMesh from `mp.MeshContent` *(existing)*.
2. **Classify the texture from `mp.TextureContent.SourceType` (pure): `Opaque`→`"persist"`,
   `Uri`→`"carry"`, `None`→`"none"`.**
3. Upload the mesh → `meshAssetId` *(existing)*.
4. Build the durable part `d` via `CreateMeshPartAsync(Content.fromUri(meshAssetId))` *(existing)*. **If
   this load fails (the mesh asset is pending moderation), return early `{ meshAssetId, swapped=false,
   texture=nil }` as today — there is no `d` to attach a texture to, so the texture is deferred too; the
   next `save_mesh` run (after the mesh moderates) persists both.**
5. **Texture step — only when `d` exists (the success branch); whole step pcall-wrapped:**
   - `"persist"`: `em = CreateEditableImageAsync(mp.TextureContent)` (read from the ORIGINAL `mp`, which is
     still alive) → `CreateAssetAsync(em, Enum.AssetType.Image, { Name = name.."_tex" })` → `imageId`;
     then `d.TextureContent = Content.fromUri("rbxassetid://"..imageId)`. Record `{ imageId = imageId }`.
   - `"carry"`: `d.TextureContent = mp.TextureContent` (copy the already-durable reference; no upload).
     Record `{ imageId = <the carried id, parsed from the Uri if available, else nil> }`.
   - `"none"`: no texture record (leave `d` textureless — correct for procedural/plain meshes).
   - On any failure inside this step: leave `d` textureless (geometry already persisted) and record
     `{ err = <message> }`.
6. Copy properties, reparent children, `mp:Destroy()` *(existing)* — runs AFTER the texture extract in
   step 5 so `mp.TextureContent` is read while `mp` is still alive.

**Moderation:** the repoint sets a durable *reference* that renders once the image moderates; it does NOT
synchronously load the image back, so a pending image shows grey briefly then resolves on its own — no
"pending, re-run" dance for textures (unlike the mesh swap, which must load the mesh back synchronously).
The texture step is reported as success once the durable reference is set.

## 4. Architecture / modules

### Changed
- **`src/MeshFactory.luau`**
  - **PURE (new, unit-tested): `classifyTexture(sourceType: Enum.ContentSourceType) -> "persist"|"carry"|"none"`**
    — the texture decision, mirroring the existing pure geometry helpers. Total: any unexpected value →
    `"none"` (safe skip).
  - **`persistMeshPart` return refactor:** today `(number?, boolean, string?)` =
    `(meshAssetId?, swapped, err)`. Refactor to a result **table**
    `{ meshAssetId: number?, swapped: boolean, err: string?, texture: TextureResult? }`, where
    `TextureResult = { imageId: number?, err: string? }` and `texture` is `nil` when the part had no
    texture (classification `"none"`). Cleaner than five positional returns and lets `runSave` tally
    textures. (Type export `MeshFactory.PersistResult` / `MeshFactory.TextureResult`.)
  - **`persistMeshPart` body:** insert the texture step per §3. The geometry extract/upload/swap and the
    property/children copy are unchanged — but **every existing early return adopts the new table shape**
    (geometry-extract fail, CreateAssetAsync fail, non-Success result, pending-moderation load fail, and
    the success return), each with `texture = nil` except the success branch.

- **`src/MeshFactorySpec.luau`** — add `classifyTexture` cases: `Opaque`→`"persist"`, `Uri`→`"carry"`,
  `None`→`"none"`, plus an unexpected-value→`"none"` total-coverage case. Mirrors the existing pure-helper
  specs (`coneGeometry`/`scaleFactorForHeight`/`rockClusterLayout`).

- **`src/Tools/Mesh.luau`** (`runSave`) — adapt to the new result table: replace the
  `(assetId, didSwap, err)` destructure with the table; keep the existing swapped/pending/failed mesh
  tally; **add a texture tally** `texPersisted` / `texFailed` (from each result's `texture` field) and
  append to the summary, e.g. *"…; N texture(s) persisted"* and, if any failed,
  *"— M texture(s) FAILED (firstTexErr)"*. The mesh `assetId ~= nil` / `didSwap` logic maps to
  `result.meshAssetId` / `result.swapped`.

### Reused
- `AssetService` + the `Content` global (verified callable from the bridge), the existing
  ChangeHistory-wrapped `doPersist` loop in `runSave`, the `collectSessionMeshParts` collector, the RELAY
  classification of `save_mesh` (unchanged — still a DataModel/AssetService write).

### Unchanged (no edits needed)
- `src/Relay.luau` / `src/RelaySpec.luau` — `save_mesh` is already classified RELAY; no new tool.
- `src/SystemPrompt.luau` — the `save_mesh` guidance ("persist finished builds so they survive Play")
  already covers the intent; texture persistence is now simply part of what `save_mesh` does. **Optional
  one-line clarification** that `save_mesh` now also persists generated textures — include it so the model
  knows the grey-in-play caveat is resolved.

## 5. Error handling, limits, edge cases

- **Total:** the texture step is fully pcall-wrapped and never throws; a failure degrades to
  geometry-only persistence with a reported `texture.err`. `runSave` stays total (returns `(string, isError)`).
- **No-texture parts** (procedural `author_mesh`, plain Parts that aren't even MeshParts) → classification
  `"none"`, no upload, no record — zero extra asset cost.
- **Idempotency:** a re-run of `save_mesh` on an already-saved mesh sees `MeshId ~= ""` and is skipped by
  `collectSessionMeshParts` entirely (the existing geometry idempotency). Within a single persist, a
  `"carry"` texture (already a `Uri`) is copied, not re-uploaded.
- **Rate / budget:** each textured mesh now uploads 2 assets (mesh + image). `CreateAssetAsync` is 30/min;
  realistic scenes (a handful of Cube props) stay well under. No batching in v1 (YAGNI).
- **Asset naming:** the image asset is named `<part>_<i>_tex` to sit beside the mesh's `<part>_<i>`.

## 6. Testing & acceptance gate

- **Static, each task:** `stylua src` ; `selene src` (0/0) ; `rojo build default.project.json --output StudioAgent.rbxm` ;
  `RelaySpec` no-drift green (unchanged classification — confirms no regression).
- **`MeshFactorySpec` green** — runnable via the bridge
  (`luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'`) after the plugin build + USER
  restart that loads the change. The new `classifyTexture` cases must pass.
- **Bridge dogfood (verify by LOOKING, not coordinates):**
  1. `generate_mesh {prompt:"a wooden barrel"}` → a fresh session barrel (texture in `TextureContent`,
     `SourceType==Opaque`).
  2. `save_mesh` on it → the summary reports `1/1 durable` **and** `1 texture persisted` with an image
     asset id; the swapped part's `MeshId` is `rbxassetid://…` and its `TextureContent.SourceType == Uri`.
  3. **PLAY (or re-capture the durable part):** the barrel RENDERS textured, not grey — the GREY bug is
     fixed end-to-end (the geometry fix was confirmed in Play last session; confirm the texture the same
     way).
  4. `author_mesh {kind:"pine"}` → `save_mesh` → the pine persists with **no** texture record (classification
     `"none"`), proving the no-texture path is a clean skip (no spurious image upload).

## 7. Scope & non-goals

**In (this change):** `MeshFactory.classifyTexture` (+ spec), the `persistMeshPart` texture step + result-
table refactor, the `runSave` texture tally, an optional SystemPrompt one-liner, the bridge dogfood.

**Out (deferred, stated honestly):**
- **`persistTextures` flag / upload batching** — only if a large-scene rate-budget problem actually appears.
- **`SurfaceAppearance` PBR maps** (ColorMap/NormalMap/MetalnessMap/RoughnessMap) — Cube emits a single
  color texture in `TextureContent`; `SurfaceAppearance.ColorMap` isn't writable at PluginSecurity anyway.
  If a future Cube schema emits a SurfaceAppearance with maps, that's a separate follow-up.
- **EditableImage-authored procedural textures** (hand-painted looks) — a separate authoring feature, not
  persistence.
- **Re-persisting a texture changed after the geometry was already saved** — out of the single-pass model.

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). A plugin code change needs `.\build.ps1` + a USER
Studio restart. The **"CreateAssetAsync Lua API"** beta flag must stay ON. Drive the dogfood via
`scripts/studio-agent.ps1` (keep bridge Luau ASCII-only). Execute with
**superpowers:subagent-driven-development** (fresh implementer + spec + code-quality review per task).
Commit per task; don't push. Verify by LOOKING at captures.
