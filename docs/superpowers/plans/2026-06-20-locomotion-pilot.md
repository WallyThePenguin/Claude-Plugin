# Locomotion Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce + validate a real, above-the-mean **Locomotion quality rubric** by authoring a reusable, category-parameterized research/grading Workflow (`train-category`) and running it on Locomotion in Claude Code.

**Architecture:** A single self-contained Workflow script orchestrates LLM agents through the spec's pipeline (multi-modal sweep → distill → above-generic judge → assemble → scoring-bias check → discrimination back-test → GEPA-style self-optimization → completeness critic). The script is **pure orchestration + pure helpers** and returns structured data; the *main session* writes the artifact files (the Workflow sandbox has no filesystem). The only deterministic, unit-tested code is the rubric JSON schema + a stdlib Python validator. Everything agent-driven is verified by one real integration run against the spec's §12 acceptance gate.

**Tech Stack:** Claude Code Workflow tool (JS orchestration script, run via `Workflow({scriptPath, args})`); Python 3 stdlib (rubric validator — matches the sidecar's pure-stdlib constraint); JSON Schema (rubric shape). No new runtime deps.

**Source spec:** `docs/superpowers/specs/2026-06-20-studio-agent-locomotion-pilot-design.md` (§3 deliverables, §4 schema, §5 sources, §7 pipeline, §8 self-optimization, §9 judge hardening, §12 acceptance, §14 open questions).

---

## Domain-adaptation note (read first)

- **TDD applies** to Task 1–2 (rubric schema + validator): real failing-test-first, deterministic.
- **Build-then-integration-verify applies** to Task 3–7 (the Workflow script): the LLM stages can't be cheaply unit-run in isolation, and partial runs cost real tokens. Each stage task is *build + commit*; correctness is proven by the single real run in Task 9 against the §12 acceptance criteria in Task 11. The Workflow tool parses the script on invoke (syntax errors throw there), and supports `resumeFromRunId` so re-runs after a fix re-execute only changed stages.
- **The main session writes artifacts** from the Workflow's returned data (the sandbox has no fs; this also matches the HANDOFF gotcha "extract from the returned schema result and write yourself for determinism").

---

## File structure

- Create: `docs/superpowers/rubrics/rubric.schema.json` — JSON Schema for a category rubric (spec §4). One responsibility: the on-disk rubric shape.
- Create: `scripts/validate_rubric.py` — stdlib structural validator (no deps). One responsibility: assert a rubric file matches the schema.
- Create: `scripts/test_validate_rubric.py` — unittest for the validator.
- Create: `docs/superpowers/workflows/train-category.workflow.js` — the reusable category-parameterized pipeline. The centerpiece.
- Create: `docs/superpowers/rubrics/locomotion.config.json` — the Locomotion run args (the only category-specific input).
- Produced by the run (Task 10–11): `docs/superpowers/rubrics/locomotion.rubric.json`, `docs/superpowers/rubrics/locomotion.rubric.md`, `docs/superpowers/rubrics/locomotion-pilot-report.md`.

---

## Task 1: Rubric JSON Schema

**Files:**
- Create: `docs/superpowers/rubrics/rubric.schema.json`

- [ ] **Step 1: Write the schema file**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Category Quality Rubric",
  "type": "object",
  "required": ["module", "version", "system_module", "criteria"],
  "properties": {
    "module": { "type": "string" },
    "version": { "type": "string" },
    "date": { "type": "string" },
    "system_module": { "type": "string" },
    "criteria": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": ["id", "order_index", "tier", "statement", "above_generic_rationale", "grading", "evidence_required", "concrete_fix"],
        "properties": {
          "id": { "type": "string" },
          "order_index": { "type": "number" },
          "tier": { "type": "string", "enum": ["baseline", "good", "exceptional"] },
          "system_module": { "type": "string" },
          "statement": { "type": "string" },
          "above_generic_rationale": { "type": "string" },
          "grading": {
            "type": "object",
            "required": ["pass", "partial", "fail"],
            "properties": {
              "pass": { "type": "string" },
              "partial": { "type": "string" },
              "fail": { "type": "string" }
            }
          },
          "evidence_required": { "type": "string" },
          "concrete_fix": { "type": "string" },
          "exemplar_refs": { "type": "array", "items": { "type": "string" } },
          "provenance": {
            "type": "object",
            "properties": {
              "sources": { "type": "array", "items": { "type": "string" } },
              "confidence": { "type": "string" }
            }
          }
        }
      }
    },
    "judge": { "type": "object" },
    "backtest": { "type": "object" },
    "scoring_bias": { "type": "object" },
    "provenance": { "type": "object" }
  }
}
```

- [ ] **Step 2: Verify it is valid JSON**

Run: `python -c "import json; json.load(open('docs/superpowers/rubrics/rubric.schema.json')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/rubrics/rubric.schema.json
git commit -m "feat: rubric JSON schema (training pilot)"
```

---

## Task 2: Rubric validator (TDD, Python stdlib)

**Files:**
- Create: `scripts/validate_rubric.py`
- Test: `scripts/test_validate_rubric.py`

- [ ] **Step 1: Write the failing test**

```python
# scripts/test_validate_rubric.py
import unittest
from validate_rubric import validate

