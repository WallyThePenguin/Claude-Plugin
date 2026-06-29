# Build guide report: characters (v1.0)

Generated 2026-06-29 by the `train-recipe` factory (22 agents; 48 build-angled techniques → 15 steps /
3 tiers, 3 baseline / 7 good / 5 exceptional); targets the characters rubric (v1.0). Because the agent has
no dedicated ApplyDescription/SurfaceAppearance tool, the guide builds via `run_luau` (+ `create_instance`/
`set_property`) for description assembly/scaling/accessory composition/PBR wiring, `generate_mesh`/
`author_mesh`/`spawn_rig` for geometry/rigs, and `capture`/`capture_angles` to verify every visual claim.

## Coverage
- Rubric criteria addressed: **16 / 16**
- Steps: 15 across 3 tiers
- Uncovered criteria: none (coverage-fill rounds: 0)

## Completeness review
- Killer systems covered (5 / 5): deliberate proportions/scaling, cohesive themed outfit (rigid + layered),
  custom body / non-humanoid rig fidelity, designed color + PBR material palette, HumanoidDescription
  variation system.
- Killer systems missing: none

### Assessment
COMPLETE — the guide maps onto all 16 rubric criteria, each step naming the specific mechanism its PASS
gate demands, in a dependency-sound order: (baseline) per-archetype HumanoidDescription scale axes →
custom body geometry → themed rigid+layered outfit; (good) 60/30/10 color palette → per-region
SurfaceAppearance PBR hierarchy → authored layered (cage) clothing → custom rig fidelity → authored 3D
face → theme spine → ApplyDescription variation system; (exceptional) per-archetype-distinct silhouette
validated at distance → governing shape-language hierarchy → authored surface/baked-light treatment →
single deliberate focal point → one shared identity system locking the cast. It names the real gotchas
(ProportionScale is a no-op while BodyTypeScale is 0; shoulder attachments move with the arm, collar
attachments don't; paint_texture is Parts-only, MeshParts rejected; ≤4 joint influences per vertex).

## 16 / 16 map (rubric criterion → guide step)
- char-archetype-proportions-humanoiddescription-scaling → `char-base-1-archetype-and-scale`
- char-avatar-structural-contract-mesh-hygiene → `char-base-2-custom-body-geometry`
- char-custom-meshpart-nonhumanoid-rig-fidelity → `char-base-2-custom-body-geometry` + `char-good-4-custom-rig-fidelity`
- char-performance-budget-atlas-lod → `char-base-2-custom-body-geometry` + `char-good-2-pbr-material-hierarchy`
- char-themed-accessory-outfit-composition → `char-base-3-themed-outfit-composition`
- char-limited-harmonized-color-palette → `char-good-1-color-palette`
- char-pbr-material-hierarchy-surfaceappearance → `char-good-2-pbr-material-hierarchy`
- char-baked-light-stylized-texturing → `char-good-2-pbr-material-hierarchy` + `char-exc-3-authored-surface-treatment`
- char-layered-clothing-cage-authoring → `char-good-3-layered-clothing`
- char-face-feature-dimensional-consistency → `char-good-5-authored-face`
- char-theme-spine-costume-storytelling → `char-good-6-theme-spine`
- char-humanoiddescription-variation-system → `char-good-7-variation-system`
- char-silhouette-distance-and-pose-readability → `char-exc-1-distinct-silhouette`
- char-shape-language-system → `char-exc-2-shape-language-system`
- char-detail-density-focal-hierarchy → `char-exc-4-focal-point`
- char-cast-cohesion-hero-asset-style-lock → `char-exc-5-cast-cohesion-style-lock`

## Provenance
- Sweep angles: workflow, killer-impl, pitfalls, video
- Techniques gathered: 48
- Coverage-fill rounds: 0
