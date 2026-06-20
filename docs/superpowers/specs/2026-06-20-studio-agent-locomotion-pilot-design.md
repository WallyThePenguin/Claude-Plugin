# Studio Agent — Training System: Locomotion Pilot (design, session 2)

**Date:** 2026-06-20
**Status:** design approved in brainstorm session 2; no code/data yet. The first session that *will* touch code/data (the pipeline run is the plan's job).
**Serves:** the north star — push the QUALITY CEILING of Roblox games past the generic "AI did it" standard.
**Builds on:** session-1 architecture — `docs/superpowers/specs/2026-06-20-studio-agent-training-architecture-design.md`.
**Memories:** `studio-agent-training-vision`, `studio-agent-north-star`, `studio-agent-asset-creator-vision`, `studio-agent-model-connection`.

## Purpose

Session 1 banked the *architecture* (hybrid Category-Packs-compose-System-Modules; tiered, structured-graded, above-generic rubric; automated top-sampling pipeline; tiered licensing). This document is the **pilot design**: take ONE slice end-to-end far enough to prove the architecture works, while deliberately cutting scope so it's achievable in one execution. The pilot is **rubric-first** — it produces a real, validated Locomotion rubric and proves the engine that produces it — and it does NOT build the live capture→evaluate→refine loop (that is the next session).

Crucially, the pilot proves a **category-general engine**, not a Locomotion-only artifact. The machinery (research → judge → rubric → back-test → self-optimize → calibrate) is identical for every category; only the *content* (sources, criteria, exemplars) changes. Locomotion is chosen because it is a *shared System Module* that many categories (rigs, mounts, NPCs) inherit, so proving it has the widest payoff.

## 1. Scope decisions (settled this session)

1. **Rubric-first.** Produce + validate the Locomotion rubric; stop before the live refine loop. No FBX→R15 retarget needed this session.
2. **Runs here in Claude Code.** Use the `deep-research` skill + Workflow fan-out + adversarial judge over text/web sources. The plugin's unique power (asset dissection + visual capture) needs Studio + retargeting and is deferred with the loop. The plugin's role is to *consume* the rubric later.
3. **Acceptance gate = discrimination back-test.** A rubric that cannot score a known-MEAN artifact low and a known-GREAT artifact high has failed, regardless of how reasonable its criteria read.
4. **Category-general by construction.** The pilot Workflow is parameterized by category; Locomotion is the first argument. The same script becomes the reusable `train-category` onboarding workflow (§11).

## 2. Research grounding (why this design, and what the research changed)

A deep-research pass (23 sources, 110 claims, 25 adversarially verified — 22 confirmed, 3 killed) tested the whole framing. Verdict: **the core bet is correct, with four additions.**

**Confirmed — a curated knowledge system is the right substitute for fine-tuning:**
- In-context self-improvement reliably lifts a *frozen* model above its one-shot baseline. Reflexion (NeurIPS 2023) raised GPT-4 HumanEval pass@1 80% → ~90% purely from a reflect-and-remember loop, same model, zero weight updates. <https://arxiv.org/abs/2303.11366>
- Karpathy's "Software 3.0 / LLM OS" framing (June 2025 YC keynote): prompts are programs, the context window is memory, "context engineering" is the real act of building. Curating what enters context IS programming the model, not a workaround. <https://www.ycombinator.com/library/MW-andrej-karpathy-software-is-changing-again> He is also publicly bearish on RL for LLMs, supporting our non-RL approach.

**Four research-driven changes folded into this pilot:**
- **(A) Make the rubric self-optimizing (GEPA).** GEPA (ICLR 2026 Oral; ships as `dspy.GEPA`) uses an LLM to read full execution traces in natural language, diagnose *why* a candidate failed, and rewrite the prompts/rubric — beating RL (GRPO) by ~6% avg (up to 20%) with up to ~35× fewer rollouts, and it consumes *textual* feedback, not just a scalar. This is the single biggest technique we were underusing. <https://arxiv.org/abs/2507.19457> · <https://github.com/gepa-ai/gepa> *(Caveat: "up to" figures are best-case; average advantage ~6–10%, domain-variable; optimized prompts are model-specific.)*
- **(B) Anchor self-correction to an EXTERNAL verifier.** Intrinsic self-correction does not reliably improve — and can degrade — output without an external signal (Huang et al., ICLR 2024 <https://arxiv.org/abs/2310.01798>). Our capture→rubric signal is that verifier; the loop must always grade against rubric+evidence, never the model's own opinion. Self-Refine confirms the *open-ended generation* regime (exactly our "make it look pro" target) is where these loops work best. <https://arxiv.org/abs/2303.17651>
- **(C) Treat the judge + rubric as a calibrated, bias-tested instrument.** "Scoring bias": scores shift purely from perturbing the scoring prompt (criterion order, score-ID labels, reference quality) independent of the asset — up to ~0.2 for weak judge models vs ~0.03 for frontier ones. <https://arxiv.org/html/2506.22316v1> And LLM-as-judge needs *routine human calibration*; automation alone is insufficient. <https://arxiv.org/html/2411.13768v3>
- **(D) Evaluation is continuous, not one-shot.** Effective agent eval needs offline (controlled regression) + online (live monitoring) loops. The rubric's deliverable is the seed of a growing regression set, with a guard against corpus drift toward the agent's own outputs. <https://arxiv.org/html/2411.13768v3>

**Left out on evidence (do not guess):** distilling a small local helper model is *unresolved* (the supporting small-model SFT claim was refuted 1-2) → explicit non-goal. "GEPA works with ~3 examples" was refuted (1-2) → min corpus size is unknown, the pilot measures it. "A full-marks reference answer is most robust for a judge" was refuted (0-3) → we use a contrastive mean-vs-great pair instead and test it.

## 3. Pilot deliverables

In the repo (these seed the plugin's future rubric store, ported in a later session):
- `docs/superpowers/rubrics/locomotion.rubric.json` — machine-gradable rubric (schema §4).
- `docs/superpowers/rubrics/locomotion.rubric.md` — human-readable render of the same source of truth.
- `docs/superpowers/rubrics/locomotion-pilot-report.md` — the verdict: discrimination back-test result, above-generic survival rate, self-optimization rounds + what changed, scoring-bias check, optional human-calibration agreement, provenance, and the empirical answers to §14's open questions.
- `docs/superpowers/workflows/train-category.workflow.js` (or equivalent) — the **reusable, category-parameterized** pipeline (§7, §11). Running it on `locomotion` produces the artifacts above; running it on another category onboards that category.

## 4. Rubric data schema (settling §13.3's "rubric schema" + hardening C)

One source of truth → JSON (gradable) + MD (readable). Per criterion:

```
{ id,                          // stable, never reordered/relabeled (scoring-bias defense)
  order_index,                 // fixed display/grade order
  tier: baseline|good|exceptional,
  system_module: "locomotion",
  statement,                   // the concrete systems-depth check
  above_generic_rationale,     // why this beats what default Roblox gives free
  grading: { pass, partial, fail },   // explicit definition of each
  evidence_required,           // what a capture/description must show to score it (anchors to external verifier — B)
  concrete_fix,                // what to do when unmet (drives the future refine loop)
  exemplar_refs: [url|asset_id],
  provenance: { sources:[...], confidence } }
```

Rubric-level: `module, version, date, sources[], judge_model, judge_verdicts, scoring_bias_result, backtest_result, optimization_history[]`.

**Hardening (C):** criterion `id` and `order_index` are stable and fixed; score labels are stable; the judge runs on a **strong (frontier) model**; the rubric is **perturbation-tested** (reorder criteria / relabel scores → scores must stay within tolerance). The judge's reference is a **contrastive mean-vs-great exemplar pair** (§5), not a single "perfect" exemplar.

**Worked content (from session-1 §5):** Baseline = idle/walk/run loops exist, transitions don't pop. Good = warps by speed AND direction (blend tree/strafe), feet plant (foot IK, no skating), additive look-at/aim, lean into accel/turns. Exceptional = pelvis bias/hip sway tied to gait phase, idle breakers + variants, surface-aware footstep VFX.

## 5. Sources & the Quaternius role

- **Sources sampled:** DevForum **critique threads** (priority — they state what separates good from generic) + tutorials; creator-docs / GitHub mirror (R15 `Animator`/`IKControl`/`AnimationConstraint` ground truth); known-expert posts/blogs; **YouTube animation-technique transcripts** (via the `youtube-research` skill — locomotion craft lives heavily on video).
- **Quaternius CC0 Universal Animation Library 1+2 (~/Downloads) = the MEAN baseline**, not an exemplar. Its forward-only, no-IK/no-additive clips are precisely the "great negative" for the back-test's *mean* artifact. The **great** back-test artifact + the Good/Exceptional exemplar refs come from top DevForum locomotion systems / showcase games (described in text). Rubric-first stores **pointer refs only** — no asset persistence, so licensing is trivially clean (text sources + URLs/asset-ids).

## 6. Source-quality weighting (settling §13.3's heuristic)

Weight by signal: solution/award/high-reply critique threads > tutorials > generic docs for the "what's good" signal; docs authoritative for **API correctness**; known-expert authorship; recency for engine APIs; showcase reputation. The above-generic judge is the backstop regardless of source weight. (Source weighting biases *sampling*; the judge enforces the *bar*.)

## 7. The pipeline (Workflow shape) — category-parameterized

Execution design (running it is the plan's job). The script takes `category` as an argument; Locomotion is the first run.

1. **Multi-modal sweep** (parallel): critique-thread search · tutorial/docs search · YouTube transcript mining · showcase-game teardown.
2. **Distill** candidate criteria per tier (cluster recurring above-the-mean patterns).
3. **Above-generic judge** (adversarial, multi-vote per criterion: *"does default Roblox already do this? → reject/raise"*), on a strong model.
4. **Assemble** rubric (schema §4) + provenance + contrastive exemplar refs.
5. **Scoring-bias check** (C): perturb the rubric prompt; require score stability within tolerance; fix issues.
6. **Discrimination back-test** (acceptance gate): grade the mean + great artifacts; require clear separation.
7. **Self-optimization loop** (§8): if the rubric fails to discriminate or has weak criteria, reflect on the *textual* failure and rewrite, then re-test. Bounded rounds.
8. **Completeness critic**: coverage of the four killer systems; what's missing → another round.
9. **(Optional) human-calibration checkpoint** (§9): you grade a small sample; measure judge agreement; mismatches → high-priority Learnings.

## 8. Self-optimization loop (change A — the headline upgrade)

A lightweight, hand-rolled GEPA in the Workflow (no Python/DSPy dependency this pilot): after the back-test, if discrimination is weak, feed the failure **in natural language** ("criterion X scored the mean artifact `pass` — it doesn't separate; the real differentiator the great artifact shows is …") to an optimizer agent that rewrites the offending criteria, then re-run the back-test. Loop until it discriminates or a round cap is hit; record every change in `optimization_history`. This proves not just "a rubric" but **"a rubric that sharpens itself from feedback."** Full `dspy.GEPA` wiring is a later option once the rubric format is stable (and is model-specific).

## 9. Judge/rubric as a calibrated instrument (changes C + B)

- **Strong judge model** for the above-generic judge and the back-test grader (scoring bias hits weak models hard).
- **Scoring-bias defense** baked into the schema (stable ids/order/labels) and verified by the §7.5 perturbation test.
- **Human calibration checkpoint** (promotes session-1 §7's audit valve from optional-later to a routine step): the user grades a small sample; agreement is measured; disagreements become high-priority Learnings that the next auto-pass respects. Optional but recommended for the pilot.
- **External-verifier anchoring (B):** every score must cite `evidence_required`; the loop never grades on model vibe alone. (In rubric-first the evidence is text-level/structural; in the loop session it becomes the live capture.)

## 10. Continuous eval / regression set (change D)

The rubric + the mean/great artifacts + their expected score-bands become the first **offline regression cases**, so future rubric edits stay testable. **Corpus-drift guard:** exemplars stay anchored to genuine top-tier external sources, never the agent's own outputs (prevents the corpus from collapsing toward self-reinforcement). Online eval (live-session assets feeding back into the regression set) is designed for but exercised in the loop session.

## 11. Future operating model — category onboarding

The pilot's question "how do I add a category later?" is answered structurally:

- **Authoring a NEW category (heavy lift → Claude Code):** trigger the **reusable parameterized workflow** (`train-category <name>`) — a one-line invocation, not a fresh prompt. It runs the full §7 pipeline and installs the resulting pack into the plugin's rubric store. It lives in Claude Code because the deep-research fan-out, adversarial verification, and GEPA-style optimization are Claude-Code-side capabilities the plugin can't match.
- **Improving an EXISTING category (light, continuous → automatic, in Studio):** no trigger. As the agent builds and the user gives feedback, per-category **Learnings (memory)** accumulate and the capture→evaluate→refine loop + calibration keep sharpening the pack.
- **Future option (noted, deferred):** a lightweight in-Studio "quick-learn" trigger using the plugin's own (weaker) tools for self-service touch-ups; and, larger, a Studio→Claude-Code bridge to launch the full pipeline from inside Studio (its own engineering project, like the admin-dashboard pattern). The strong path stays the Claude Code workflow.

This makes the pilot do double duty: it builds the factory (`train-category`), not just the first product (Locomotion).

## 12. Success metric / acceptance

The pilot **succeeds** if:
1. The rubric passes the **discrimination back-test** — mean artifact scores low, great artifact scores high, with clear separation.
2. The **above-generic survival rate** is high (most criteria beat the default-Roblox floor) and the four killer systems are covered.
3. The **scoring-bias check** shows the rubric is stable under prompt perturbation (within tolerance).
4. The **self-optimization loop** demonstrably improved discrimination on at least one criterion (proving the loop works), or the rubric passed without needing it (also acceptable — record which).
5. (Optional) human calibration shows acceptable judge agreement, or the disagreements are captured as Learnings.

## 13. Scope & non-goals

- **In:** the Locomotion rubric (JSON+MD), the pilot report, and the reusable parameterized workflow — produced here in Claude Code.
- **Out (scheduled — loop session):** in-Studio asset dissection, captured visual exemplars, the live capture→evaluate→refine loop on a retargeted rig, porting the pack into the plugin store, FBX→R15 retargeting.
- **Out (deferred decisions):** exemplar-image storage mechanism; panel audit-viewer UX; full `dspy.GEPA`/DSPy toolchain wiring; in-Studio "quick-learn" trigger.
- **Out entirely (unresolved on evidence):** distilling a small local helper model; weight fine-tuning (impossible — session-1 §1).

## 14. Open questions the pilot will measure

- **Min corpus/criteria count** needed for effective rubric + self-optimization in this domain ("~3 examples" was refuted; measure it).
- **Best exemplar-reference strategy** for a subjective visual-quality judge (full-marks vs graded set vs contrastive pair — test the contrastive pair the back-test already gives us).
- **Offline↔online operationalization** for in-Studio asset generation, and the concrete corpus-drift guard (designed in §10; validated in the loop session).
- **Whether a small local helper model is ever worth it** (flagged, not investigated here).

## 15. Risks & mitigations

- **Mean-regression** (central risk): above-generic judge (build filter) + discrimination back-test (acceptance gate) + self-optimization (sharpening) + exemplar anchoring.
- **Text-only rubric lacks dissection-grounding:** acceptable for proving the *mechanism*; criteria are still judge-filtered + back-tested; in-Studio dissection enriches later.
- **Back-test artifacts are text-described, not captured:** acceptable at the architecture-proving level; live-capture grading is the loop session's job.
- **Judge unreliability / scoring bias:** strong judge model + perturbation test + human calibration.
- **Self-correction degrading output:** anchored to the external rubric/evidence signal (B), never model-only self-grading.
- **Corpus drift / self-reinforcement:** §10 guard (exemplars anchored to external top-tier sources).
- **GEPA gains are domain-variable + model-specific:** the lightweight loop is bounded and measured; full DSPy wiring deferred until the format is stable.

## 16. Next steps

1. Turn this spec into an implementation plan (writing-plans skill).
2. The plan's execution = run the parameterized Workflow on `locomotion`, producing the §3 deliverables, and report against §12.
3. Then schedule the **loop session**: retarget a rig, build the live capture→evaluate→refine loop anchored to this rubric, and exercise the online-eval path. Its scope is §17.

## 17. Loop-session scope (confirmed plugin-gap roadmap)

A grounded audit of the current plugin against this rubric's demands (7-agent Workflow, adversarially verified against the code — all gaps confirmed present) defines what the **loop session** must build. This is NOT pilot scope; the pilot deliberately runs in Claude Code to avoid all of it. Recorded here so the loop session starts from evidence.

**How the rubric already helps the shipped plugin (no new code):** a produced rubric rides the existing knowledge-delivery path (`src/AgentLoop.luau:112` composes SystemPrompt + memory + skills into the leading preamble), so it upgrades the agent's *output* — turning the prose in `src/SystemPrompt.luau:51` into per-criterion checkable targets — with zero new transport code.

**Critical gaps — required to run the grading loop in Studio:**
1. **No rubric store** — nothing loads a Quality Pack at call time. → new `src/RubricStore.luau` (mirror SkillStore/Memory) + wire into `src/init.server.luau:42` and the `AgentLoop` preamble. *Medium.*
2. **No structured grading** — the Anthropic client has no forced-JSON path, so per-criterion scores would be free-form prose (drift). → new `src/Tools/Evaluate.luau` **plus a schema contract** (tool-input schema or `tool_choice`/structured-output support in `src/Anthropic.luau`). *Med-High.* (The store alone is insufficient — the schema enforcement is a distinct requirement.)
3. **Can't dissect rigs** — `PropertyCatalog.luau:25-73` covers only basic classes; `get_properties` can't read Motor6D (C0/C1/Transform), IKControl, AnimationConstraint, Animator, KeyframeSequence/Keyframe/Pose, ParticleEmitter, Beam. → additive catalog entries (serializer tags for CFrame/Vector3/EnumItem already exist). *Low-Med.*
4. **Can't film motion** — `capture_animation` is a hard-disabled stub (`Capture.luau:142-152`; `TimePosition` doesn't advance in edit), and the vision sidecar HTTP path is **server-only**, so it doesn't reach a client-view playtest. → ship the deferred playtest-mode filmstrip (plan `2026-06-18-multi-capture.md` Tasks 7-8) **and rework the relay** to forward the sidecar GET through the server. *High — the hardest, and the gating one for motion criteria.*

**Important gaps — quality, cost, taste-learning, UX:**
5. **No exemplar-image store** for mean-vs-great side-by-side → exemplar handles in RubricStore + a retrieval path reusing capture's base64 return shape. *Medium.*
6. **Learnings can't be high-priority overrides** — `Memory.luau:19-20` is flat `{id,text,createdAt}`, cap 25×240, no category/priority → a per-category prioritized learnings bucket (or a dedicated store) the Evaluate tool reads as override-priority. *Medium.*
7. **No prompt-caching of the active pack** across refine iterations (`AgentLoop` rebuilds the preamble each Send) → `cache_control` breakpoints — **verify the CLIProxyAPI path honors them** (it strips `system`). *Medium.*
8. **No Studio rubric viewer / category-onboard trigger** → a panel mirroring the Memory/Skills viewers + a button to launch the parameterized `train-category` workflow. *Med-High.*

**Scaling caveat:** rubric packs (tiered criteria + exemplar images + corpus refs) are far larger than the small SkillStore catalog — they need **on-demand per-category loading + caching**, not a copy of the SkillStore pattern.

**Boundary + a low-cost option:** none of this rewrites the plugin's own Luau automatically — the rubric improves *output* and *surfaces* these work items. But the same engine could later be aimed at a non-visual **"plugin code quality"** category (criteria: tool-schema hygiene à la the `encodeBody` bug, error handling, sidecar loopback security). That category is **lower-dependency than Locomotion** — read-file + structured grading + learnings, no capture/catalog/animation work — so it's the cheapest path if the goal is ever to have the system help improve the plugin's *code* directly.
