# Studio Agent — Training System Architecture (design, session 1)

**Date:** 2026-06-20
**Status:** architecture banked (brainstorm session 1 of a multi-session program). No code, no data-gathering yet.
**Serves:** the north star — push the QUALITY CEILING of Roblox games past the generic "AI did it"
standard. This is the **standard** half of the thesis; the **loop** half is the Asset Creator (captured in the
memory `studio-agent-asset-creator-vision`, not yet specced). Memories: `studio-agent-training-vision`,
`studio-agent-north-star`, `studio-agent-asset-creator-vision`.

## Addendum (2026-06-20, session 2): research validation + amendments

A deep-research pass (23 sources, 25 claims adversarially verified) **confirmed the core framing** — a
curated knowledge system is the correct substitute for fine-tuning a frozen model (Reflexion lifted GPT-4
HumanEval 80%→~90% purely from an in-context loop; Karpathy's "Software 3.0 / LLM OS" frames context
curation as *the* act of building). It added four amendments, now folded into the pilot
(`2026-06-20-studio-agent-locomotion-pilot-design.md`) and applicable to **every** category:

1. **Self-optimizing rubrics (GEPA).** Rubrics/prompts should sharpen themselves from *textual* failure
   feedback (an LLM reads why a candidate failed and rewrites it). GEPA beats RL by ~6% avg with ~35× fewer
   rollouts. → the engine gains a self-optimization stage; §5's rubric is no longer authored-once-and-frozen.
2. **External-verifier anchoring.** Intrinsic self-correction can *degrade* output without an external
   signal; the capture→rubric signal is that verifier — the refine loop must always grade against
   rubric+evidence, never model vibe.
3. **Judge/rubric = calibrated, bias-tested instrument.** "Scoring bias" means rubric wording/order can
   shift scores by themselves → fix criterion ids/order/labels, use a strong judge model, perturbation-test
   the rubric. The §7 human-audit valve is **promoted** from optional-later to a routine *calibration* step.
4. **Continuous eval.** Rubrics seed a growing offline regression set + online feedback, with a guard
   against corpus drift toward the agent's own outputs.

Left out on evidence: distilling a small local helper model is **unresolved** (explicit non-goal for now).

## Purpose of this document

The "Training vision" is to make the agent excellent at making games by sampling forums / free
assets / everything into a per-discipline **quality-reference corpus + rubrics** it draws on. This
document settles the **framing** and the **corpus/rubric architecture** — including *how* the
research pipeline works — so that later sessions can execute per-category research against a fixed
design. It deliberately does **not** build any rubric, gather any corpus, or write any code.

## 1. Framing (settled): a knowledge system, not weight fine-tuning

**You cannot fine-tune Claude's weights.** Confirmed against the Claude API reference: the
Anthropic SDK exposes inference + orchestration + in-context customization (skills, memory, RAG,
prompt caching, structured outputs, tool use, Managed Agents) — there is **no weight-training
endpoint**. The only historical exception (a limited preview of fine-tuning Claude 3 Haiku on
Amazon Bedrock) is an old model, AWS-only, off the subscription path, and irrelevant here. The agent
reaches Claude through the subscription OAuth via the proxy/tunnel ([[studio-agent-model-connection]]),
where fine-tuning is doubly unavailable. Weight fine-tuning would require swapping the brain to a
local/open model and trading away the very capability that makes the quality-ceiling vision possible.

**Therefore "training" = a curated knowledge system the agent loads in-context.** Everything below is
built on skills + RAG + rubrics + memory + caching + structured outputs — the model is never changed;
we change **what it knows and what bar it grades against** at call time.

## 2. Organizing principle: feature × category

The directive ("utilize each feature to maximize asset creation in each categorical field") is the
architecture's spine. Each Claude feature has a fixed role in the asset-creation loop:

