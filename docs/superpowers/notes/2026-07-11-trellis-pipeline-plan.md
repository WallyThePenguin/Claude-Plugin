# Staged Implementation Plan: Text → Image → 3D → Rig → Roblox

**Pipeline:** Gemini text-to-image → TRELLIS (local, RTX 2060 SUPER 8GB Turing) → Blender headless cleanup/auto-rig → rigged asset in Roblox Studio, orchestrated by the existing Python 3.11 sidecar at `127.0.0.1:8389`.

**Two product lanes** (this shapes everything downstream):

- **Lane A — quality meshes (default, weapons/props):** Gemini → TRELLIS → Blender *cleanup only* (decimate/UV/scale/de-junk) → unrigged mesh import via the already-shipped EditableMesh → `CreateMeshPartAsync` → `CreateAssetAsync` path → articulation via the **existing Motor6D chain system** (already live). No skinning anywhere. This lane has zero unverified seams and ships first.
- **Lane B — skinned/boned assets (creatures, deforming props):** adds Blender armature+weights and a rigged import seam. Every rigged-import seam is gated (see Stage 0), because that is where the unverified territory is.

```
prompt ──> sidecar/gemini_image.py ──> refs/<slot>.png
                 │  (direct Google AI Studio API — NEVER via CLIProxyAPI)
                 v
        sidecar/trellis.py  (engine picked at Gate G2)
                 │            A: trellis.cpp CUDA server/CLI (TRELLIS.2, sm_75 binaries)
                 │            B: trellis-stable-projectorz FastAPI (TRELLIS-1, verified 8GB)
                 v
           glb/<slot>.glb
                 │
        sidecar/blenderbridge.py ──> blender.exe -b -P blender_scripts/rig_weapon.py
                 │        Lane A: cleanup+decimate+scale        Lane B: + armature + 1.0 weights
                 v
      fbx/<slot>.fbx + <slot>.gltf + rig_manifest.json
                 │
        sidecar/roblox_import.py  ── existing 8389 bridge ──> plugin (src/Tools/SkinnedMesh.luau)
                 │   Path 1: EditableMesh+AddBone (gated G3)   Path 2: Open Cloud Model (gated G4)
                 │   Path 3: manual 3D Importer (always works) Lane A: existing mesh path + Motor6D
                 v
   MeshPart (+Bones) in Studio ──> capture verify ──> CreateAssetAsync persist
```

---

## Stage 0 — Decision gates and installs (do first; ~half a day)

Nothing gets built until four cheap empirical gates settle the contested facts. Record each result in `sidecar/config.json` (new keys: `trellis_engine`, `gemini_image_billing`, `skinning_runtime_ok`, `opencloud_rig_ok`).

### 0.1 Installs (USER consent required — downloads and disk)