GOOD = {
    "module": "locomotion", "version": "1", "system_module": "locomotion",
    "criteria": [{
        "id": "loco-good-blendtree", "order_index": 1, "tier": "good",
        "statement": "Locomotion warps by speed AND direction via a blend tree.",
        "above_generic_rationale": "Default Roblox plays one forward loop.",
        "grading": {"pass": "blend tree present", "partial": "speed only", "fail": "single loop"},
        "evidence_required": "strafing shows distinct side motion",
        "concrete_fix": "add a 2D blend space keyed to velocity"
    }]
}

class T(unittest.TestCase):
    def test_good_rubric_passes(self):
        ok, errors = validate(GOOD)
        self.assertTrue(ok, errors)

    def test_missing_criteria_fails(self):
        ok, errors = validate({"module": "x", "version": "1", "system_module": "x"})
        self.assertFalse(ok)

    def test_bad_tier_fails(self):
        bad = {**GOOD, "criteria": [{**GOOD["criteria"][0], "tier": "amazing"}]}
        ok, errors = validate(bad)
        self.assertFalse(ok)

    def test_missing_grading_field_fails(self):
        bad = {**GOOD, "criteria": [{**GOOD["criteria"][0], "grading": {"pass": "x"}}]}
        ok, errors = validate(bad)
        self.assertFalse(ok)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd scripts && python -m unittest test_validate_rubric -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'validate_rubric'`

- [ ] **Step 3: Write the validator**

```python
# scripts/validate_rubric.py
"""Stdlib structural validator for a category rubric (matches rubric.schema.json)."""
import json
import sys

TIERS = {"baseline", "good", "exceptional"}
TOP_REQUIRED = ["module", "version", "system_module", "criteria"]
CRIT_REQUIRED = ["id", "order_index", "tier", "statement",
                 "above_generic_rationale", "grading", "evidence_required", "concrete_fix"]
GRADING_REQUIRED = ["pass", "partial", "fail"]


def validate(rubric):
    errors = []
    if not isinstance(rubric, dict):
        return False, ["rubric is not an object"]
    for k in TOP_REQUIRED:
        if k not in rubric:
            errors.append(f"missing top-level field: {k}")
    crits = rubric.get("criteria")
    if not isinstance(crits, list) or not crits:
        errors.append("criteria must be a non-empty array")
        return (not errors), errors
    seen_ids = set()
    for i, c in enumerate(crits):
        if not isinstance(c, dict):
            errors.append(f"criterion {i} is not an object")
            continue
        for k in CRIT_REQUIRED:
            if k not in c:
                errors.append(f"criterion {i} missing: {k}")
        if c.get("tier") not in TIERS:
            errors.append(f"criterion {i} bad tier: {c.get('tier')}")
        cid = c.get("id")
        if cid in seen_ids:
            errors.append(f"duplicate criterion id: {cid}")
        seen_ids.add(cid)
        g = c.get("grading")
        if not isinstance(g, dict) or any(k not in g for k in GRADING_REQUIRED):
            errors.append(f"criterion {i} grading must have pass/partial/fail")
    return (not errors), errors


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        ok, errors = validate(json.load(f))
    if ok:
        print(f"VALID: {path}")
        sys.exit(0)
    print(f"INVALID: {path}")
    for e in errors:
        print("  -", e)
    sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd scripts && python -m unittest test_validate_rubric -v`
Expected: PASS (4 tests OK)

- [ ] **Step 5: Commit**

```bash
git add scripts/validate_rubric.py scripts/test_validate_rubric.py
git commit -m "feat: stdlib rubric validator + tests"
```

---

## Task 3: Workflow skeleton — meta, args/config, pure helpers, schemas

**Files:**
- Create: `docs/superpowers/workflows/train-category.workflow.js`

- [ ] **Step 1: Write the skeleton (meta + config + pure helpers + schemas + empty body)**

```javascript
export const meta = {
  name: 'train-category',
  description: 'Build + validate an above-the-mean quality rubric for one asset category (sweep -> distill -> above-generic judge -> assemble -> bias-check -> discrimination back-test -> self-optimize -> completeness critic)',
  phases: [
    { title: 'Sweep' },
    { title: 'Distill' },
    { title: 'Judge' },
    { title: 'Assemble' },
    { title: 'Harden' },
    { title: 'Critique' },
  ],
}