| Feature | Role |
|---|---|
| **Skills** | The per-category **authoring recipe** (build→capture→evaluate→refine), loaded on demand |
| **Structured outputs** | The **evaluate** step — a graded score against the rubric, criterion by criterion (objective, not vibes) |
| **RAG / Files / web_search** | The **corpus** — curated exemplars + pointer references per category; also how the pipeline *builds* it |
| **Memory** | **Learnings** — per-category corrections + wins accumulated across sessions; also captures human audit overrides |
| **Prompt caching** | Keep the active per-category pack **cheap to resend** across every refine iteration |
| **Subagents / parallel writers** | Parallel research (build corpus), parallel building (regions/variants), parallel verification (multi-lens grading) |
| **Capture / capture_angles** | The visual input to **evaluate** — the agent *sees* the asset and grades it; also captures visual exemplars |

## 3. Structure: two layers (hybrid organization)

Knowledge is organized **hybrid** — category-facing packs that compose shared system modules:

- **Category Quality Packs** (what the agent builds + grades): Map · Handheld · Rig · VFX · Mount · …
  Each pack = `{ Rubric + Corpus + Recipe + Learnings }`.
- **Shared System Modules** (the reusable depth, authored once, inherited by every pack that needs
  it): Contact-point IK · Blend/Gait · Environmental-state · Authoritative netcode · Material-impact
  matrix. (This is the convergence insight from the memories — the categories reduce to a small set
  of reusable systems.)

A pack's Rubric and Recipe **pull in** the modules it composes (a Mount pack = IK + Gait + netcode),
so the hard knowledge lives in exactly one place and every category inherits it — no duplication,
no drift. This is "generalize, don't hardcode" applied to the knowledge layer itself.

## 4. The Quality Pack anatomy

| Component | Backed by | What it is |
|---|---|---|
| **Rubric** | structured outputs (grading) + skill/preamble (delivery) | The graded bar (see §5) |
| **Corpus** | RAG / Files / web + captured exemplar images | Distilled criteria source + pointer refs + visual exemplars |
| **Recipe** | Skills | The category's build→capture→evaluate→refine workflow |
| **Learnings** | Memory | Accumulated corrections/wins + human audit overrides |

## 5. The Rubric (keystone)

The rubric is the mechanism that makes the loop refine **toward pro-grade** instead of regressing to
the mean. Shape: **criterion-level, tiered, structured-graded.**

- **Criteria** are concrete checks that encode *systems depth*, never surface presence. Not "does it
  have an animation" but "does locomotion warp by speed AND direction (blend tree), not one loop."
- **Tiers** (Baseline → Good → Exceptional) let the agent *progressively push the ceiling* instead
  of stopping at "fine."
- **Grading** is structured output: the evaluate step emits one row per criterion —
  `{ criterion, tier, score (pass/partial/fail), evidence_from_capture, concrete_fix }`. The refine
  loop targets the **highest unmet tier** and re-captures. Mean-regression is impossible because the
  bar is written down and every score must cite evidence.

**Worked example — the `Locomotion` system module:**

| Tier | Criteria (each graded pass/partial/fail with evidence + fix) |
|---|---|
| **Baseline** | Idle/walk/run loops exist; transitions don't pop |
| **Good** *(above the mean)* | Locomotion **warps by speed *and* direction** (blend tree / strafe set), not one forward loop · **feet plant** on ground/slopes/steps (foot IK — no skating) · **additive look-at/aim** layered on top · **lean** into accel/turns |
| **Exceptional** *(polish)* | **Pelvis bias / hip sway** tied to gait phase · **idle breakers** + randomized variants · surface-aware footstep VFX *(→ Material-impact module)* |

## 6. Sources → Rubric pipeline (fully automated; human audits later)

```
Sources → Deep-research sample → Distill candidates → [above-the-mean judging] → Store → (human audit, later/optional)
```

- **Sources** (per category/module): Roblox DevForum (tutorials + **critique** threads — the gold),
  free Toolbox/Marketplace assets, create.roblox.com + the GitHub creator-docs mirror, discipline
  style guides, and the user's own quality exemplars.
- **Sample**: the `deep-research` workflow + `web_search`/`web_fetch` (Anthropic server-side tools,
  which reach roblox.com) + parallel subagents fan out per module.
- **Distill**: extract recurring above-the-mean patterns → candidate criteria + a shortlist of
  exemplar references.
