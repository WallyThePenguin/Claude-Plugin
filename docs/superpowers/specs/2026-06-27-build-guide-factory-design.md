# Studio Agent — Build-Guide Factory (design)

**Date:** 2026-06-27
**Status:** design approved (brainstorm), ready for an implementation plan.
**Serves:** the north star — push the QUALITY CEILING past the generic "AI did it" standard. This completes
the **Recipe** component of the Quality-Pack anatomy (training-architecture §4) for every rubric category.
Memories: [[studio-agent-training-vision]], [[studio-agent-north-star]]. Parent spec:
`docs/superpowers/specs/2026-06-20-studio-agent-training-architecture-design.md`.

## 1. Problem

The training thread has the **grading** half of every Quality Pack — 5 above-the-mean rubrics
(combat / environment / gui / locomotion / vfx), the `evaluate` visual-grading tool, the `refine-to-rubric`
loop, and per-category `learn`/`unlearn`. It is missing the **authoring** half for 4 of the 5 categories:
a per-category **build recipe** — the proactive "how the pros build this, tier by tier" knowledge the agent
loads *before* building, the complement to the rubric's *reactive* per-criterion `concrete_fix`.

What exists today is adjacent but not it:

- **`BuiltinRecipes`** (skill category `recipe`) — generic build *scaffolds* (leaderstats, shop-gui, r15-npc,
  datastore-save, parallel-zones). Hand-authored, not tied to any quality rubric. Surfaced under a
  "Build recipes" heading in the skill catalog.
- **`gui-design-quality`** (a working skill) — the *one* per-category quality recipe that exists, but
  hand-authored and GUI-only.

So locomotion, combat, environment, and vfx each have a rubric (the bar) but **no build guide** (how to
reach it). This spec adds a generated, rubric-anchored build guide per category, and the factory that
produces them.

## 2. Naming

The codebase already uses "recipe" for the generic scaffolds above (and surfaces them under "Build recipes").
To avoid the collision, the new artifact is a **build guide**, loaded via **`use_build_guide(category)`**.
Mnemonic pairing: the **rubric** is the bar; the **build guide** is how to reach it.

## 3. The artifact — a build guide (the inverse of a rubric)

A build guide is the proactive twin of a rubric: the rubric **grades**, the guide **builds**. It is
tier-structured JSON; every build step maps to the rubric criterion ids it satisfies. Schema
`docs/superpowers/guides/buildguide.schema.json` (mirrors `rubrics/rubric.schema.json`):

```jsonc
{
  "module": "locomotion",        // category; matches the rubric.module it targets
  "version": "1.0",
  "date": "2026-06-27",
  "system_module": "locomotion",
  "rubric_version": "1.0",        // the rubric version this guide was built against
  "overview": "1-2 sentence framing of the build approach + the killer systems",
  "killer_systems": [
    { "name": "blend tree", "what": "what it is", "how": "concrete Studio build steps" }
  ],
  "tiers": [
    {
      "tier": "baseline",         // baseline | good | exceptional
      "goal": "what a build at this tier achieves",
      "steps": [
        {
          "id": "loco-build-blend-tree",
          "order_index": 1,
          "instruction": "concrete build step using the agent's REAL tools",
          "addresses_criteria": ["loco-blend-tree-speed-dir"],  // rubric criterion ids
          "tools": ["add_keyframe", "bind_animation"],          // real Studio tool names
          "pitfalls": "the common mistake + how to avoid it"
        }
      ]
    },
    { "tier": "good", "goal": "...", "steps": [] },
    { "tier": "exceptional", "goal": "...", "steps": [] }
  ],
  "common_pitfalls": ["category-wide mistakes to avoid"],
  "provenance": {
    "sources": ["url", "..."],
    "confidence": "high|medium|low",
    "coverage": { "criteria_total": 0, "criteria_addressed": 0, "uncovered": [] }
  }
}
```

**Load-bearing property (coverage):** every rubric criterion id appears in at least one step's
`addresses_criteria`. If a guide is followed, the resulting build *can* clear the rubric. Steps cite the
agent's **real Studio tools** (`add_keyframe`, `make_tool`, `paint_texture`, `bind_behavior`, `make_npc`,
`generate_mesh`, …) so they are actionable, not abstract tutorial prose.

Validation is defensive (mirrors `RubricCatalog.validateRubric`): a guide needs a non-empty `module` and a
non-empty `tiers` array; each tier needs a valid `tier` value and a `steps` array; each step needs `id`,
`instruction`. Missing optional fields default ("" / {}); a malformed built-in is dropped + warned at load,
never crashes.

## 4. The factory — a `train-recipe` workflow (mirrors `train-category`)