// ---- args: the ONLY category-specific input (keeps the engine category-general) ----
const cfg = args || {}
const CATEGORY = cfg.category || 'locomotion'
const DESCRIPTION = cfg.description || 'character locomotion / movement animation'
const KILLER = cfg.killerSystems || []
const MEAN = cfg.meanArtifact || { name: 'generic default', description: 'what a beginner ships by default' }
const GREAT_HINT = cfg.greatArtifactHint || 'a top, award-quality example'
const MAX_OPT = cfg.maxOptRounds || 3
const SEPARATION_MIN = cfg.separationMin || 0.35

// ---- pure helpers (deterministic; aggregate score in [0,1], higher tiers weighted more) ----
const TIER_W = { baseline: 0, good: 1, exceptional: 2 }
const SCORE_V = { pass: 1, partial: 0.5, fail: 0 }
function aggregate(rows) {
  let num = 0, den = 0
  for (const r of (rows || [])) {
    const w = (TIER_W[r.tier] ?? 0) + 1
    num += w * (SCORE_V[r.score] ?? 0); den += w
  }
  return den ? num / den : 0
}
function separation(meanRows, greatRows) {
  const m = aggregate(meanRows), g = aggregate(greatRows)
  return { mean: m, great: g, gap: g - m, pass: (g - m) >= SEPARATION_MIN && m <= 0.5 && g >= 0.7 }
}

// ---- schemas ----
const FINDINGS_SCHEMA = { type: 'object', required: ['techniques'], properties: {
  angle: { type: 'string' },
  techniques: { type: 'array', items: { type: 'object', required: ['technique'], properties: {
    technique: { type: 'string' }, tier_hint: { type: 'string' },
    why_above_generic: { type: 'string' }, source: { type: 'string' } } } } } }

const CRITERIA_SCHEMA = { type: 'object', required: ['criteria'], properties: {
  criteria: { type: 'array', items: { type: 'object', required: ['id', 'tier', 'statement'], properties: {
    id: { type: 'string' }, tier: { type: 'string' }, statement: { type: 'string' },
    above_generic_rationale: { type: 'string' }, evidence_required: { type: 'string' },
    concrete_fix: { type: 'string' }, sources: { type: 'array', items: { type: 'string' } } } } } } }

const VERDICT_SCHEMA = { type: 'object', required: ['id', 'verdict'], properties: {
  id: { type: 'string' }, verdict: { type: 'string' },
  reason: { type: 'string' }, raised_statement: { type: 'string' } } }

const GRADING_OBJ = { type: 'object', required: ['pass', 'partial', 'fail'], properties: {
  pass: { type: 'string' }, partial: { type: 'string' }, fail: { type: 'string' } } }

const RUBRIC_SCHEMA = { type: 'object', required: ['module', 'criteria'], properties: {
  module: { type: 'string' }, version: { type: 'string' },
  criteria: { type: 'array', items: { type: 'object',
    required: ['id', 'order_index', 'tier', 'statement', 'grading', 'evidence_required', 'concrete_fix'], properties: {
      id: { type: 'string' }, order_index: { type: 'number' }, tier: { type: 'string' },
      system_module: { type: 'string' }, statement: { type: 'string' },
      above_generic_rationale: { type: 'string' }, grading: GRADING_OBJ,
      evidence_required: { type: 'string' }, concrete_fix: { type: 'string' },
      exemplar_refs: { type: 'array', items: { type: 'string' } },
      provenance: { type: 'object', properties: {
        sources: { type: 'array', items: { type: 'string' } }, confidence: { type: 'string' } } } } } } } }

