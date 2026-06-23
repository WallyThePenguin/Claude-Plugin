# Studio Agent — Exemplar-image anchoring (design, 2026-06-23)

**Status:** approved in brainstorming, ready for an implementation plan.
**Lever:** §17 gap #5 / training-architecture §7.4 + §8 — make `evaluate` (and the agent) *see* what
"great" looks like, not just read text criteria. The corpus stores curated reference images of top
work per category; `evaluate` captures the agent's own build and grades it **with those references in
view**, calibrating the bar visually.

## 1. Problem

`evaluate` ([src/Tools/Evaluate.luau](../../../src/Tools/Evaluate.luau)) grades a build with a
**text-only** call: rendered rubric + structural DataModel dump + the agent's design claim + category
learnings → `Anthropic.requestStructured` (forced `submit_grade`). The grader never *sees* anything —
neither the build nor any reference for what "great" is. So the bar is averaged prose, and
visually-anchorable craft (foliage grounding, material depth, typographic hierarchy, pose readability)
can only be graded from claims, not from pixels. The training architecture (§8) calls for the opposite:
*"the corpus stores captured screenshots of top exemplar assets, and the evaluate step grades the
agent's own capture against the reference image, not just against text criteria."*

The transport for this already exists: capture tools build
`{type="image", source={type="base64", media_type="image/png", data=…}}` blocks via the sidecar, and
`Anthropic.requestStructured` passes `messages` straight through — so an **array** `content` of
*text + image blocks* already works on the wire. The missing pieces are a **stored exemplar corpus**,
a way for `evaluate` to **capture its own subject**, and the **grade-call wiring** that folds both in.

## 2. Settled decisions (from brainstorming)

- **Scope:** full visual anchoring (capture the build + grade against curated exemplar images), not the
  light URL-backfill.
- **Sources (all clean-license tiers; the store is source-agnostic):** your own curated captures
  (primary / highest-signal), official Roblox samples, CC0 asset captures, and agent self-captures as
  a cold-start seed. **Copyrighted "best-in-class" stays study-only** — the agent may `web_fetch` it to
  learn *method*, but it is **never** stored or shipped (§6b: technique, not expression).
- **Licensing rule (enforced by the validator):** an exemplar may be stored/shipped only if its
  `license` is `own | official | cc0`. Any other value (or a copyrighted source) is rejected.

## 3. Architecture

### 3a. Storage — a sidecar-served exemplar folder

Exemplars are PNG files plus a `manifest.json`, in a folder beside the sidecar:

```
sidecar/exemplars/
  manifest.json
  locomotion/loco-blendtree-hero.png
  combat/…
  gui/…
  environment/…
```

A new sidecar endpoint serves them in the **same shape `fetchCaptures` already consumes**:

```
GET /exemplars?category=<cat>[&b64=1]
  -> { "exemplars": [ { "id","caption","tier","license","source","criterion_id", "image": "<base64>" }, … ],
       "returned": N }
```

Chosen over the alternatives because it (1) reuses the existing capture transport with **zero new wire
concepts**, (2) keeps the `.rbxm` lean — the raw corpus stays external, per training-arch §9, and
(3) lets you **add an exemplar by dropping a PNG + one manifest line, with no plugin rebuild or Studio
restart**, which matters because your own captures are the primary source. (A bundled base64 Luau
module would bloat the rbxm and force a regen + `.\build.ps1` + restart per image; `rbxassetid` is a
dead end — the model can't read `rbxassetid://` and a plugin can't read the pixels back, the
EditableImage wall already hit.)

### 3b. Manifest schema (`sidecar/exemplars/manifest.json`)

```jsonc
{
  "version": 1,
  "exemplars": [
    {
      "id": "loco-blendtree-hero",          // unique, kebab-case
      "category": "locomotion",             // MUST match a rubric module name
      "file": "locomotion/loco-blendtree-hero.png", // path relative to exemplars/
      "license": "own",                     // own | official | cc0  (REQUIRED; anything else rejected)
      "source": "Agent build that passed the locomotion gate, 2026-06-23", // human-readable provenance
      "caption": "Velocity-driven blend tree + runtime foot IK; note the planted stance foot on the slope.",
      "criterion_id": null,                 // OPTIONAL — anchors one criterion; null = category-level
      "tier": "exceptional"                 // OPTIONAL — baseline | good | exceptional (tier it illustrates)
    }
  ]
}
```