| Item | Size | Command sketch |
|---|---|---|
| trellis.cpp v0.1.5 CUDA binary | 648 MB | `curl -LO https://github.com/pwilkin/trellis.cpp/releases/download/v0.1.5/trellis-cuda-windows-x64.zip` → expand to `C:\tools\trellis\` (also grab `trellis-vulkan-windows-x64.zip`, 22 MB, as kernel fallback) |
| TRELLIS.2 GGUF weights (512-res subset) | ~11.3 GB | `py -3.11 -m pip install -U "huggingface_hub[cli]"` then `hf download ilintar/trellis2-gguf --local-dir C:\tools\trellis\models --exclude "*_1024*"` (ungated — no HF token) |
| Blender **4.5 LTS portable ZIP** (pin explicitly; winget default is 5.x — do NOT take it) | ~400 MB | download 4.5.x portable → `C:\tools\blender-4.5\` (no admin needed) |
| trellis-stable-projectorz (fallback engine; defer until G2 fails, or install now for the A/B quality baseline) | ~10–15 GB | `v40_py311_trellis_stableprojectorz.zip` from github.com/IgorAherne/trellis-stable-projectorz/releases/tag/latest → unzip → `run-fp16.bat` |
| sidecar deps | tiny | `py -3.11 -m pip install trimesh pygltflib` (verification helpers; the HTTP legs stay stdlib) |

Total worst case ~27 GB against 112 GB free — fine. Nothing needs admin; everything pins under `C:\tools\`.

### 0.2 Gate G1 — Gemini image free-tier probe (~5 min, USER: API key)

USER creates a **Google AI Studio API key** (aistudio.google.com; separate project/key from the Roblox Open Cloud key) and drops it in the sidecar env/config. Fire one live call (curl or the Stage-1 module). Free tier for image models is **contested** (official pricing page shows none as of July 2026): if 429/blocked → USER enables billing. Budget reality: $0.039/image, ~$1 per 25 references.

**Hard rule, decided now:** image generation goes **direct to Google**, never through CLIProxyAPI/Antigravity. Verified: the gemini-cli OAuth channel exposes no image models (CLIProxyAPI #978), the Antigravity image channel is flaky (503/429, sizes ignored), and there are documented permanent account suspensions for exactly this stack (#1803) — on the user's *primary* Google account, whose ban-risk is already flagged in this project. The Gemini Web cookie channel stays documented as emergency-only.

### 0.3 Gate G2 — TRELLIS engine bake-off (the stage-0 fit decision)

The lenses say: official TRELLIS.2 **cannot** fit 8 GB (verified: 24 GB / Linux / flash-attn sm_80+); trellis.cpp at `--res 512` **should** fit (likely — sm_75 is in the shipped kernels per release.yml, per-stage model load/free, ~2.6 GB peak weights — but no published 8 GB-Turing run exists); stable-projectorz **verifiably** fits (built for 8 GB, GTX 980+, fp16, xformers). So the engine choice is empirical:

1. With Studio **closed** (8 GB card is shared), run: `C:\tools\trellis\trellis-cli.exe test_sword.png out.glb --res 512 --require-gpu --bg-removal birefnet` while logging `nvidia-smi --query-gpu=memory.used --format=csv -l 1`.
2. **PASS** (GLB emitted, no OOM) → `trellis_engine = "trellis2-cpp"` (TRELLIS.2-4B quality, PBR GLB). Record wall time — expect minutes, it is unpublished for this card.
3. **FAIL** with kernel/CUDA error → retry with the Vulkan zip (arch-independent). Still fails or OOMs → `trellis_engine = "trellis1-spz"` (stable-projectorz). This floor is guaranteed by verified facts; quality is TRELLIS-1 tier (baked-color GLB, no PBR).
4. **Rejected outright** (do not revisit): ComfyUI TRELLIS.2 (all prebuilt wheels sm_80+ → "no kernel image" on this card; rebuild = hours of MSVC/toolchain work), WSL2 (identical sm_75 rebuild burden, zero advantage), official microsoft/TRELLIS.2 native (24 GB), Imagen 4 (endpoint shuts down 2026-08-17).

License caveat to log: trellis.cpp has **no LICENSE file** (13 days old, 12 stars). Pin v0.1.5, don't vendor its code, and get licensing clarified before any commercial redistribution of the *tool*; the TRELLIS.2 weights themselves are MIT.

### 0.4 Gate G3 — Roblox runtime-skinning spike (~30 min, in a fresh Baseplate via the existing bridge)

This gates Lane B Path 1. A verified DevForum regression report (2026-05-23, no staff reply) says the sibling API `CreateDataModelContentAsync` **silently drops skinning**; whether `CreateMeshPartAsync` is also hit is unknown. Spike, in Luau over the existing bridge:

1. Build a 2-bone cylinder EditableMesh; `AddBone` ×2 (also the API-discovery step — the `boneProperties` dict is undocumented: create, then introspect `GetBones()/GetBoneCFrame()/GetBoneParent()` to learn the schema); `SetVertexBones` + `SetVertexBoneWeights`.
2. `AssetService:CreateMeshPartAsync` → parent matching-named `Instance.new("Bone")` hierarchy under the MeshPart (skinning binds **by name** — verified) → set `Bone.Transform` → screenshot via the existing capture loop.
3. **PASS** = visible deformation → Path 1 is Lane B primary. **FAIL** = park Path 1 (regression), Lane B rides G4 or Path 3.

### 0.5 Gate G4 — Open Cloud rigged-upload probe (~20 min)

Gates Lane B Path 2. Rig/bone survival through `POST /assets` (assetType Model, `model/fbx` / `model/gltf-binary`) is **undocumented in both directions**. Using the existing assets-scoped key and `sidecar/opencloud.py`'s HTTP machinery: upload one known-good skinned FBX (any sample rig; or the Stage-3 smoke-test export) → poll operation → `InsertService:LoadAsset` in Studio → inspect for Bone instances and deformation. PASS → fully headless bulk path unlocked. FAIL → headless rigged import = Path 1 only (if G3 passed), else manual.

**Exit criteria for Stage 0:** all four config keys set; engine chosen; USER key working; go/no-go known for both rigged-import seams.

---## Stage 1 — Gemini text→image leg (`sidecar/gemini_image.py`)

**Build.** New module, stdlib `urllib` only (matches sidecar style), plus a route in `sidecar/server.py`: `POST /image/generate {prompt, slot, views?}` → writes `workspace/refs/<slot>.png`, returns path + dims.

- Endpoint: `POST https://generativelanguage.googleapis.com/v1beta/models/{MODEL_ID}:generateContent`, header `x-goog-api-key: <key>`.
- Body: `{"contents":[{"parts":[{"text": PROMPT}]}],"generationConfig":{"responseModalities":["Image"],"imageConfig":{"aspectRatio":"1:1"}}}`; parse `candidates[0].content.parts[].inlineData.data` → base64 → PNG (~1024 px).
- `MODEL_ID` pinned in **one** config key: `"gemini-2.5-flash-image"` ($0.039/img, most stable), with `"gemini-3.1-flash-lite-image"` as the documented one-line migration (2.5 is flagged legacy; docs are also pivoting to an Interactions API — isolating the call in one function makes both migrations one-liners).
- Baked-in prompt template (this is the TRELLIS quality lever): `"Professional product photograph of a single <OBJECT>, three-quarter front view, centered and filling most of the frame, on a pure white seamless background, soft even studio lighting, no shadows, no reflections, matte materials, entire object visible with margin, no text, no watermark"`. One 3/4 hero view is primary; optional front/side/back extra views for TRELLIS multi-image mode (results vary — verified caveat).
- 1024×1024 is fully sufficient: TRELLIS-1 preprocessing auto-runs rembg u2net + 518×518 resize; trellis.cpp has `--bg-removal birefnet`. Do not pay for 2K/4K.