const GRADE_SCHEMA = { type: 'object', required: ['rows'], properties: {
  rows: { type: 'array', items: { type: 'object', required: ['id', 'tier', 'score'], properties: {
    id: { type: 'string' }, tier: { type: 'string' }, score: { type: 'string' },
    evidence: { type: 'string' } } } } } }

const OPT_SCHEMA = { type: 'object', required: ['rewritten'], properties: {
  rewritten: { type: 'array', items: { type: 'object', required: ['id', 'statement'], properties: {
    id: { type: 'string' }, statement: { type: 'string' }, above_generic_rationale: { type: 'string' },
    grading: GRADING_OBJ, evidence_required: { type: 'string' }, concrete_fix: { type: 'string' },
    change_reason: { type: 'string' } } } } } }

const CRITIQUE_SCHEMA = { type: 'object', required: ['assessment'], properties: {
  covered: { type: 'array', items: { type: 'string' } },
  missing: { type: 'array', items: { type: 'string' } },
  survival_rate: { type: 'number' }, assessment: { type: 'string' } } }

// ---- body (stages added in Tasks 4-7) ----
return { category: CATEGORY, todo: 'stages not yet implemented' }
```

- [ ] **Step 2: Verify the file is present and is the only return for now**

Run: `git status --short docs/superpowers/workflows/train-category.workflow.js`
Expected: the file shows as added/untracked.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/workflows/train-category.workflow.js
git commit -m "feat: train-category workflow skeleton (config + helpers + schemas)"
```

---

## Task 4: Sweep + Distill stages

**Files:**
- Modify: `docs/superpowers/workflows/train-category.workflow.js` (replace the `// ---- body` placeholder return)

- [ ] **Step 1: Replace the placeholder return with the Sweep + Distill stages**

Replace the final two lines from Task 3 (`// ---- body ...` and `return { category: CATEGORY, todo: ... }`) with:

```javascript
phase('Sweep')
const ANGLES = [
  { key: 'critique', prompt: `Search the Roblox DevForum and the web for CRITIQUE / feedback threads about ${DESCRIPTION}. Critique threads state what separates GOOD from generic — prioritize them. Extract concrete TECHNIQUES that distinguish above-the-mean ${CATEGORY} from the default, each with a tier_hint (baseline/good/exceptional), why it beats generic, and the source URL.` },
  { key: 'tutorial', prompt: `Search tutorials + create.roblox.com and the Roblox creator-docs GitHub mirror for how ${DESCRIPTION} is built well (for locomotion: Animator/AnimationTrack, IKControl, AnimationConstraint, blend logic). Extract techniques with tier_hint, why-above-generic, and source URL.` },
  { key: 'video', prompt: `Find YouTube tutorials/breakdowns on ${DESCRIPTION} technique and read their transcripts (search, then read captions). Extract craft techniques pros use beyond the default, each with tier_hint and source URL.` },
  { key: 'showcase', prompt: `Find top showcase / award-quality Roblox examples of ${DESCRIPTION} plus teardown writeups describing what makes them exceptional. Extract the distinguishing techniques, each with tier_hint and source URL.` },
]
const sweep = (await parallel(ANGLES.map(a => () =>
  agent(a.prompt, { label: `sweep:${a.key}`, phase: 'Sweep', schema: FINDINGS_SCHEMA })
))).filter(Boolean)
const allTechniques = sweep.flatMap(s => s.techniques || [])
log(`Sweep: ${allTechniques.length} techniques across ${sweep.length} angles`)

phase('Distill')
const distilled = await agent(
  `Cluster these ${CATEGORY} techniques into concrete, gradable candidate CRITERIA organized by tier (baseline/good/exceptional). Each criterion must check SYSTEMS DEPTH, not surface presence (e.g. not "has an animation" but "locomotion warps by speed AND direction via a blend tree"). Merge duplicates. Ensure the known killer systems are represented where evidence supports them: ${JSON.stringify(KILLER)}.\n\nTECHNIQUES:\n${JSON.stringify(allTechniques, null, 1)}`,
  { label: 'distill', phase: 'Distill', schema: CRITERIA_SCHEMA })
log(`Distilled ${distilled.criteria.length} candidate criteria`)

return { category: CATEGORY, candidates: distilled.criteria, techniques: allTechniques.length }
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/workflows/train-category.workflow.js
git commit -m "feat: train-category sweep + distill stages"
```