- `license` is the **shippability gate** — the validator rejects anything not in `{own, official, cc0}`.
- `criterion_id` + `tier` are optional today (we curate **per-category**) but make the schema
  **ready for per-criterion anchoring later**, for the visually-anchorable criteria only — we never
  pretend to anchor architectural criteria (netcode, state-store separation) that aren't screenshots.

### 3c. Grading model — calibration anchoring, NOT similarity scoring

The grade call sends the agent's own capture **and** the category's exemplar images, the latter labeled
*"reference images of GREAT work in this category — calibrate the bar to these."* The grade stays
**per-criterion against the rubric text**; the images make the bar concrete, they do **not** become a
similarity target. This is the only model consistent with *technique-not-expression* (§6b) — we anchor
the **bar**, never grade "does it look like this specific image" — and it tolerates "good-not-god-tier"
exemplars (they calibrate; they don't dictate), which the sourcing tension makes unavoidable for v1.

The forced `submit_grade` tool, the per-criterion schema, and `maxTokens=8192` are unchanged. Only the
user message's `content` changes from a string to an array of blocks.

### 3d. `evaluate` flow (changed)

1. Resolve subject, gather structural evidence, design claim, learnings — **as today**.
2. If `capture` (new input, default `true`) and the sidecar is reachable: **auto-capture the subject** —
   frame the camera to the subject's AABB (reusing `CaptureCore.aabbOf` + camera save/set/restore +
   `triggerCapture` + `fetchCaptures`), producing one framed "beauty shot" image block of the build.
   (N-angle orbit and animation-clip filmstrips are later refinements — §6.)
3. Fetch the category's exemplars from `/exemplars` → labeled image blocks.
4. Build the user message `content` as an **array**: a text block (the existing INSTRUCTION + RUBRIC +
   DESIGN + STRUCTURAL + LEARNINGS, plus a short visual-calibration instruction when images are
   present), then the build-capture block(s) under an `=== AGENT'S BUILD (capture) ===` label, then the
   exemplar blocks under a `=== REFERENCE: what GREAT looks like (calibrate the bar) ===` label.
5. `requestStructured({ messages = {{role="user", content = <array>}}, tool = gradeTool, maxTokens = 8192 })`
   — unchanged call, array content.
6. Validate + render — **as today**.

**Graceful degrade (non-negotiable):** no sidecar, no exemplars for the category, `capture=false`, or a
capture failure → the content collapses to the text-only path exactly as today. Never a hard fail, never
a regression on the existing text grade. The INSTRUCTION's visual-calibration sentence is included only
when at least one image is attached.

## 4. Components

### New
- `sidecar/exemplars/manifest.json` + `sidecar/exemplars/<category>/*.png` (the seed corpus, §5).
- **Sidecar `/exemplars` endpoint** in `sidecar/server.py` (+ a small loader: read `manifest.json`,
  filter by `?category=`, attach base64 when `b64=1`). Document it in `sidecar/README.md`.
- **`scripts/validate_exemplars.py`** (mirrors `validate_rubric.py`): every entry has a unique `id`;
  `category` matches a known rubric module; `file` exists under `exemplars/`; `license ∈ {own,
  official, cc0}`; optional `criterion_id` resolves to a real criterion in that category's rubric;
  optional `tier ∈ {baseline, good, exceptional}`. Non-zero exit on any violation.
- **`src/ExemplarEvidence.luau`** — the Luau side, paralleling `GuiEvidence`/`EnvEvidence`:
  - PURE `buildExemplarBlocks(payload) -> { any }`: given a decoded `/exemplars` response, return an
    array of alternating text-label + image blocks (label = tier + caption + source; tolerant of a
    missing caption/tier). Empty/absent exemplars → `{}`.
  - IMPURE `fetchExemplars(category, config) -> ({ any }?, string?)`: GET `/exemplars?b64=1`, decode,
    `buildExemplarBlocks`. Returns `(nil, err)` on any failure (caller degrades).
  - IMPURE `captureSubject(subject, config) -> ({ any }?, string?)`: frame the subject + one capture +
    `fetchCaptures(1, since)` → one labeled image block. Returns `(nil, err)` on any failure.
