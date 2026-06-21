# Studio Agent — Evaluate tool (Slice E) design

**Date:** 2026-06-21
**Status:** design approved in brainstorming; ready for a writing-plans pass. **No code yet.**
**Serves:** the project's north star — close the **capture → evaluate → refine** quality loop. With the
animation engine shipped (slice D), the agent can now BUILD locomotion; Evaluate grades it against the
delivered Locomotion rubric so the agent can refine to the pro bar.
**Builds on:** the shipped `RubricStore` + `use_rubric` (the rubric is already delivered into the plugin),
the rig/animation tools, and `get_tree`/`search`/`Script.Source` reads for structural evidence.
**Source rubric:** `docs/superpowers/rubrics/locomotion.rubric.md` (v1.1, 16 criteria — 2 baseline / 7 good /
7 exceptional). **Gap context:** §17 of `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md`
(the loop-session roadmap; this slice implements its gap #2).

---

## 0. Goal

A `evaluate` tool that grades a built locomotion **system** against the Locomotion rubric and returns a
**structured, per-criterion report** (tier + cited evidence + concrete fix) the agent uses to refine. The
single hard requirement that makes this real rather than vibes: **schema-enforced grading** — per-criterion
scores must be structured output, not free prose (the §17.2 gap).

---

## 1. The core insight (what the rubric actually grades)

The Locomotion rubric grades a locomotion **system's architecture**, NOT a single clip's appearance. Its
criteria are owned-velocity-driven blend trees, runtime foot IK, additive aim layering, pelvis/gait-phase
sway, acceleration tracking, etc. Every criterion's `evidence_required` is "a statement/dump showing [the
owned mechanism]"; captures are explicitly "credited toward full marks but not required." The rubric header
says: *"Text/structure-level grading; live capture grading is the loop session."*