**Verify.** Per call: HTTP 200, PNG magic bytes, min dimension ≥ 1024, corner-luminance heuristic (mean of 4 corner patches ≥ ~0.92 ⇒ white bg) — auto-reroll once on failure. Log token/cost per image. Note in the job record that all Gemini output carries an invisible SynthID watermark (harmless for geometry conditioning; disclose if a generated image ever ships as a texture).

**Exit criteria:** `POST /image/generate {"prompt":"iron sword"}` yields a clean white-bg product shot on disk, twice in a row.

---

## Stage 2 — TRELLIS image→GLB leg (`sidecar/trellis.py`)

**Build.** One interface, two drivers behind `config.trellis_engine`; route `POST /model3d/generate {image_path, seed, res=512}` → `workspace/glb/<slot>.glb`. Single-flight job lock — the 8 GB card cannot host Studio + generation + anything else concurrently, so the sidecar serializes generation and (driver A default) prefers process-per-job so VRAM returns to zero between jobs.

- **Driver A `trellis2-cpp`:** shell out per job — `C:\tools\trellis\trellis-cli.exe <in.png> <out.glb> --res 512 --require-gpu [--bg-removal birefnet] [--decim N --atlas N]`. Optional resident mode later: manage `trellis-server.exe --models C:\tools\trellis\models` as a child process (`GET /health`, `POST /generate` multipart with seed/resolution/bg_removal → `model/gltf-binary`) — same shape as the sidecar's other bridges. Stay at `--res 512`; the 1024 cascade is documented at 16 GB and is out of reach.
- **Driver B `trellis1-spz`:** stable-projectorz runs its own FastAPI (`api_spz`); the sidecar starts `run-fp16.bat` and proxies. Force `ATTN_BACKEND=xformers` (Turing has no flash-attn — verified) and `SPCONV_ALGO=native`; use built-in `to_glb(simplify=…, texture_size=1024)` so the GLB arrives pre-decimated.

**Verify.** Parse the GLB with `trimesh`/`pygltflib` (extending the existing `sidecar/meshio.py:parse_glb`): loads clean, non-zero volume, tri count recorded, UVs present, texture image embedded. Log wall time + peak VRAM (`nvidia-smi --query-gpu=memory.used`) into the job journal — this builds the missing 8 GB-Turing benchmark. Reroll policy: up to 2 re-seeds (systemic finding: all current models produce some unusable generations — plan rerolls, not one-shots).

**Exit criteria:** reference PNG → valid textured GLB on disk with recorded time/VRAM, for the chosen engine.

