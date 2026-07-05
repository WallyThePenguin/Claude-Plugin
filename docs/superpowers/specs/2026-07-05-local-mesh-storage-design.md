# Local mesh storage (no Roblox upload) — design

**Date:** 2026-07-05 · **Status:** approved by user ("Fix meshes first")

## Why

The factory's mesh persistence uploads generated geometry to Roblox via
`CreateAssetAsync`. Freshly-created assets pass an immediate load-check (served from the
creator's session cache) so the part is swapped to reference the new `rbxassetid://` — but
the asset is still **pending moderation** on Roblox's servers, so a real CDN fetch (on
reopen, or `ContentProvider:PreloadAsync`) **fails** (`AssetFetchStatus.Failure`). Enough of
these push Studio into "some features have been disabled" degraded mode, which killed the
plugin's command bridge mid-run (observed: 21/22 sampled generated meshes failed to fetch;
the loop died mid-cycle-5).

User's fix (verified feasible this session): **store meshes locally, never upload them.**
The geometry is pure Luau data; serialize it into the place and rebuild the EditableMesh on
load. No upload → no moderation → no CDN → no instability.

## Verified mechanism (live probes, 2026-07-05)

- `em:GetVertices()` → {vertexId}; `em:GetPosition(vid)` → Vector3 — read all vertices. ✓
- `em:GetFaces()` → {faceId}; `em:GetFaceVertices(fid)` → {vid, vid, vid} — read all
  triangles. ✓ (`GetTriangles` does NOT exist; the API is face-based.)
- Rebuild: `CreateEditableMesh()` + `AddVertex` + `AddTriangle` (existing `buildMeshPart`
  path); apply via `MeshPart:ApplyMesh(Content.fromObject(em))`.

So extraction works for BOTH procedural meshes (`buildMeshPart`) and Cube text-to-3D meshes.

## Design

### Data format
A part's geometry is `{ v = {x,y,z, x,y,z, ...}, t = {i,i,i, ...} }` — a flat vertex-position
array and a flat 0-based triangle-index array. `encodeMeshData` / `decodeMeshData` are PURE
string<->table functions (a compact delimited format: `"v:<floats>;t:<ints>"`), unit-tested
for round-trip in MeshFactorySpec. Stored as a `StringValue` named `MeshData`.

### New MeshFactory functions
- `MeshFactory.encodeMeshData(data) -> string` / `decodeMeshData(string) -> data` — PURE.
- `MeshFactory.extractGeometry(em) -> data` — impure: GetVertices/GetPosition +
  GetFaces/GetFaceVertices, remapping vertex ids to 0-based indices.
- `MeshFactory.persistMeshPartLocal(mp) -> {stored, dataChars, err?}` — impure: extract EM
  from `mp.MeshContent`, extract geometry, encode, store as a `MeshData` StringValue child,
  tag `mp:SetAttribute("SALocalMesh", true)`. NO upload, NO swap; part stays session-backed.
- `MeshFactory.rebuildLocalMesh(mp) -> ok` — impure: read `MeshData`, decode, rebuild the
  EditableMesh, `mp:ApplyMesh(Content.fromObject(em))`.

### Rebuild-on-load
Session-backed geometry goes blank on save/reopen/play, so tagged parts must be rebuilt:
- **Edit:** the plugin bootstrap, on load, finds every `MeshPart` with `SALocalMesh=true`
  and rebuilds it (so staged mesh artifacts render after reopen).
- **Play / shipped:** `runtime/MeshRebuild.luau` (client) does the same on join.

### save_mesh tool
Switch from `persistMeshPart` (upload) to `persistMeshPartLocal`. The old upload function is
kept (unused) in case a future "publish real assets" path is ever wanted. Result message
becomes "stored locally (no upload; survives save/reopen via rebuild)".

### Texture (v1 scope)
Procedural meshes have no texture (color/material only) — fully covered. Cube meshes' procedural
texture also uploads today (same instability); v1 keeps Color/Material and DROPS the uploaded
texture. Local texture storage (serialize EditableImage pixels) is a follow-up.

## Testing
- Unit (MeshFactorySpec): `encodeMeshData`/`decodeMeshData` round-trip incl. empty, floats,
  large index values; malformed decode returns nil (not a throw).
- Live (bridge): generate a mesh, `persistMeshPartLocal`, confirm no `rbxassetid`/no upload,
  a `MeshData` child exists, the part is tagged; then blank + `rebuildLocalMesh` and confirm
  it renders (capture).

## Out of scope
- Local texture storage (Cube textures dropped in v1).
- Publishing real Roblox assets (the upload path stays available but unused).