---

## Task 5: Above-generic Judge + Assemble stages

**Files:**
- Modify: `docs/superpowers/workflows/train-category.workflow.js` (replace the Task 4 temporary return)

- [ ] **Step 1: Replace the Task 4 `return { category: CATEGORY, candidates: ... }` line with the Judge + Assemble stages**

```javascript
phase('Judge')
// above-generic judge: 3 skeptical votes per criterion; reject anything default Roblox already does
const judged = (await parallel(distilled.criteria.map(c => () =>
  parallel([0, 1, 2].map(i => () =>
    agent(`ABOVE-GENERIC JUDGE. Default/generic Roblox ${CATEGORY} gives a baseline for free. For this candidate criterion decide: does DEFAULT Roblox already do this? If yes it is the FLOOR -> verdict "reject". If only slightly above -> "raise" and give a tougher raised_statement. If it genuinely beats the default -> "keep". Be skeptical; default to "reject" when unsure.\n\nCRITERION: ${JSON.stringify(c)}`,
      { label: `judge:${c.id}#${i}`, phase: 'Judge', schema: VERDICT_SCHEMA }))
  ).then(votes => ({ c, votes: votes.filter(Boolean) }))
))).filter(Boolean)

const survivors = []
let rejected = 0
for (const j of judged) {
  const rej = j.votes.filter(x => x.verdict === 'reject').length
  if (rej >= 2) { rejected++; continue }
  const raise = j.votes.find(x => x.verdict === 'raise' && x.raised_statement)
  survivors.push(raise ? { ...j.c, statement: raise.raised_statement } : j.c)
}
const survivalRate = distilled.criteria.length ? survivors.length / distilled.criteria.length : 0
log(`Judge: ${survivors.length}/${distilled.criteria.length} survived (${(survivalRate * 100).toFixed(0)}%), ${rejected} rejected`)

phase('Assemble')
let rubric = await agent(
  `Assemble these surviving criteria into a FINAL rubric for category "${CATEGORY}" following the schema EXACTLY. Assign stable ids and a fixed order_index (baseline first, then good, then exceptional). Fill grading.pass/partial/fail, evidence_required, concrete_fix, and provenance per criterion. Set system_module="${CATEGORY}" and module="${CATEGORY}". Keep order stable (scoring-bias defense).\n\nSURVIVORS:\n${JSON.stringify(survivors, null, 1)}`,
  { label: 'assemble', phase: 'Assemble', schema: RUBRIC_SCHEMA })

return { category: CATEGORY, rubric, survival: { rate: survivalRate, survivors: survivors.length, candidates: distilled.criteria.length } }
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/workflows/train-category.workflow.js
git commit -m "feat: train-category above-generic judge + assemble stages"
```

---

## Task 6: Harden stage — scoring-bias check + back-test + self-optimization loop

**Files:**
- Modify: `docs/superpowers/workflows/train-category.workflow.js` (replace the Task 5 temporary return)

- [ ] **Step 1: Replace the Task 5 `return { category: CATEGORY, rubric, survival: ... }` line with the Harden stage**

```javascript
phase('Harden')

// grade one artifact against the current rubric; order='shuffled' reverses criteria for the bias check
async function grade(rb, artifact, label, order) {
  const crit = order === 'shuffled' ? [...rb.criteria].reverse() : rb.criteria
  const r = await agent(
    `Grade this ${CATEGORY} ARTIFACT against the rubric: one row per criterion id, score pass/partial/fail with cited evidence. Grade ONLY on the artifact's described behavior/structure vs each criterion's evidence_required — never on vibe.\n\nARTIFACT:\n${JSON.stringify(artifact)}\n\nCRITERIA:\n${JSON.stringify(crit.map(c => ({ id: c.id, tier: c.tier, statement: c.statement, evidence_required: c.evidence_required })), null, 1)}`,
    { label, phase: 'Harden', schema: GRADE_SCHEMA })
  return r.rows || []
}