---

## Stage 3 — Blender headless cleanup + auto-rig (`sidecar/blenderbridge.py` + `sidecar/blender_scripts/`)

**Design decision (from the blender-rig lens): no MCP.** blender-mcp is an interactive GUI/socket/arbitrary-code tool; this leg is a deterministic batch step. Plain subprocess:

```
C:\tools\blender-4.5\blender.exe -b --factory-startup ^
  -P sidecar\blender_scripts\rig_weapon.py -- ^
  --in workspace\glb\sword.glb --out workspace\fbx\sword.fbx --spec specs\sword.json --mode rigid|skinned|cleanup
```

**Build.** `sidecar/blenderbridge.py` = subprocess wrapper + timeout + log capture. `sidecar/blender_scripts/rig_weapon.py` (versioned in repo) stages:

1. `bpy.ops.import_scene.gltf(filepath=in_glb)`.
2. bmesh cleanup: merge-by-distance ~1e-4, degenerate dissolve, `transform_apply` — mandatory: AI meshes are non-manifold/dense/chaotic (verified systemic finding), and this is also the anti-bone-heat pre-pass.
3. Decimate to budget (target ≤ 10k tris; hard Roblox spec 20k/MeshPart) preserving UVs; only re-Smart-UV + re-bake albedo/normal from the dense mesh if decimation wrecks UVs. `--mode cleanup` (Lane A) stops after this + scaling and exports unrigged.
4. Segment per `specs/<archetype>.json`: separate-by-loose-parts if multi-shell, else spec-driven axis bands (`grip/guard/blade1/blade2`).
5. Build **exactly one** armature via the data API (`edit_bones`, heads/tails from segment bounds: Root@grip → Handle → Guard → BladeN). Unique bone names. Ignore the "!" root-bone convention — it could not be verified in any Roblox source (apocryphal).
6. **Skin without bone-heat (deterministic):** per segment, create a vertex group named exactly like its bone, `vg.add(indices, 1.0, 'REPLACE')`, join, add Armature modifier. This is headless-safe, operator-free, and guarantees **every bone influences ≥1 vertex** — critical because the Roblox importer silently drops zero-influence bones and the opt-out checkbox exists only in the Studio GUI. `ARMATURE_AUTO` bone-heat is banned for weapons (unproven under `-b`, fails on AI-mesh defects); it and UniRig are the *later* organic-rig track.
7. Scale to studs (1 stud = 0.28 m; factor in spec).
8. Export **FBX**: `bpy.ops.export_scene.fbx(object_types={'ARMATURE','MESH'}, add_leaf_bones=False, use_armature_deform_only=True, bake_anim=False, path_mode='COPY', embed_textures=True, apply_scale_options='FBX_SCALE_UNITS', mesh_smooth_type='FACE')` — maps 1:1 to Roblox's documented settings. Also export a parallel **.gltf** (the 3D Importer accepts glTF with rigging — sidesteps FBX scale quirks). Emit `rig_manifest.json` (bone tree, bind transforms, tri count, texture list) for the plugin.

Two one-time calibrations: (a) **scale** — export a known 1 m cube, import once, measure studs, pin either `FBX_SCALE_UNITS` or `global_scale=0.01` in the script forever (docs and community disagree; one empirical run settles it); (b) smoke-test `ARMATURE_AUTO` under `-b` with `temp_override` once, only to inform the future organics track.

**Verify (headless, automatic).** Re-import the exported FBX into a fresh `blender -b` session and assert: exactly 1 armature, expected bone names, every deform bone has ≥1 weighted vertex, tri count ≤ budget, textures embedded. Write `verify_report.json`; any failure fails the job loudly (this leg is deterministic — no retries).

**Exit criteria:** TRELLIS GLB in → FBX+glTF+manifest out, self-verified, for both `cleanup` and `rigid` modes.

---

## Stage 4 — Import into Roblox (`sidecar/roblox_import.py` + `src/Tools/SkinnedMesh.luau`)

**Lane A (default, ships first, no gates):** the sidecar streams the cleaned mesh through the **existing** EditableMesh → `CreateMeshPartAsync` → `CreateAssetAsync` path (already proven in this repo), and the **existing Motor6D chain system** articulates it (make_tool/grip machinery). For per-part collision/dismemberment, Stage 3 exports unskinned separate segment meshes; the importer never creates Motor6Ds anyway — Motor6D welding stays a plugin-side Luau job. Blender's contribution to Lane A is purely mesh quality (topology, tri budget, UVs, scale).