A self-contained workflow at `docs/superpowers/workflows/train-recipe.workflow.js`, run once per category.
**Args:** `{ category, description, killerSystems, rubric (the existing rubric JSON — the spine), toolCatalog
(a short list of the agent's real build tools for grounding) }`.

Phases (each mirrors a proven `train-category` stage):

1. **Sweep (build-angled).** Parallel research agents, but angled at *how to build* — distinct from the
   rubric sweep (which asked what separates good from generic; the rubric already encodes that). Angles:
   (a) build-order / workflow tutorials; (b) killer-system **implementation** in Roblox (how to actually wire
   a blend tree / IKControl / particle-layering / hit-reaction); (c) "why does my X look bad" critique
   threads; (d) a **dissect-the-rubric** agent that reads each criterion and proposes the build step that
   would satisfy it. Sources grounded in the creator-docs GitHub mirror + DevForum + YouTube transcripts.
2. **Distill.** Cluster the build techniques into tier-structured ordered steps; tag each step with the
   rubric criterion ids it addresses + the real tools + pitfalls. The rubric is passed in so the distiller
   maps steps → criteria.
3. **Coverage critic (keystone gate — the recipe's analog of the rubric back-test).** Deterministically
   compute which rubric criterion ids are NOT covered by any step (pure JS in the workflow). An LLM fill
   pass adds/extends steps to cover the gaps; loop until coverage ≈ 100% (bounded `MAX_FILL` rounds),
   flagging any criterion that is genuinely un-buildable with the current toolset (recorded in
   `coverage.uncovered`, not silently dropped). This is the guarantee that following the guide can clear the
   rubric.
4. **Above-generic critic (quality gate — mirrors the above-generic judge).** Each step is judged: does it
   teach deliberate systems-depth authoring, or generic tutorial filler the engine floor already produces?
   Reject/raise generic steps. Keeps the guide above-the-mean (the same mean-regression defense the rubric
   uses).
5. **Assemble.** Emit the build-guide JSON to the §3 schema — stable ids, fixed `order_index` (baseline →
   good → exceptional), coverage stats + sources in `provenance`.
6. **Critique (completeness).** Are all killer systems represented as build steps? Is the build order
   sensible (dependencies before dependents)? Overall assessment + survival/coverage summary.

**Returns** `{ category, guide, coverage, aboveGenericSurvival, completeness, provenance }`.

**Driver.** Run `train-recipe` for all 4 categories (locomotion, combat, environment, vfx) — either a thin
`train-recipes-all` driver that calls `workflow('train-recipe', {category, rubric, …})` per category (one
level of nesting, allowed), or 4 sequential invocations from the main loop. gui already has
`gui-design-quality`; the factory will additionally produce a `gui` build guide so all 5 categories are
covered uniformly by the new surface (the hand-authored skill stays as-is).

**Mean-regression risk** (the central risk, inherited from the rubric work) is mitigated by the same quartet,
re-pointed at authoring: rubric-as-spine (already above-generic-validated) → coverage-tie-to-criteria →
above-generic **step** critic → critique-source priority in the sweep.

## 5. Delivery plumbing (a mechanical mirror of the rubric path)

| New file | Mirrors | Role |
|---|---|---|
| `docs/superpowers/guides/buildguide.schema.json` | `rubrics/rubric.schema.json` | JSON schema |
| `docs/superpowers/guides/<cat>.guide.json` ×4 (+ `.md` + `<cat>-guide-report.md`) | `<cat>.rubric.json` (+ `.md` + pilot report) | the generated guides |
| `scripts/gen_builtin_buildguides.py` | `gen_builtin_rubrics.py` | embed guide JSON → Luau |
| `src/BuiltinBuildGuides.luau` (generated, do-not-edit) | `BuiltinRubrics.luau` | list of raw JSON strings |
| `src/BuildGuideCatalog.luau` (+ `BuildGuideCatalogSpec.luau`) | `RubricCatalog.luau` (+ Spec) | PURE: `validateGuide` / `render` / `catalogBlock` / `findByCategory` |
| `src/BuildGuideStore.luau` | `RubricStore.luau` | decode+validate once at construct; `catalogBlock()`; `resolve(category)` |
| `src/Tools/BuildGuides.luau` | `Tools/Rubrics.luau` | the `use_build_guide(category)` tool; parent-only; non-destructive |

**Wiring edits** (each mirrors the exact rubric wiring point):

- `src/Main.luau` — `BuildGuideStore.new()` into `deps.buildGuides` (mirrors `rubrics = RubricStore.new()`).
- `src/AgentLoop.luau` — thread `buildGuides` through the context type + constructor (mirrors the `rubrics`
  field at lines 38/106/305/332) and inject `buildGuides:catalogBlock()` into the leading preamble right
  after the rubric catalog (mirrors lines 131–133).
- `src/DevBridge.luau` — pass `deps.buildGuides` through (mirrors lines 101/148).
- `src/Tools/init.luau` — `require(script.BuildGuides)` and register its descriptors (mirrors lines 35/132).
  Parent-only: NOT added to the subagent/writer allowlists; a child's context carries no `buildGuides`, so
  the tool no-ops gracefully for a child (same contract as `use_rubric`).
- `src/RelaySpec.luau` — add `use_build_guide` to the parent-only relay manifest; the no-drift count goes
  15 → 16. The Spec must stay green (16/16).
- `src/SystemPrompt.luau` — add the tool one-liner (mirrors line 30), add a `# Build guides` catalog section
  marker (mirrors `# Quality rubrics` at line 93), and update the build flow (§6).

## 6. SystemPrompt — the build flow

When building an asset in a category that has a rubric, the documented flow becomes:

1. `use_rubric(category)` — the bar (what to hit).
2. `use_build_guide(category)` — the approach (tier-by-tier steps to reach the bar, each citing real tools).
3. Build to the highest tier you can, following the guide's steps in order.
4. `evaluate` → `refine-to-rubric` — grade against the rubric + capture, then close the gaps.

Plus a one-line update to the `refine-to-rubric` working skill (`src/BuiltinWorkingSkills.luau`): step 2
("build a first draft") becomes "draft using `use_build_guide(category)` to aim at the bar from the start."

## 7. Rendering (`use_build_guide` output)

`BuildGuideCatalog.render(guide)` produces markdown (mirrors `RubricCatalog.render`):

```
# Build guide: locomotion (v1.0) — targets the locomotion rubric (v1.0)
<overview>
Killer systems: <name — what (how)>, …

## Baseline — <goal>
1. <instruction>  [addresses: id, id]  [tools: add_keyframe, …]
   Pitfall: <pitfalls>
…
## Good — <goal>
…
## Exceptional — <goal>
…

Common pitfalls: <…>
Coverage: M/N rubric criteria addressed.
```

`catalogBlock()` (always-on preamble) is one compact line per guide, e.g.
`- locomotion — 12 steps across 3 tiers, covers 12/12 rubric criteria`.

## 8. Verification

- **Pure spec** `BuildGuideCatalogSpec` — `validateGuide` (good + malformed-dropped), `render` (tiers in
  order, criterion/tool annotations, coverage line), `catalogBlock` (one line per guide, "" when empty),
  `findByCategory` (normalized match + miss). Runnable from the bridge with no restart
  (`require(script.Parent.BuildGuideCatalogSpec).run()`).
- **`RelaySpec` no-drift** — 16/16 after adding `use_build_guide`.
- **`selene` 0/0**, **`rojo build` green** after every change.
- **Factory coverage gate** — each generated guide reports `coverage.criteria_addressed/criteria_total` in
  provenance; the target is full coverage (any `uncovered` entry is surfaced, not hidden).
- **Live bridge dogfood** — after `gen_builtin_buildguides.py` + hot-reload: `use_build_guide locomotion`
  renders the guide; confirm it pairs with `use_rubric locomotion` (both resolve, catalog block present in
  the preamble). Spot-check one guide for above-generic, actionable steps.

## 9. Scope & non-goals

- **In scope:** the §3 schema, the §4 factory + the 4 generated guides (locomotion, combat, environment,
  vfx) + a gui guide for uniform coverage, the §5 plumbing, the §6 SystemPrompt wiring, the §8 verification.
- **Out of scope (later):** user-authored guides / a `save_build_guide` (built-ins only in v1, mirroring
  rubrics); per-step exemplar images (the corpus scale-out is a separate lever); auto-running
  `refine-to-rubric` end-to-end on a real build as part of *this* deliverable (the surface + coverage gate
  are the primary proof; a full refine dogfood is a deeper, optional follow-up).
- **Out entirely:** changing the rubrics themselves; the judge-tightening lever (a separate session).

## 10. Risks

- **Generic / plausible-but-mediocre guide steps** — mitigated by the §4 above-generic step critic +
  rubric-as-spine + critique-source priority (the rubric's proven quartet, re-pointed at authoring).
- **Un-buildable criteria** (a rubric criterion no current tool can satisfy) — surfaced in
  `coverage.uncovered` rather than faked; a real signal for which tool to build next.
- **Plumbing drift** — every new module is a near-copy of a tested rubric-path file; `RelaySpec` no-drift +
  `BuildGuideCatalogSpec` + `selene`/`rojo` gate each step.
- **Factory cost** (4× a ~60-agent workflow) — accepted; run sequentially, each guide committed as it lands
  so a mid-run failure loses at most one category.