// scoring-bias check: grade the MEAN artifact normal vs shuffled; aggregate must be stable
const biasA = await grade(rubric, MEAN, 'bias:normal', 'normal')
const biasB = await grade(rubric, MEAN, 'bias:shuffled', 'shuffled')
const biasCheck = { aggNormal: aggregate(biasA), aggShuffled: aggregate(biasB), gap: Math.abs(aggregate(biasA) - aggregate(biasB)) }
biasCheck.stable = biasCheck.gap <= 0.1
log(`Bias check: gap ${biasCheck.gap.toFixed(3)} (${biasCheck.stable ? 'stable' : 'UNSTABLE'})`)

// discrimination back-test + GEPA-style self-optimization
const GREAT = { name: `top-tier ${CATEGORY} exemplar`, description: GREAT_HINT }
const optimizationHistory = []
let backtest, round = 0
while (true) {
  const meanRows = await grade(rubric, MEAN, `backtest:mean#${round}`, 'normal')
  const greatRows = await grade(rubric, GREAT, `backtest:great#${round}`, 'normal')
  backtest = { round, ...separation(meanRows, greatRows), meanRows, greatRows }
  log(`Back-test r${round}: mean ${backtest.mean.toFixed(2)} / great ${backtest.great.toFixed(2)} / gap ${backtest.gap.toFixed(2)} -> ${backtest.pass ? 'PASS' : 'fail'}`)
  if (backtest.pass || round >= MAX_OPT) break
  const weak = meanRows.filter(m => {
    const g = greatRows.find(x => x.id === m.id)
    return g && ((SCORE_V[g.score] ?? 0) - (SCORE_V[m.score] ?? 0)) <= 0
  }).map(m => m.id)
  const opt = await agent(
    `These rubric criteria FAILED to discriminate: the mean artifact scored as high as (or higher than) the great artifact, so they don't separate quality. Rewrite ONLY these criteria into sharper systems-depth checks the GREAT artifact passes and the MEAN artifact fails. Return rewritten criteria with a change_reason.\n\nWEAK IDS: ${JSON.stringify(weak)}\nMEAN GRADES: ${JSON.stringify(meanRows)}\nGREAT GRADES: ${JSON.stringify(greatRows)}\nRUBRIC: ${JSON.stringify(rubric.criteria)}`,
    { label: `optimize#${round}`, phase: 'Harden', schema: OPT_SCHEMA })
  for (const rw of (opt.rewritten || [])) {
    const idx = rubric.criteria.findIndex(c => c.id === rw.id)
    if (idx >= 0) rubric.criteria[idx] = { ...rubric.criteria[idx], ...rw }
  }
  optimizationHistory.push({ round, weak, rewritten: (opt.rewritten || []).map(r => ({ id: r.id, change_reason: r.change_reason })) })
  round++
}

return { category: CATEGORY, rubric, biasCheck, backtest, optimizationHistory, survival: { rate: survivalRate, survivors: survivors.length, candidates: distilled.criteria.length } }
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/workflows/train-category.workflow.js
git commit -m "feat: train-category harden stage (bias check + back-test + self-optimize)"
```

---

## Task 7: Completeness critic + final return

**Files:**
- Modify: `docs/superpowers/workflows/train-category.workflow.js` (replace the Task 6 temporary return)

- [ ] **Step 1: Replace the Task 6 `return { category: CATEGORY, rubric, biasCheck, ... }` line with the Critique stage + final return**

```javascript
phase('Critique')
const completeness = await agent(
  `Completeness critic for the "${CATEGORY}" rubric. Killer systems that MUST be covered: ${JSON.stringify(KILLER)}. Report covered vs missing, factor in the candidate survival rate (${(survivalRate * 100).toFixed(0)}%), and give an overall assessment of whether this rubric is above the mean and complete.\n\nRUBRIC:\n${JSON.stringify(rubric.criteria.map(c => ({ id: c.id, tier: c.tier, statement: c.statement })), null, 1)}`,
  { label: 'critique', phase: 'Critique', schema: CRITIQUE_SCHEMA })

