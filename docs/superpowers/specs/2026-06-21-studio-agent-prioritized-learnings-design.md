# Studio Agent — Prioritized Learnings design

**Date:** 2026-06-21
**Status:** design approved in brainstorming; ready for a writing-plans pass. **No code yet.**
**Serves:** §17 gap #6 of the loop-session roadmap — turn the shipped capture→evaluate→refine loop into one
that **LEARNS across iterations**. After `evaluate` (slice E) catches a miss and the agent fixes it, the agent
records a durable per-category **learning** so the same mistake never recurs on the next build.
**Builds on:** the `Memory` store/preamble pattern (`src/Memory.luau`), the `RubricStore`/`use_rubric` +
`evaluate` quality loop, and the always-on leading-preamble delivery (`AgentLoop` — the proxy strips `system`).

---

## 0. Goal

Per-category, high-priority **learnings** that the agent records (a `learn` tool), that ride the always-on
preamble as override-priority guidance for that category, and that `evaluate` folds into its grade prompt — so
a lesson learned once (e.g. "locomotion builds fail without runtime foot IK") is applied up front on every
later build, anywhere.

---

## 1. The core idea

A **learning** is a durable, confirmed correction for an asset CATEGORY (the rubric categories: `locomotion`,
etc.) — distinct from general `Memory` (which is this-game architecture / global techniques+preferences).
Learnings are the quality loop's accumulated, category-scoped corrections. They are:

- **Global** — a category-quality lesson is universal technique, carried to every place (like Memory's `global`
  scope), not place-specific.
- **High-priority** — delivered in a prominently-labeled preamble section the agent applies FIRST.
- **Agent-recorded** — the agent calls `learn(category, text)` when it discovers a durable lesson (prompted by
  `evaluate`'s findings or user feedback). Deliberate and low-noise: a learning is a confirmed lesson, not a
  transient failure (so `evaluate` does NOT auto-write them).

---

## 2. Decisions (settled in brainstorming)

1. **Source = agent records; preamble delivers.** A `learn` tool; learnings ride the preamble; `evaluate`
   reads the graded category's learnings into its grade prompt. (Not evaluate-auto-write, which records
   transient failures and clutters.)
