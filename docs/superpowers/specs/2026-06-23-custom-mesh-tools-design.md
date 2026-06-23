# Studio Agent — Custom-mesh tools (`generate_mesh` + `author_mesh`) design (2026-06-23)

**Status:** approved in brainstorming, ready for an implementation plan.
**Goal:** Formalize the newly-unlocked bridge mesh paths into curated, reliable, strategy-guided agent
tools so the agent builds with CUSTOM MESHES (not just Part primitives) and picks the right path —
operationalizing the lesson learned this session: *Cube is great for man-made objects but its organic
single-meshes look like creatures; use procedural geometry for trees/rocks/foliage.*

## 1. Background (verified live this session — see memory `roblox-bridge-mesh-creation`)

Three mesh paths are callable from `run_luau` at PluginSecurity in edit context. v1 wraps the first two
as tools; the third (persistence) is deferred.
- **Cube text-to-3D:** `GenerationService:GenerateModelAsync({TextPrompt=...}, {PredefinedSchema="Body1"})`
  → `(Model, metadata)`. No `Player` param; runs from the edit bridge. Proven: "a wooden barrel" → a
  real textured barrel (Model, 1 MeshPart). Beta, ~5 generations/min/experience; output normalized to
  ~2 studs. (`GenerateMeshAsync` is the OTHER method — server-only + Player + deprecating; NOT used.)
- **EditableMesh procedural geometry:** `AssetService:CreateEditableMesh()` →
  `AddVertex(Vector3)`/`AddTriangle(id,id,id)` → `AssetService:CreateMeshPartAsync(Content.fromObject(em))`
  → a real MeshPart. Proven: rendered a tetrahedron and stacked cones (pines). Cap 60k verts / 20k tris.
- **(deferred) `CreateAssetAsync(em, Enum.AssetType.Mesh)`** — persist an owned, shippable asset
  (beta-flag-gated, async moderation). v2.

**Key reframe:** the agent already has `run_luau`, so the raw APIs already work. Formalizing adds
**curated tools + reliability + strategy guidance**, not new raw power.

## 2. Settled decisions (from brainstorming)

- **Scope = Core:** `generate_mesh` (Cube) + `author_mesh` (curated procedural organics) + a SystemPrompt
  strategy section wired into the build→capture→evaluate→learn loop. **Persistence (`save_mesh`)
  deferred to v2.**
- **Procedural path = a curated `author_mesh` tool** (proven parametric organics; reliable one-call, no
  winding/normal fumbling), not a skills-only or prompt-only approach. The agent can still
  `run_luau`+EditableMesh for novel shapes and `save_skill` good builders to grow the library.

## 3. The tools

### 3a. `generate_mesh` (Cube text-to-3D)

Inputs:
- `prompt` (string, required) — what to generate.
- `name` (string, optional) — the resulting Model's name (default derived from the prompt).
- `position` (`{x,y,z}`, optional) — where to ground it; default the current Selection's position, else
  origin.
- `height` (number, optional) — target height in studs; Cube normalizes to ~2 studs, so this scales the
  Model. Omitted → left at native scale.

Behavior: `GenerationService:GenerateModelAsync({TextPrompt=prompt}, {PredefinedSchema="Body1"})`; on a
Model result → name it, `ScaleTo` the factor for `height` (if given), ground its base at `position`,
parent to Workspace; return a summary (`name`, MeshPart count, bounding size, path). The **description
bakes in the rule**: *best for MAN-MADE objects (barrels/carts/buildings/furniture/signs); its organic
single-meshes (trees/rocks/foliage) come out creature-like — use `author_mesh` for those.*

Failure handling: a non-Model / nil result, a rate-limit error (~5/min), or a generation throw → a clear,
retryable `(string, isError=true)`. The call yields ~10–40s (fine for tool dispatch).

### 3b. `author_mesh` (curated procedural organics)

Inputs:
- `kind` (string, required) — `"pine"` | `"rock"` in v1 (a builder table, extensible).
- `name` (string, optional), `position` (`{x,y,z}`, optional, default selection/origin).
- `params` (table, optional, kind-specific, all with defaults):
  - `pine`: `height` (studs, default ~10), `tiers` (cone count, default 3), `color` (Color3-ish `{r,g,b}`).
  - `rock`: `size` (studs, default ~3), `color`, `seed` (number → deterministic non-uniform variation).

Behavior: builds the proven geometry from this session — **pine** = a `Cylinder` Part trunk + `tiers`
stacked **EditableMesh** cones (green, Grass material); **rock** = a cluster of rotated `Block` Parts
(Rock material, grey, varied by `seed`) — grouped in a Model, grounded at `position`, parented to
Workspace; return a summary + path. Reliable, no winding/normal bugs.

Failure handling: unknown `kind` → an error listing valid kinds; everything pcall-wrapped. Geometry is
tiny (far under the 60k-vert cap).

## 4. Architecture / modules