return {
  category: CATEGORY,
  rubric,
  backtest: { mean: backtest.mean, great: backtest.great, gap: backtest.gap, pass: backtest.pass, rounds: round, meanRows: backtest.meanRows, greatRows: backtest.greatRows },
  biasCheck,
  optimizationHistory,
  survival: { rate: survivalRate, survivors: survivors.length, candidates: distilled.criteria.length },
  completeness,
  provenance: { angles: ANGLES.map(a => a.key), techniqueCount: allTechniques.length, sources: allTechniques.map(t => t.source).filter(Boolean) },
}
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/workflows/train-category.workflow.js
git commit -m "feat: train-category completeness critic + final return shape"
```

---

## Task 8: Locomotion category config

**Files:**
- Create: `docs/superpowers/rubrics/locomotion.config.json`

- [ ] **Step 1: Write the config (the run's args)**

```json
{
  "category": "locomotion",
  "description": "Roblox R15 character locomotion / movement animation system (idle, walk, run, strafe, turns)",
  "killerSystems": [
    "blend tree: warps by speed AND direction (not one forward loop)",
    "foot IK: feet plant on ground/slopes/steps, no skating",
    "additive look-at / aim layered on locomotion",
    "pelvis bias / hip sway / lean tied to gait phase and acceleration"
  ],
  "meanArtifact": {
    "name": "default Roblox Animate + raw Quaternius forward-only clips",
    "description": "A single forward walk/run loop swapped by WalkSpeed only. No strafe/directional set, no foot IK (feet skate on slopes), no additive look-at, no lean or pelvis sway. This is the generic default a beginner ships."
  },
  "greatArtifactHint": "A top DevForum / showcase locomotion system: a 2D blend tree keyed to planar velocity (forward+strafe), foot IK via IKControl/AnimationConstraint that plants feet on slopes and steps, an additive aim/look-at layer, and lean + pelvis sway driven by acceleration and gait phase.",
  "maxOptRounds": 3,
  "separationMin": 0.35
}
```

- [ ] **Step 2: Verify valid JSON**

Run: `python -c "import json; json.load(open('docs/superpowers/rubrics/locomotion.config.json')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/rubrics/locomotion.config.json
git commit -m "feat: locomotion category config for the pilot run"
```

---

## Task 9: Run the pipeline on Locomotion

**Files:** none (produces an in-memory structured result).

- [ ] **Step 1: Load the config and invoke the Workflow**

Read `docs/superpowers/rubrics/locomotion.config.json`, then invoke:
`Workflow({ scriptPath: "docs/superpowers/workflows/train-category.workflow.js", args: <the parsed config object> })`

(Note: `args` must be the actual JSON object, not a stringified version.)

- [ ] **Step 2: Wait for completion and capture the result**

The Workflow runs in the background and notifies on completion. Read the result file referenced in the task-completion notification. Keep the full returned object (`rubric`, `backtest`, `biasCheck`, `optimizationHistory`, `survival`, `completeness`, `provenance`) for Tasks 10–11.
Expected: a `backtest` with numeric `mean`/`great`/`gap` and a boolean `pass`; a `rubric` with a non-empty `criteria` array.

- [ ] **Step 3 (only if the run errors mid-way):** fix the offending stage in the script, then resume:
`Workflow({ scriptPath: "docs/superpowers/workflows/train-category.workflow.js", resumeFromRunId: "<runId>", args: <config> })` — unchanged stages return cached results.

---

## Task 10: Write + validate the rubric artifacts

**Files:**
- Create: `docs/superpowers/rubrics/locomotion.rubric.json`
- Create: `docs/superpowers/rubrics/locomotion.rubric.md`

- [ ] **Step 1: Write `locomotion.rubric.json` from the returned `rubric`, augmented with metadata**

Write the returned `rubric` object with these fields ensured/added at the top level (so it matches the schema and records the run):
- `module: "locomotion"`, `version: "1"`, `date: "2026-06-20"`, `system_module: "locomotion"`
- `judge: { survival_rate: <survival.rate> }`
- `backtest: { mean, great, gap, pass, rounds }` (from the returned `backtest`, WITHOUT the bulky `meanRows`/`greatRows`)
- `scoring_bias: <biasCheck>`
- `provenance: <provenance>`

- [ ] **Step 2: Validate it against the schema**

Run: `python scripts/validate_rubric.py docs/superpowers/rubrics/locomotion.rubric.json`
Expected: `VALID: docs/superpowers/rubrics/locomotion.rubric.json`
If INVALID: fix the written JSON (or the assemble-stage prompt + re-run Task 9 resume) until valid.

- [ ] **Step 3: Write `locomotion.rubric.md`** — a human-readable render: a section per tier (Baseline/Good/Exceptional); for each criterion show `statement`, `above_generic_rationale`, the pass/partial/fail definitions, `evidence_required`, `concrete_fix`, and `exemplar_refs`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/rubrics/locomotion.rubric.json docs/superpowers/rubrics/locomotion.rubric.md
git commit -m "feat: locomotion rubric artifacts (pilot output)"
```