2. **Storage = a dedicated `LearningsStore`** (mirrors `Memory`'s pure+instance pattern), keyed by category,
   GLOBAL, capped per category. Keeps `Memory` clean; the §17 "dedicated store" option.
3. **Scope = global** (universal per-category technique). Flagged for the user; the spec proceeds with global.

---

## 3. Architecture

### New modules
- **`src/Learnings.luau`** — mirrors `Memory.luau`:
  - Pure helpers (no self/DataModel; unit-testable): `normalizeText` (trim + UTF-8-safe truncate to
    `MAX_TEXT`), `normalizeCategory` (lower+trim; nil if empty), `addTo(entries, text, now)` (append with
    `id = max+1`, FIFO-drop oldest over `MAX_PER_CATEGORY`), `forgetFrom(entries, id)`, `normalizeEntry(raw)`
    (corrupt-blob defense: finite positive-integer id + non-empty text), `renderCategory(entries)`.
  - Instance (live store, `new(plugin)`): `add(category, text)`, `forget(category, id)`, `list(category)`,
    `categories()` (the non-empty category names), `promptBlock()` (renders ALL categories, capped),
    `forCategory(category)` (one category's rendered block, for `evaluate`). Persisted via
    `plugin:SetSetting` under a per-category key (`StudioAgent_learnings_<category>`); an index key
    (`StudioAgent_learnings_index`) lists the known categories so `promptBlock`/`categories` can enumerate
    without scanning all settings.
  - Caps: `MAX_PER_CATEGORY` (e.g. 15) × `MAX_TEXT` (e.g. 280). FIFO per category.
- **`src/LearningsSpec.luau`** — in-Studio pure self-test (add/cap/forget/render/normalize/corrupt-blob).
- **`src/Tools/Learnings.luau`** — `learn {category, text}` + `unlearn {category, id}`. Parent-only,
  non-destructive (thin wrappers over `context.learnings`, nil-guarded like the Memory tools).

### Modified
- **`src/Tools/init.luau`** — register `learn` + `unlearn`.
- **`src/init.server.luau`** — `deps.learnings = Learnings.new(plugin)`.
- **`src/AgentLoop.luau`** — thread `learnings` into the leading preamble (a "# Priority learnings" block AFTER
  the rubric catalog and memory) and into the tool `context` (so the tools + `evaluate` reach it).
- **`src/Tools/Evaluate.luau`** — if `context.learnings` is present, fold the graded category's learnings
  (`learnings:forCategory(category)`) into the grade prompt as "established corrections to weight".
- **`src/SystemPrompt.luau`** — a "# Priority learnings" note: apply any listed learnings for the category
  FIRST; after a refine where `evaluate` caught something you then fixed, `learn(category, <the durable
  lesson>)` so it never recurs; `unlearn` a stale one. Distinguish from `remember` (general memory).
- **`src/Relay.luau` / `src/RelaySpec.luau`** — classify `learn`/`unlearn` LOCAL (need the `learnings` dep,
  like `remember`/`use_rubric`).

---

## 4. Data flow

Agent builds in a category → `evaluate` flags a miss → agent fixes it → agent `learn("locomotion", "owned
velocity-driven blend + runtime foot IK are required; the grader fails builds without them")` → persisted to
the `locomotion` bucket (+ the index). **Next build, any place:** `Learnings.promptBlock()` injects the
"# Priority learnings" section (always-on, capped) so the agent applies the lesson up front; `evaluate` folds
the same category's learnings into its grade prompt. `unlearn(category, id)` drops a stale lesson.

---

## 5. Delivery + override semantics

- **Placement:** a dedicated `# Priority learnings (apply these first)` block in the leading preamble, AFTER
  the rubric catalog + memory (so it reads as the most specific, highest-priority guidance).
- **Phrasing:** "Lessons you confirmed in past builds — apply the ones for what you're building FIRST; they
  override your defaults for that category."
- **Bounded:** capped per category (FIFO) so the always-on injection stays small. `promptBlock()` returns ""
  when empty (inject nothing).

---

## 6. Error handling

Mirrors `Memory`: `normalizeText` nil-guards + UTF-8-safe truncates; `normalizeCategory` rejects empty;
`normalizeEntry` drops corrupt/hand-edited rows (NaN/inf/float/zero/negative id, non-string text); `loadBucket`
re-normalizes + de-dups ids + caps; the index is rebuilt defensively (a category with an empty/missing bucket
is skipped). Tools nil-guard `context.learnings` (graceful no-op for a child/relayed context) and validate a
present-but-invalid category/id. Total (dispatch pcall-wraps).

---

## 7. Testing / verification

- **`LearningsSpec`** (in-Studio, pure): `addTo` (append + FIFO cap + id scheme), `forgetFrom`, `normalizeText`
  (truncate/UTF-8), `normalizeCategory`, `normalizeEntry` (corrupt-blob rejection), `renderCategory`.
- **Static:** `selene` 0/0, `stylua`, `rojo build` green per task.
- **Bridge dogfood:** `learn {category:"locomotion", text:"..."}` ×2 → confirm both ride the preamble (drive a
  `prompt` and check the agent cites them, or read the rendered preamble via `luau`/a debug accessor) → run
  `evaluate {category:"locomotion", design:"..."}` and confirm the grade prompt referenced the learnings (or
  at least that `forCategory` returns them) → `unlearn` one → confirm it's gone. Plus the `LearningsSpec` N/N
  in the logs, and `RelaySpec` still green (no-drift, `learn`/`unlearn` classified LOCAL).
- **Adversarial review** (Workflow) on the un-runnable store/preamble logic, as with prior slices.

---

## 8. File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/Learnings.luau` | **new** | Category-keyed global learnings store: pure helpers + instance + `promptBlock`/`forCategory`. |
| `src/LearningsSpec.luau` | **new** | In-Studio pure self-test. |
| `src/Tools/Learnings.luau` | **new** | `learn` + `unlearn` tools. |
| `src/Tools/init.luau` | mod | Register `learn`/`unlearn`. |
| `src/init.server.luau` | mod | `deps.learnings`. |
| `src/AgentLoop.luau` | mod | Preamble block + tool-context thread. |
| `src/Tools/Evaluate.luau` | mod | Fold the graded category's learnings into the grade prompt. |
| `src/SystemPrompt.luau` | mod | "# Priority learnings" guidance. |
| `src/Relay.luau` / `src/RelaySpec.luau` | mod | Classify `learn`/`unlearn` LOCAL. |

---

## 9. Non-goals / future

- **A Studio Learnings viewer panel** (mirroring the Memory/Skills viewers) — defer; v1 manages via the tools.
- **Evaluate-auto-written learnings** — rejected (transient-failure noise); the agent records deliberately.
- **Per-game learnings** — v1 is global; a place-specific scope could be added later if needed.
- **Calibration / human-audit of learnings, exemplar anchoring (§17 #5), prompt-caching (#7)** — separate gaps.
- **Cross-category / system-module learnings** (the training-vision's shared System Modules) — later.

---

## 10. Source-of-truth references

- The pattern this mirrors: `src/Memory.luau` (pure+instance, `promptBlock`, `SetSetting` persistence, the
  corrupt-blob defense) and `src/Tools/Memory.luau`.
- The loop it completes: `evaluate` (`src/Tools/Evaluate.luau`) + the Locomotion rubric +
  `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` §17 gap #6.
- Preamble delivery (proxy strips `system`): memory `studio-agent-model-connection`; `AgentLoop` builds the
  leading preamble from SystemPrompt + memory + skills + rubric catalog.