- **Decision (settled): fully automated, with a human audit valve later (optional).** No mandatory
  human gate. **This puts the entire above-the-mean guarantee on the automation** — see §7.

### 6a. Two ingestion modes — text vs. asset

Sources split into two modes that ingest differently:

- **Text** (forums, critique threads, docs): `web_fetch` → read → extract criteria. Commentary
  *about* good work.
- **Asset** (copyright-free models/rigs/VFX): the richest mode, and unique to the in-Studio agent —
  it can **dissect the actual artifact in the engine**:
  1. **Insert** the asset (Toolbox/Marketplace/the user's library).
  2. **Structurally dissect** with `get_tree`/`get_properties` — read the *real* Motor6D/`IKControl`
     rig, the *real* `ParticleEmitter`/`Beam` values, the real part hierarchy and script structure.
     This is **ground truth**, not a description of it.
  3. **Capture** (`capture_angles`) → a **visual exemplar** (§8).
  4. **Extract the technique** → rubric criteria + the captured reference image.

  Asset ingestion feeds both halves of a pack — concrete dissection-grounded criteria *and* the
  visual exemplars — and learns from shipped quality work by taking it apart.

### 6b. Copyright & licensing guardrails (both ingestion + output)

*Not legal advice; for commercial use, verify the specific license. The default-safe path is
copyright-free sources; copyrighted assets are a careful secondary path under the tier rule below.*

1. **Two source tiers, by license.** The best exemplars often aren't copyright-free, so copyrighted
   assets are usable — but only for *study*, never as stored reproductions or shipped content:
   - **Copyright-free / your-own / official Roblox samples** → **full treatment**: dissect, capture,
     and **store** the visual exemplar + criteria.
   - **Copyrighted ("licensed") assets** → **ephemeral, technique-only**: insert, dissect, derive the
     *method* criteria, then **discard** — never persist the asset or its screenshot, never ship it.
     What's kept is the non-copyrightable *method*, not a stored copy of the *expression*. Honor each
     asset's actual license — some terms forbid dissection/reverse-engineering/derivatives even
     privately, regardless of whether it's shipped.
   - **"Free" ≠ a clean license.** Roblox Toolbox "free" is a *price*, not a license, and the Toolbox
     is full of stolen re-uploads. Reject dirty-license/re-uploaded assets regardless of quality. The
     §7 source judge is therefore also a **license-cleanliness judge**.
2. **Technique, not expression** (applies to *both* tiers). Learn the transferable *method* (e.g.
   "blend tree + foot IK + pelvis bias") → it becomes a rubric criterion. Never clone the asset's
   specific creative expression (its exact meshes/textures/keyframes), and never produce output
   *substantially similar* to it (a derivative work infringes even without a literal copy).
   Techniques/methods aren't copyrightable; specific expression is — so this stays legally clean
   **and** on-thesis (the goal is the *system*, not the *asset*). Any stored exemplar image is a
   grading reference drawn only from the full-treatment tier, never a template to reproduce.

## 7. The above-the-mean mechanism (load-bearing, because the pipeline is automated)

With no mandatory human curator, the automation itself must clear the bar or it inherits the forum's
mean (the exact failure the project exists to beat). Four mechanisms make automated sampling beat the
mean:

1. **Sample the top, not the average.** Weight sources by quality signal — award/high-upvote threads,
   high-rated assets, known expert authors. The corpus is "what the *best* do," not "what's typical."
2. **Critique threads first.** DevForum *critique* threads state what separates good from generic —
   they encode the bar directly. Prioritize them over tutorials.
3. **The "above-generic" judge** *(the keystone of the keystone).* Every candidate criterion is
   adversarially tested by a judge agent: *"Does default/generic Roblox already do this? If yes, it's
   the floor — reject it or push it higher."* This is the north-star line operationalized
   (spark effect = ceiling; impact-reaction system = above it). A criterion survives only if it beats
   what the engine gives for free.
4. **Anchor to exemplars.** Each criterion ties to a specific top exemplar (a captured reference
   image), so the bar is concrete, not averaged prose.

**Human audit valve (deferred/optional):** every rubric is stored with **provenance** (sources,
exemplars, confidence). A panel viewer (mirroring today's Memory/Skills viewers) lets the user later
cut/sharpen a criterion; overrides are captured as high-priority **Learnings** so the next auto-pass
respects them — the system learns the user's taste over time.

## 8. Visual exemplars

Because capture works, "what good looks like" can be **literal**: the corpus stores captured
screenshots of top exemplar assets, and the evaluate step grades the agent's own capture *against the
reference image*, not just against text criteria. Visual exemplars anchor criteria (§7.4) and
strengthen the visual evaluate step. **Stored exemplars come only from the full-treatment tier**
(copyright-free / your-own / official — §6b); copyrighted assets contribute ephemeral *technique*
during study but are never persisted as reference images.

## 9. Delivery & storage

- **On-demand per active category.** Loading all packs at once would blow context, so when the agent
  works on category X it loads X's pack; the system modules X composes load with it. Delivery rides
  the existing **skill + leading-preamble** path (the proxy strips the client `system` field — see
  [[studio-agent-model-connection]] — so packs are delivered as a leading message, never via `system`).
- **Prompt caching** keeps the active pack warm across refine iterations.
- **Persistence** extends what already exists: Recipes → the skills store; Learnings → the Memory
  store; plus a new **rubric/reference store** (rubrics + pointer refs + exemplar-image handles). The
  **raw corpus stays external** — only pointer references (URLs/asset-ids) are stored; the agent
  `web_fetch`es deeper on demand, so context never bloats.

## 10. Coupling

- Powers the **Asset Creator** refine loop — the rubrics are what the capture→evaluate→refine loop
  grades against. The two are the standard + loop halves of one thesis.
- Serves the **north star** — every mechanism here optimizes for "above the mean," not "fast."

## 11. Scope & non-goals (important — multi-session program)

- **In scope (this session):** the framing, the feature×category map, the two-layer pack/module
  structure, the tiered rubric design, the automated top-sampling pipeline with the above-generic
  judge, and delivery/storage. All **architecture only.**
- **Explicitly OUT of scope here (later sessions):** running any deep research; building any actual
  rubric, corpus, or system module; writing any code; choosing the exact rubric data schema; choosing
  the exact source-quality-weighting heuristics. These are scheduled, not skipped.
- **Out of scope entirely:** weight fine-tuning (impossible — §1); visually-verified-by-sight is the
  Asset Creator's job, not this doc's.

## 12. Risks & mitigations

- **Mean-regression** (the central risk): mitigated by the §7 quartet — top-sampling, critique
  priority, the above-generic judge, exemplar anchoring. If automated quality proves insufficient in
  the pilot, the human-audit valve escalates to a mandatory gate (revisit §6).
- **Context bloat:** mitigated by external raw corpus + on-demand per-category loading + caching (§9).
- **Automation produces plausible-but-mediocre criteria:** the above-generic judge + provenance +
  audit valve are the defense; the pilot (§13) is where we measure whether it holds.
- **Dirty-license ingestion** (learning from a stolen/copyrighted asset): mitigated by the §6b
  license-cleanliness judge (filter on license, not price; reject re-uploads). The
  technique-not-expression rule is the backstop — even a misclassified asset's influence is limited
  to non-copyrightable *method*, never reproduced expression.

## 13. Next sessions (the multi-session program)

1. **Pilot one category end-to-end** (recommended first) — e.g. `Locomotion`: run the real pipeline
   on one module, produce a real rubric + exemplars, wire it into a capture→evaluate→refine loop, and
   measure whether the automated bar is actually above the mean. Proves the whole architecture on one
   slice before scaling. This is the first session that touches code/data.
2. **Or: first broad deep-research pass** — fan out the pipeline across several categories at once.
   Higher coverage, but unproven loop — riskier before the pilot.
3. Deferred design decisions to settle when piloting: the rubric data schema, the source-quality
   weighting heuristics, the exemplar-image storage mechanism, the panel audit-viewer UX.