---

## Task 11: Verify the §12 acceptance gate + write the pilot report

**Files:**
- Create: `docs/superpowers/rubrics/locomotion-pilot-report.md`

- [ ] **Step 1: Check each §12 acceptance criterion against the run result**

Confirm and record:
1. **Discrimination back-test:** `backtest.pass === true` (mean ≤ 0.5, great ≥ 0.7, gap ≥ 0.35).
2. **Above-generic survival:** `survival.rate` is high AND `completeness.missing` does not contain any of the four killer systems.
3. **Scoring-bias:** `biasCheck.stable === true` (gap ≤ 0.1).
4. **Self-optimization:** `optimizationHistory.length >= 1` (the loop sharpened ≥1 criterion) OR the back-test passed at round 0 (also acceptable — record which).

- [ ] **Step 2: If acceptance FAILS**, take the documented fallback before writing the report:
- Back-test won't separate after `MAX_OPT` rounds → raise `maxOptRounds` in the config and re-run Task 9 (resume); if still failing, the great/mean artifacts may be too similar — sharpen `greatArtifactHint`/`meanArtifact.description` and re-run.
- Bias unstable → the assemble prompt's order/labels need fixing; adjust and re-run.
- Record the failure + what was changed in the report (a negative result that exposes a real gap is a valid pilot outcome per spec §12/§15).

- [ ] **Step 3: Write `locomotion-pilot-report.md`** containing:
- The §12 verdict (each criterion: pass/fail + the numbers).
- The back-test table (mean vs great aggregate + per-criterion rows).
- The judge survival rate + the completeness critic's covered/missing.
- The `optimizationHistory` (what the self-optimizer changed and why).
- The scoring-bias result.
- **Empirical answers to the spec §14 open questions:** how many candidates/criteria were needed (from `survival`); whether the contrastive mean-vs-great pair discriminated well (from `backtest`); note the corpus-drift guard is untested until the loop session.
- Provenance (angles, technique count, source URLs).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/rubrics/locomotion-pilot-report.md
git commit -m "docs: locomotion pilot report (acceptance verdict + open-question answers)"
```

---

## Task 12 (optional): Human-calibration checkpoint

**Files:** none (may append Learnings notes to the report).

- [ ] **Step 1: Present a small sample to the user** — pick 4–5 criteria and show the agent's mean-vs-great grades; ask the user to grade the same and note agreement/disagreement.

- [ ] **Step 2: Record the result** — append a "Human calibration" section to `locomotion-pilot-report.md`: the agreement rate and any disagreements (these become high-priority **Learnings** the loop session feeds back per spec §9). Commit if changed.

---

## Self-review (completed by author)

- **Spec coverage:** §3 deliverables → Tasks 1,3,8,10,11 (schema, workflow, config, rubric json/md, report). §4 schema → Task 1 + RUBRIC_SCHEMA (Task 3). §5 sources + Quaternius-as-mean → Task 4 ANGLES + Task 8 config. §6 weighting → encoded in the sweep prompts (critique-first). §7 pipeline stages → Tasks 4–7. §8 self-optimization → Task 6 loop. §9 judge hardening (bias check, stable order, strong model, contrastive pair) → Task 5 assemble + Task 6 bias check/back-test (judge runs on the session model, which is Opus/strong). §12 acceptance → Task 11. §14 open questions → Task 11 Step 3. §13 calibration → Task 12. **No gaps found.**
- **Placeholder scan:** no TBD/TODO; all stage code is complete and the temporary returns are explicitly replaced task-to-task.
- **Type consistency:** helper + schema names are consistent across tasks (`aggregate`, `separation`, `SCORE_V`, `TIER_W`, `grade`, `rubric.criteria`, `backtest`, `biasCheck`, `survivalRate`/`survival`, `optimizationHistory`); the on-disk rubric shape (Task 10) matches `rubric.schema.json` (Task 1) and the validator (Task 2).