- **`src/ExemplarEvidenceSpec.luau`** — pure cases for `buildExemplarBlocks` (empty payload, one entry,
  label formatting, missing optional fields). Framing/HTTP are CaptureCore's, live-verified.

### Changed
- **`src/Tools/Evaluate.luau`**: assemble array `content`; fold the build capture + exemplars; update
  `INSTRUCTION` with the visual-calibration sentence (only when images present); add the `capture`
  boolean input (default `true`); graceful text-only degrade.
- **`src/SystemPrompt.luau`**: extend the "Evaluating against the rubric" section — after building in a
  rubric category, run `evaluate` (which now *shows* the agent the bar); for sourcing study only, it may
  `web_fetch` copyrighted references to learn **method**, never to store or reproduce.

### Unchanged / reused
- `Anthropic.requestStructured` (array content already works), `EvaluateReport` (forced tool + render),
  `CaptureCore` (framing + capture + fetch), `Config.getSidecarUrl`, the relay classification
  (`evaluate` stays LOCAL).

## 5. Seed corpus + curation workflow

**Cold-start seed (so v1 is live before any curation):** for each of the 4 categories, seed ≥1
clean-license exemplar, tier-tagged honestly:
- An **agent self-capture** of the best build that already passed that category's rubric gate
  (`license: "own"`, `source: "agent-seed …"`). This solves the cold start without external sourcing.
- Where one cleanly demonstrates the category, an **official Roblox sample** or **CC0 asset** capture.
- These are explicit placeholders; calibration anchoring (§3c) tolerates "good-not-god-tier," and the
  `tier`/`source` tags tell the grader a seed is not a ceiling.

**Your upgrade path:** drop a PNG into `sidecar/exemplars/<category>/`, add one manifest line
(`license: "own"`). No rebuild, no restart — the next `evaluate` picks it up; your captures displace the
seeds and the bar climbs. `validate_exemplars.py` guards the manifest.

## 6. Scope & non-goals

**In (v1):** the `/exemplars` endpoint + manifest + validator; `ExemplarEvidence` (fetch + subject
auto-capture → labeled blocks); `evaluate` array-content wiring with calibration framing + the `capture`
input + graceful degrade; the 4-category seed corpus; the SystemPrompt nudge; a bridge-dogfood
acceptance test (§7).

**Out (deferred, stated honestly):**
- **Animation-clip filmstrip** visual grading — reuse `capture_animation`; v1 visual-grades the built
  scene/subject (one framed shot), animation is a clean v2.
- **N-angle orbit** capture inside `evaluate` (v1 = one framed shot; orbit is a trivial extension).
- **True per-criterion exemplar anchoring** — the schema is ready (`criterion_id`+`tier`); we curate
  per-category now.
- **A Studio-side exemplar viewer UI** (mirroring the Memory/Skills viewers) — the human-audit valve;
  later.
- **An automated web exemplar-harvester** — the agent studies copyrighted refs live; we don't build a
  scraper, and copyrighted images are never stored.

## 7. Testing & acceptance gate

- `ExemplarEvidenceSpec` (pure `buildExemplarBlocks` cases) green in-Studio.
- `validate_exemplars.py` green on the seed manifest; `selene src` 0/0; `rojo build` green.
- **Bridge dogfood (the gate that matters — verify by LOOKING, not coordinates):** build a deliberately
  mediocre subject in a category, then `evaluate` it **with** vs **without** the exemplar block wired in.
  Confirm the visual-anchored grade (a) **cites something visible in the capture** that the text-only
  path could not know, and (b) **shifts at least one visually-anchorable criterion**. This proves the
  images actually move the grade rather than riding along. Then confirm the **degrade path**: with the
  sidecar exemplars absent (or `capture=false`), `evaluate` returns today's text-only report unchanged.

## 8. Build / verify loop (unchanged)

`stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene 0/0).
A plugin code change needs `.\build.ps1` + a USER Studio restart. A sidecar change needs the sidecar
restarted. Drive everything via `scripts/studio-agent.ps1`. Execute with
**superpowers:subagent-driven-development** (fresh implementer + review per task). Commit per task; do
not push.