**Lane B (rigged/skinned), three ranked paths behind one route `POST /roblox/import_rigged {fbx|glb, manifest}`:**

- **Path 1 — runtime skinning (primary iff Gate G3 passed; fully programmatic, zero dialogs):** extend `sidecar/meshio.py:parse_glb` to also extract the skin (bone tree + bind CFrames, per-vertex bone ids + weights, ≤4/vertex) → stream JSON over the existing 8389 bridge → new `src/Tools/SkinnedMesh.luau` (follows the existing `src/Tools/*` pattern): EditableMesh build → `AddBone`/`SetBoneCFrame`/`SetBoneParent` (dict schema learned at G3) → `SetVertexBones`+`SetVertexBoneWeights` → `CreateMeshPartAsync` → matching-named `Bone` instances under the MeshPart → `AnimationController`+`Animator` → persist via `CreateAssetAsync` (Mesh + Model). Respect EditableMesh caps (60k verts / 20k tris — Stage 3 budget already under). Headless publish variant: the same publish runs in Open Cloud Luau Tasks (`sidecar/opencloud.py:create_luau_task` already exists) with no beta flag.
- **Path 2 — Open Cloud Model upload (bulk path iff Gate G4 passed):** `POST /assets` with the Stage-3 FBX/GLB via `sidecar/opencloud.py` → asset id → plugin `InsertService:LoadAsset` → verify Bones → hand to existing Item/grip machinery. Known pain: the returned id is the *package* id, not MeshId/TextureId, and embedded-texture behavior is under-documented — if textures arrive broken, re-apply via the existing image-upload + `SurfaceAppearance` wiring.
- **Path 3 — manual archetype seam (always works; USER action):** plugin stages the FBX and prompts the USER to run the Studio 3D Importer once per rig archetype (Rig Type: Custom; our construction guarantees no zero-influence bones). The imported skinned MeshPart+Bones becomes an owned template asset the plugin clones/retargets thereafter. `AssetImportService` is RobloxScriptSecurity — a dialog-free local-file import for third-party plugins does not exist; do not plan around it.

**Animation seam (scheduled follow-up, not a blocker):** skinned rigs animate via `Bone.Transform`, but the repo's clip machinery (`src/AnimationClip.luau`) targets Motor6D transforms. Add a Bone channel to the clip authoring + a `skinned_rig_live` oracle check (existing `src/Tools/Oracle.luau` pattern). Until then, Lane B assets pose via direct `Bone.Transform`, and anything needing shipped animations uses Lane A/Motor6D.

**Verify.** After import: assert MeshPart + exact Bone set from `rig_manifest.json`; drive each bone through a test rotation; assert `Bone.TransformedWorldCFrame` moved (no API returns deformed vertex positions — verified — so CFrames + capture are the witnesses); screenshot via the existing capture loop and compare silhouette against the Stage-1 reference. Publish steps tolerate epsilon skinning drift (staff-acknowledged precision note) and moderation latency (queue + retry — automated review applies to every asset; keep AI output out of the avatar/UGC catalog, where the 2025 purges happened; in-game props are explicitly permitted).

**Exit criteria:** Lane A: prompt-born sword mesh in Studio, gripped and swinging via existing Motor6D clips. Lane B: a skinned test asset deforming under scripted `Bone.Transform`, persisted with `CreateAssetAsync`, via whichever path the gates opened.

---

## Stage 5 — Orchestration + end-to-end acceptance (`sidecar/asset_pipeline.py`)

**Build.** Route `POST /pipeline/asset {prompt, archetype, lane, name}` → state machine `image → glb → blender → import → verify`, one job at a time (VRAM lock shared with Stage 2), artifacts under `workspace/pipeline/<job>/` with a job journal (stage timings, VRAM peaks, rerolls, costs, verify reports). Retry policy: image ≤2 rerolls (bg heuristic), TRELLIS ≤2 re-seeds, Blender fail-fast, import fail-fast with path fallback (1→2→3). Wire into the existing forever-loop/factory as a new asset source; tests as `sidecar/test_asset_pipeline.py` following the repo's `test_*.py` convention.

**Verify (the E2E acceptance pair).** (1) `"iron sword"`, Lane A — exercises quality lane + Motor6D grip/swing with existing clips; (2) `"goblin"`, Lane B — exercises skinning end-to-end. Each must produce: reference PNG, GLB, verified FBX, in-Studio captures, persisted asset ids. Grade captures against the reference image with the existing rubric/judge machinery.