### New
- **`src/MeshFactory.luau`** — the engine, one responsibility (parameters → placed meshes):
  - PURE (unit-tested): `coneGeometry(radius, height, segments) → { vertices: {Vector3}, triangles: {{number}} }`
    (apex + base-center + ring; side + base-cap triangles with outward winding); `scaleFactorForHeight(currentHeight, targetHeight) → number`; `rockClusterLayout(size, seed) → { {size:Vector3, offset:Vector3, rot:Vector3, color:Color3} }`.
  - IMPURE (live-verified): `buildEditableMesh(geometry, color, material) → MeshPart` (CreateEditableMesh +
    AddVertex/AddTriangle + CreateMeshPartAsync(Content.fromObject)); `buildPine(params) → Model`;
    `buildRock(params) → Model`; `generateViaCube(prompt, schema) → (Model?, err?)`;
    `placeGrounded(model, position, height?)` (ScaleTo + AABB-ground).
- **`src/MeshFactorySpec.luau`** — in-Studio spec for the PURE helpers (cone vertex/triangle counts +
  apex/ring positions; `scaleFactorForHeight`; rock-cluster layout determinism by seed). Mirrors
  `CaptureSpec`/`GuiEvidenceSpec`.
- **`src/Tools/Mesh.luau`** — the two thin descriptors (`generate_mesh`, `author_mesh`): validate input,
  call `MeshFactory`, place, pcall-wrap, return `(summary, isError)`. Exports `descriptors`.

### Changed
- **`src/Tools/init.luau`** — `require(script.Mesh)` + append `MeshTool.descriptors` (stable order).
- **`src/Relay.luau` + `src/RelaySpec.luau`** — `generate_mesh` + `author_mesh` are DataModel-writing +
  AssetService → **NOT** in `LOCAL_TOOLS` (they RELAY during a playtest, the default). Add both to
  `RelaySpec`'s EXPECTED classification so the no-drift guard stays green.
- **`src/SystemPrompt.luau`** — a new "# Building with custom meshes" section (the strategy: Cube for
  man-made, `author_mesh` for organic, compose with Parts + lighting, `evaluate` then `learn` the mesh
  lessons) + a one-line entry in the tool index.

### Reused
- `Content` global + `AssetService`/`GenerationService` (verified callable from the bridge), the
  `Tools.dispatch` pcall-totality, the descriptor-list registry, the RELAY default.

## 5. The strategy / learn-loop integration ("improve over time")

The SystemPrompt section makes the learned rule first-class so the agent applies it on every build, and
explicitly nudges: after building in a rubric category, `evaluate`, then `learn(category, <durable mesh
lesson>)` — so a lesson like "use author_mesh (not Cube) for trees/rocks" is recorded once and weighted
on every later build. The tool *descriptions* carry the same rule, so even without the section the agent
sees it at the point of use.

## 6. Error handling, limits, edge cases

- Total: every tool path is pcall-wrapped → `(string, isError)`; never throws (a thrown error would
  otherwise become an is_error result via `Tools.dispatch`, but we return clean messages).
- Cube: rate-limit (~5/min) and generation failures → clear retryable text; the long yield is acceptable.
- `author_mesh`: unknown kind → lists valid kinds; geometry far under the EditableMesh caps.
- Placement: both ground the result's AABB base at `position` (default selection/origin) so it sits on
  the surface, not floating/sunk.
- RELAY: edit-mode is the primary path; the classification only routes to the server copy during a
  playtest (edge case).

## 7. Testing & acceptance gate

- Static, each task: `stylua src` ; `selene src` (0/0) ; `rojo build default.project.json --output StudioAgent.rbxm` ;
  `RelaySpec` no-drift green.
- `MeshFactorySpec` green — runnable **via the bridge** (`luau 'return tostring(require(script.Parent.MeshFactorySpec).run())'`),
  after the plugin build + USER restart that loads the new tools.
- **Bridge dogfood (verify by LOOKING, not coordinates):**
  1. `generate_mesh {prompt:"a wooden barrel", height:3}` → READ the capture: a textured barrel.
  2. `author_mesh {kind:"pine"}` and `author_mesh {kind:"rock"}` → READ the captures: a clean low-poly
     pine and a rock cluster, **no creature look**.
  3. A `prompt` driving the in-Studio agent to build a small scene using both tools → capture → confirm
     it composes (re-proving this session's manual result through the FORMAL tools the agent uses).

## 8. Scope & non-goals

**In (v1):** `generate_mesh`, `author_mesh` (pine + rock), `MeshFactory` (+ spec), the SystemPrompt
strategy section, RelaySpec classification, the bridge dogfood.

**Out (deferred, stated honestly):**
- **`save_mesh`** (CreateAssetAsync → owned/shippable/reusable asset) — the persistence + beta-flag +
  async-moderation path; v2 (needed for a cross-session reusable kit + shipping, not for the
  build→capture→evaluate loop which works with in-session meshes).
- **EditableImage** procedural textures (the stylized hand-painted look beyond built-in materials).
- **More `author_mesh` kinds** (bush, terrain-mound, fence, …) — the builder table is extensible.
- **Cube `Car5`/vehicle schema** and multi-mesh Cube modes.

## 9. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build …` (selene 0/0). A plugin code change needs `.\build.ps1` + a USER
Studio restart. Drive the dogfood via `scripts/studio-agent.ps1` (keep bridge Luau ASCII-only). Execute
with **superpowers:subagent-driven-development** (fresh implementer + spec + code-quality review per
task). Commit per task; don't push. Verify by LOOKING at captures.