**Implication:** Evaluate judges **structural + design-claim + (optional) visual** evidence — it is not a
capture-and-grade-the-look tool. A filmstrip of one clip (slice D's output) would correctly score mostly
FAIL against this rubric; the rubric is for grading a locomotion **system** the agent built.

---

## 2. Decisions (settled in brainstorming)

1. **Evidence model = structural + design + visual.** Evaluate auto-dumps structure (`get_tree` of the
   subject + relevant `Script.Source`), combines it with the agent's `design` claim summary, plus optional
   capture frames; the judge weighs **verifiable structural evidence over unverified claims** (external-
   verifier anchoring).
2. **Scope = the core grading loop only.** Build: structured-output support in `Anthropic.luau`; the
   `evaluate` tool (gather → grade → report); refine-loop wiring. **Defer** the peripheral §17 gaps:
   PropertyCatalog rig-class typed reads (#3 — not needed; existence + script logic suffice), exemplar-image
   store (#5), prioritized-Learnings overrides (#6), prompt-caching (#7), Studio rubric viewer (#8).
3. **Grading mechanism = forced `tool_choice` structured output + a prose-parse fallback.** Force a single
   `submit_grade` tool; if the CLIProxyAPI doesn't honor `tool_choice`, parse JSON from the returned text.

---

## 3. Architecture

A self-contained grading tool with a forced-schema sub-call (Approach A).

### New modules
- **`src/EvaluateReport.luau`** (pure; unit-testable):
  - `buildGradeTool(rubric)` → the `submit_grade` tool descriptor whose `input_schema` expects one grade per
    criterion (ids drawn from the rubric's criteria).
  - `validateGrades(raw, rubric)` → total coercion: align grades to the rubric's criteria, fill missing as
    `ungraded`, clamp tiers to the allowed set; never throws.
  - `renderReport(rubric, grades)` → a readable report: per-criterion tier glyph + criterion name + cited
    evidence + (for fail/partial) the rubric's `concrete_fix`; an overall header (X/N passing, killer-systems
    status) and a prioritized fix list.
  - Pure helpers behind each (schema build, tier glyph, sorting fails-first).
- **`src/Tools/Evaluate.luau`** (the tool): the `evaluate` descriptor + `runEvaluate` (orchestrates resolve →
  gather → grade → validate → render). Parent-only, non-destructive, **LOCAL** (see §6).

### Modified
- **`src/Anthropic.luau`** — a `requestStructured(messages, tool)` path: send `tools = { tool }` +
  `tool_choice = { type = "tool", name = tool.name }`; on success return the `tool_use.input` (validated
  JSON); if the assistant returned text instead (proxy ignored `tool_choice`), return `(nil, rawText)` so the
  caller falls back to JSON-from-text parsing. Reuses the existing send/retry/`encodeBody` machinery and the
  leading-preamble delivery (the proxy strips `system`).
- **`src/Tools/init.luau`** — register `evaluate`.
- **`src/SystemPrompt.luau`** — an "# Evaluating against the rubric" section: after building an asset in a
  rubric category (`use_rubric` first), call `evaluate` to grade it, then address each fail/partial's concrete
  fix and re-evaluate until the bar is met.
- **`src/Relay.luau` / `src/RelaySpec.luau`** — classify `evaluate` as LOCAL (it needs `context.rubrics` +
  `context.anthropic`, like `use_rubric`).

---

## 4. Data flow (`evaluate {category, subject?, design?, captures?}`)

1. **Resolve the rubric** via `context.rubrics` (`RubricStore.findByCategory`); unknown → list available.
2. **Gather evidence:**
   - *Structural (auto):* walk `subject` (an instance path; default = the agent's current selection, else a
     small note that none was given) collecting locomotion-relevant signal — instance classes/hierarchy
     (`Humanoid`/`Animator`/`IKControl`/`AnimationConstraint`/`Motor6D` presence, controller `Script`s) and
     the `Source` of scripts under `subject` + `StarterPlayer.StarterCharacterScripts` + `ServerScriptService`
     (length-capped, total budget-capped). Rendered as a text block.
   - *Design claim:* the agent's `design` string (its architectural summary of what it built).
   - *Visual (optional):* if `captures` is set, include a small set of capture frames (image blocks) as
     supporting evidence (v1: minimal — the agent may pass already-taken frames; auto-filming the live system
     needs playtest, the §17.4 limitation, deferred).
3. **Build the grade tool:** `EvaluateReport.buildGradeTool(rubric)`.
4. **Grade:** one `context.anthropic:requestStructured(messages, gradeTool)` call. `messages` = a leading
   grader instruction (*"You are a STRICT rubric grader. Grade each criterion fail/partial/pass against its
   evidence_required. Weight verifiable structural/code evidence over unverified design claims. Cite the
   specific evidence. Call submit_grade."*) + the rendered rubric + the evidence block (+ image blocks).
5. **Validate + render:** `validateGrades` → `renderReport` → return the report string to the agent. (If the
   structured call fell back to text, parse JSON from it; if that fails, return the raw text + a "structured
   grading unavailable" note so the agent still gets the substance.)

---

## 5. The grade schema (`submit_grade` input)

```
{
  grades: [
    { id: string,                       // a rubric criterion id (e.g. "loco-foot-ik-terrain")
      tier: "fail" | "partial" | "pass",
      towardFull: boolean,              // meets the exceptional/ceiling extras
      evidence: string,                 // the specific structural/design/visual evidence cited
      gap: string }                     // what's missing (for fail/partial; "" when pass+towardFull)
  ],
  summary: string                       // 1-2 sentence overall read
}
```

`renderReport` turns this into: an overall line (e.g. "11/16 pass, 3 partial, 2 fail; killer systems:
blend-tree PASS, foot-IK FAIL, additive-aim PASS, pelvis-sway PARTIAL"), then a fails-first list with each
criterion's tier, the cited evidence, and the rubric's `concrete_fix`.

---

## 6. Relay / run-context

`evaluate` is **LOCAL** (in `Relay.LOCAL_TOOLS`), like `use_rubric` — it needs the parent's `rubrics` +
`anthropic` deps, which the relayed server context does not carry. In edit / Server-view the structured call
uses the real `Anthropic` client directly. In client-play, `deps.anthropic` is the relay wrapper (only
`sendMessage`); v1 surfaces a clear "evaluate runs in edit / the Server view" message there rather than
routing structured calls through the relay (a noted follow-up). This matches the edit-first nature of the
rubric/capture work.

---

## 7. Error handling

- No `rubrics` in context (a child/relayed context) → "evaluate isn't available here" (mirrors `use_rubric`).
- Unknown `category` → list available rubrics.
- No `subject` and nothing selected → grade on `design` + captures alone, noting structural evidence was
  absent (so the judge weights claims as unverified).
- `requestStructured` HTTP failure → surface the error (reuse the client's transient classification).
- `tool_choice` not honored (text returned) → JSON-from-text parse; unparseable → return the raw text + a
  "structured grading unavailable; here is the prose evaluation" note (graceful degrade, never a hard fail).
- Malformed/partial structured output → `validateGrades` coerces (missing criteria → `ungraded`, bad tier →
  `ungraded`); never throws.
- Total: `Tools.dispatch` pcall-wraps the handler.

---

## 8. Testing / verification

- **`EvaluateReportSpec`** (in-Studio, pure): `buildGradeTool` schema shape (ids present, tier enum);
  `validateGrades` (coerces a malformed/partial grade set, fills missing ids as `ungraded`); `renderReport`
  (a synthetic grade set → expected sections: overall line, fails-first ordering, concrete-fix inclusion).
- **Static:** `selene` 0/0, `stylua`, `rojo build` green per task.
- **Bridge dogfood (the verification that matters):**
  1. **Discrimination test** — `evaluate {category="locomotion", design="<strong architecture: owned
     velocity-driven 2D blend tree + runtime foot IKControl + additive aim on Action priority + accel-driven
     pelvis sway>"}` should score most criteria PASS; `evaluate {design="<weak: one forward clip swapped by
     WalkSpeed on stock Animate>"}` should score the killer systems FAIL with the right concrete fixes. The
     grader must SEPARATE the two — this is the core acceptance signal.
  2. **Structural-evidence test** — build a tiny stub (a Script under the rig that reads velocity + an
     `IKControl` under the Animator) and confirm `evaluate {subject=<rig>, design=...}` cites the actual
     instances/source in its evidence (verifiable evidence beats claims).
  3. **LIVE-TEST (the key risk): does the CLIProxyAPI honor `tool_choice`?** Confirm `evaluate` returns
     schema-conformant structured grades (not the prose fallback). If the proxy strips/ignores `tool_choice`,
     confirm the prose-parse fallback still yields a usable report, and record the outcome.
- **Adversarial review** (Workflow) on the un-runnable grading logic, as with prior slices.

---

## 9. File structure

| File | New/Mod/Del | Responsibility |
|---|---|---|
| `src/EvaluateReport.luau` | **new** | Pure: `buildGradeTool`, `validateGrades`, `renderReport` + helpers. |
| `src/EvaluateReportSpec.luau` | **new** | In-Studio self-test for the pure report logic. |
| `src/Tools/Evaluate.luau` | **new** | The `evaluate` tool: resolve → gather evidence → grade → report. |
| `src/Anthropic.luau` | mod | `requestStructured(messages, tool)` (forced `tool_choice` + text fallback). |
| `src/Tools/init.luau` | mod | Register `evaluate`. |
| `src/SystemPrompt.luau` | mod | "# Evaluating against the rubric" section. |
| `src/Relay.luau` / `src/RelaySpec.luau` | mod | Classify `evaluate` LOCAL. |

---

## 10. Non-goals / future

- **Peripheral §17 gaps** (deferred): PropertyCatalog typed rig reads (#3), exemplar-image anchoring (#5),
  prioritized-Learnings overrides (#6 — the "loop that learns across iterations" upgrade), prompt-caching the
  active pack (#7), a Studio rubric viewer / category-onboard button (#8).
- **Client-play structured grading** (routing the forced-`tool_choice` call through the relay) — v1 is
  edit / Server-view.
- **Auto-filming the live locomotion system** as visual evidence — needs the server-only playtest filmstrip
  (§17.4); v1 uses optional agent-supplied captures.
- **A non-visual "plugin code quality" rubric category** (§17 boundary note) — a cheap later application of
  the same Evaluate engine once it exists.

---

## 11. Source-of-truth references

- Locomotion rubric: `docs/superpowers/rubrics/locomotion.rubric.md` (the criteria + evidence_required +
  concrete_fix this tool grades against).
- Loop-session gap roadmap: `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` §17
  (this slice = gap #2).
- Rubric delivery in-plugin: `src/RubricStore.luau`, `src/RubricCatalog.luau`, `src/Tools/Rubrics.luau`.
- Structured-output: Anthropic `tool_choice` (`{type:"tool", name}`) forcing a single tool call; the
  CLIProxyAPI `system`-stripping behavior (memory `studio-agent-model-connection`) is why grader instructions
  ride a leading message and why `tool_choice` honoring is a live-test.
