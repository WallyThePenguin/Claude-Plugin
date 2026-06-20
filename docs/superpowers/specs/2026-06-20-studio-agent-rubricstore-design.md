# Studio Agent — RubricStore (design)

**Date:** 2026-06-20
**Status:** design approved in brainstorm; no code yet.
**Serves:** the north star — push the quality ceiling. This is the FIRST loop-session piece: get the produced quality rubric INTO the live plugin so the agent builds TO the bar.
**Builds on:** the Locomotion pilot (`docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` §17 = the loop-session plugin-gap roadmap; this closes gap #1 "no rubric store"). The rubric artifact it delivers is `docs/superpowers/rubrics/locomotion.rubric.json` (v1.1).
**Memories:** `studio-agent-training-vision`, `studio-agent-north-star`, `studio-agent-model-connection`.

## Purpose

The training pipeline produces quality rubrics as repo artifacts, but the in-Studio agent has no way to load one — the audit confirmed zero rubric store, and §9 of the training architecture always called it a future addition. This piece adds the **delivery mechanism**: the agent sees which rubrics exist (always-on) and loads the full rubric on demand, so when it builds (e.g.) locomotion it builds to the rubric's highest tier instead of the generic default. It does NOT grade against the rubric yet (capture→evaluate is the next sub-project); it *delivers* the bar.

## Scope

- **In:** a `RubricStore` (built-ins only) + a pure `RubricCatalog` (+ spec self-test) + a `use_rubric(category)` tool + the v1.1 Locomotion rubric embedded as a built-in via a generator + preamble/SystemPrompt wiring.
- **Out (non-goals, scheduled later):** grading / an Evaluate tool / structured-output scoring (next sub-project); capture, rig dissection, animation filmstrip; a panel rubric viewer; in-Studio user-authored rubrics (save/delete); stored exemplar IMAGES (only URL refs ride the text). Does not modify rubric content.

## Architecture: mirror the skills system

The plugin already has the exact pattern this needs. Stores live in `deps` and inject a block into the **leading preamble** (the proxy strips `system`; see `AgentLoop.luau:105-124`). `SkillStore.catalogBlock()` puts a compact catalog always-on; `use_skill` returns the full body on demand. RubricStore copies this split — the right answer for rubrics because a full pack is too large to keep in context always-on (training-architecture §9 scaling caveat).

```
deps.rubrics:catalogBlock()  -> always-on compact index in the preamble (every Send)
use_rubric(category) tool    -> full rendered rubric on demand (only when building that category)
```

## Components (each one responsibility; mirrors the skills trio)

| File | Responsibility | Mirrors |
|---|---|---|
| `src/BuiltinRubrics.luau` | `list` = array of rubric JSON strings (generated, see §Embedding) | `BuiltinRecipes` |
| `src/RubricCatalog.luau` | PURE: `validateRubric`, `render(rubric)`, `catalogBlock(rubrics)`, `findByCategory`. No DataModel → unit-testable | `SkillCatalog` |
| `src/RubricCatalogSpec.luau` | in-Studio round-trip self-test | `SkillCatalogSpec`/`MemorySpec` |
| `src/RubricStore.luau` | wraps built-ins: decodes the JSON strings (HttpService), validates+drops malformed, exposes `catalogBlock()` / `resolve(category)` / `listBuiltins()` | `SkillStore` |
| `src/Tools/Rubrics.luau` | the `use_rubric(category)` tool (parent-only, non-destructive) | `Tools/Skills.luau` |
| `scripts/gen_builtin_rubrics.py` | reads `docs/superpowers/rubrics/*.rubric.json` → emits `BuiltinRubrics.luau` | (build step) |

**Why JSON strings, not hand-written Luau tables (the call):** `BuiltinRubrics` embeds each rubric as its raw JSON text inside a Luau long-bracket string; `RubricStore` decodes via `HttpService:JSONDecode` at construction. This sidesteps Luau-table-serialization + escaping/unicode issues entirely, keeps the embedded rubric byte-faithful to the produced artifact, and keeps `RubricCatalog` pure (the service-touching decode lives in `RubricStore`, not the catalog). The generator picks a long-bracket level not present in the text.

## Data shapes

- **Stored rubric** = exactly the `rubric.schema.json` shape (module, version, system_module, criteria[] with id/order_index/tier/statement/grading/evidence_required/concrete_fix/exemplar_refs, + judge/backtest/provenance metadata). No schema change.
- **Catalog block (always-on, compact)** — one line per category so context stays small:
  ```
  # Quality rubrics (build to the bar)
  Curated above-the-mean quality rubrics per asset category. BEFORE building an asset in a
  listed category, call use_rubric(category) to load its full tiered rubric, then build to the
  highest tier you can and address each criterion's concrete_fix.

  - locomotion — 16 criteria (2 baseline / 7 good / 7 exceptional)
  ```
- **Rendered rubric (use_rubric output)** — the full tiered text: per tier, each criterion's statement · why-above-generic · pass/partial/fail · evidence_required · concrete_fix · exemplar_refs. (Same content as `locomotion.rubric.md`, produced by `RubricCatalog.render`.)

## Data flow

1. Every Send: `AgentLoop` appends `rubrics:catalogBlock()` to the leading preamble (one more block after memory + skills — `AgentLoop.luau:119-124` pattern).
2. User asks the agent to build locomotion → the agent sees the catalog → calls `use_rubric("locomotion")`.
3. `Tools/Rubrics.luau` → `RubricStore.resolve("locomotion")` → `RubricCatalog.render(rubric)` → the full rubric text returns as the tool result.
4. The agent builds to the highest tier, addressing the criteria. (Grading the result is the next sub-project.)

## Error handling

- **Built-in load:** each JSON string `pcall`-decoded then `RubricCatalog.validateRubric`'d at construction; a malformed one is dropped + `warn`'d (never crashes the plugin) — mirrors `SkillStore.buildBuiltins`.
- **`use_rubric` unknown category:** returns a helpful error naming the valid categories (mirrors `SkillStore.resolve`'s unknown-skill message).
- **Nil-safety:** `deps.rubrics` is optional; `AgentLoop`/`toolContext` guard it like `memory`/`skills`, so edit / Server-view / relay paths are byte-unchanged when it's absent. `use_rubric` nil-guards `context.rubrics` for subagents (parent-only, like `use_skill`).

## Testing

- **`RubricCatalogSpec`** (pure, in-Studio self-test): validateRubric (good + each missing-required + bad-tier), render (contains tier headers + a criterion's fix), catalogBlock (line per rubric + counts), findByCategory (hit/miss). Pattern = `SkillCatalogSpec`.
- **Static (here):** `selene src` 0 errors/0 warnings, `stylua --check src`, `rojo build` clean; `python scripts/gen_builtin_rubrics.py` runs and the emitted module round-trips (decode the embedded JSON, re-validate).
- **Live (user, in Studio):** fresh chat shows the rubric catalog in context; `use_rubric("locomotion")` returns the full rubric; the agent consults it when asked to build locomotion. (Per the plugin's split: the USER runs Studio live tests.)

## Module map (new/changed)

- New: `src/BuiltinRubrics.luau`, `src/RubricCatalog.luau`, `src/RubricCatalogSpec.luau`, `src/RubricStore.luau`, `src/Tools/Rubrics.luau`, `scripts/gen_builtin_rubrics.py`.
- Changed: `src/init.server.luau` (deps `rubrics = RubricStore.new(plugin)`), `src/AgentLoop.luau` (inject `rubrics:catalogBlock()` into the preamble + add `rubrics` to `toolContext`), `src/Tools/init.luau` (register `use_rubric`), `src/SystemPrompt.luau` (document `use_rubric` + the build-to-the-bar workflow). No `Config` change (caps are `RubricCatalog` constants).

## Risks & mitigations

- **Agent forgets to consult the rubric:** the always-on catalog text + a SystemPrompt instruction make consulting it the default (same reliance the skills system already works under).
- **Embedded rubric drifts from the produced JSON:** the generator regenerates `BuiltinRubrics` from the JSON — never hand-edit it; re-run after any rubric change.
- **Context cost:** only the compact catalog is always-on; the full rubric loads on demand (the whole point of the split).
- **selene/stylua cleanliness:** match existing module style (`--!strict`, the store/catalog idioms already in `SkillStore`/`SkillCatalog`).

## Next (subsequent loop-session pieces, not here)

Structured-output grading (the Evaluate tool, §17 gap #2) → PropertyCatalog rig classes (gap #3) → animation filmstrip capture (gap #4) → then the live capture→evaluate→refine loop grades real builds against this delivered rubric.