---

## The single riskiest assumption

**That skinned data survives *any* programmatic import seam into current Roblox.** Both headless rigged paths are unverified this month: the EditableMesh runtime path sits next to an open, staff-unanswered regression (2026-05-23: `CreateDataModelContentAsync` silently drops skinning — blast radius unknown), and Open Cloud Model upload's rig preservation is documented nowhere in either direction. If **both** G3 and G4 fail, every new rig archetype needs one manual 3D-Importer pass (Path 3) and Lane B's autonomy collapses to template-cloning. That is exactly why G3/G4 run at Stage 0, before a line of Lane B code. Mitigation that keeps the project whole: Lane A (mesh quality + Motor6D articulation) is unaffected — the pipeline still delivers most of its value because weapons already articulate natively; only smooth-skin deformation is hostage to the gates.

Runner-up risk (already structurally handled): trellis.cpp's 8 GB-Turing fit is inferred, not benchmarked — but Gate G2's verified fallback (stable-projectorz) caps the downside at TRELLIS-1 quality, not failure.

---

## What needs the USER

1. **Google AI Studio API key** (new, separate from the Open Cloud key); enable billing if the G1 probe 429s (~$0.04/image).
2. **Consent to downloads/disk (~27 GB):** trellis.cpp zip + ilintar GGUF weights (~12 GB), Blender 4.5 LTS portable, optionally stable-projectorz (~10–15 GB).
3. **Studio beta flag:** enable "CreateAssetAsync Luau API" (local plugin publish path).
4. **Policy sign-off:** images go direct-to-Google only — never via the CLIProxyAPI/Antigravity proxy (documented permanent-ban precedent on exactly that stack, and it's the primary Google account).
5. **Manual steps if gates fail:** Path 3 = run the 3D Importer once per rig archetype; G2 total failure = accept TRELLIS-1 quality tier.
6. **License review before anything commercial:** trellis.cpp has no LICENSE file (pin v0.1.5; weights are MIT); SynthID watermark rides in any Gemini-derived shipped texture.
7. **Scheduling:** generation jobs and heavy Studio sessions can't share the 8 GB card — runs are serialized; live tests in a fresh Baseplate per existing project rule.

## File map (new / changed)

| Path | Role |
|---|---|
| `sidecar/gemini_image.py` (+`test_gemini_image.py`) | Stage 1: direct Gemini image call, model id pinned in config |
| `sidecar/trellis.py` (+`test_trellis.py`) | Stage 2: engine-agnostic image→GLB, drivers `trellis2-cpp` / `trellis1-spz`, VRAM lock |
| `sidecar/blenderbridge.py` | Stage 3: headless Blender subprocess wrapper |
| `sidecar/blender_scripts/rig_weapon.py` | Stage 3: cleanup → decimate → segment → armature → 1.0-weight skin → FBX/glTF + manifest |
| `specs/<archetype>.json` | rig specs (bone names, segmentation, stud scale) |
| `sidecar/meshio.py` (extend `parse_glb`) | skin extraction (bones, weights) for Path 1 streaming |
| `sidecar/roblox_import.py` | Stage 4: path-1/2/3 router; Open Cloud upload via existing `opencloud.py` |
| `src/Tools/SkinnedMesh.luau` | Stage 4: EditableMesh+AddBone builder, Bone hierarchy, CreateAssetAsync persist |
| `src/AnimationClip.luau` (follow-up) | Bone.Transform channel alongside Motor6D |
| `sidecar/asset_pipeline.py` (+test) | Stage 5: orchestration, journal, retries |
| `sidecar/server.py` | new routes: `/image/generate`, `/model3d/generate`, `/roblox/import_rigged`, `/pipeline/asset` |

## Explicitly rejected (do not revisit without new facts)

blender-mcp (interactive tool, wrong shape); ComfyUI TRELLIS.2 on this card (sm_80+ wheels, hours of rebuild); WSL2 (no advantage for sm_75); official TRELLIS.2 native (24 GB); `AssetImportService` (RobloxScriptSecurity); Imagen 4 (dead 2026-08-17); image traffic over CLIProxyAPI/Antigravity (ban risk); the "!" root-bone convention (apocryphal); bone-heat auto-weights for weapons (deterministic 1.0 weights instead).