# Studio Agent — Rubric-categories + evaluate-evidence session handoff (2026-06-23)

**Read this first. Everything below is SHIPPED + bridge-verified + committed clean on `master` (NOT pushed).
There is NO pending half-done step. This session executed the prioritized-Learnings plan and then shipped a
large, coherent body of follow-on work. The next session picks a NEXT lever (§5) — the highest one
(exemplar-image anchoring) needs the USER's input, so it's a real choice, not a default.**

## 0. Environment NOW (running — don't re-create)
- **Dev bridge + sidecar + tunnel are UP.** Drive the plugin from the shell with `scripts/studio-agent.ps1`
  (`tool <name> '<json>'`, `luau '<code>'`, `prompt '<text>'`, `logs`, `capture [out.png]`). The sidecar is on
  `http://127.0.0.1:8389`.
- **Studio has the LATEST clean build loaded** (4 rubrics + GuiEvidence + EnvEvidence; commit `6bf2447`,
  no temp spec-requires). A plugin CODE change needs `.\build.ps1` + a **USER Studio restart** ("Restart to
  update") — the bridge can't hot-reload itself.
- Workspace: the user's **`UAL2_Standard`** Quaternius rig (a deferred-FBX artifact, §3/§5) may still be in
  Workspace — **it's the user's; don't delete it.** Test rigs/GUIs/scenes from this session were all cleaned up.
- Everything is committed clean on `master`; **nothing is pushed** (the user controls pushing).

## 1. CRITICAL bridge / workflow gotchas (don't re-derive)
- From the **PowerShell tool**, invoke the CLI as **`& scripts/studio-agent.ps1 …`** (direct). A nested
  `powershell -File …` double-parses and STRIPS inner double-quotes from Luau string literals.
- Keep Luau passed via the bridge **ASCII-only**. For multi-line Luau, Write it to a temp `.lua` (ASCII) then
  `$code = Get-Content -Raw -Encoding UTF8 tmp.lua ; & scripts/studio-agent.ps1 luau $code`.
- The **Bash** tool can run `powershell -NoProfile -Command "& scripts/studio-agent.ps1 luau '…\"escaped\"…'"`
  for short one-liners (used for cleanup/destroys this session).
- A real **`evaluate` grade call takes >30s** (bridge `tool` timeout is 150s). Drive a `prompt`/`evaluate` with
  a generous PowerShell `timeout` (e.g. 200000).
- **A clear capture/result IS the verification — coordinates are NOT** (the user hammered this all along).
- **To view a bridge filmstrip** (capture_animation/capture): the `tool` result only says "non-text tool
  content". Fetch the frames from the sidecar: `Invoke-RestMethod "http://127.0.0.1:8389/captures?count=N&b64=1"`
  → write each base64 image to a PNG → Read it. (The `capture` CLI subcommand pulls only the newest 1.)
- **The `train-category` workflow CAN STALL** (a hung agent — 0-byte output, no transcript activity, the task
  drops from the registry). RECOVER by **resuming**: `Workflow({scriptPath, resumeFromRunId, args})` with the
  SAME args — the completed sweep/distill/judge agents return from cache and it finishes the rest. (The GUI run
  stalled ~30 min in and resumed cleanly; combat + environment ran straight through.)

## 2. What SHIPPED this session (all committed `master`, bridge-verified)
1. **Prioritized Learnings (§17 gap #6)** — per-category, global, durable `learn`/`unlearn` that ride the
   always-on preamble and that `evaluate` folds into its grade prompt. `src/Learnings.luau` (mirrors Memory,
   per-category + index) + `Tools/Learnings.luau` + wiring (deps + preamble + tool context across BOTH
   `AgentLoop.send` call sites + DevBridge's `toolContext`) + LOCAL classification. Review caught + fixed 2 real
   bugs: a cap-boundary persistence bug (count-vs-identity) and an index-orphan edge. Dogfooded the full
   learn→preamble→evaluate-fold→unlearn loop.
2. **`capture_animation` framing fix** — auto-fits the camera to the animation's SWEPT pose extent (a measure
   pre-pass unions the rig's world AABB across sampled poses) + a `zoom` param. `CaptureCore.unionAABB` +
   exposed `aabbOf`. Fixes action poses being cropped.
3. **Animation importing** — `import_animation(animation|source, rig?, clip?)`: import a published animation by
   asset id (`GetKeyframeSequenceAsync`, proven at PluginSecurity in edit) or an in-place
   KeyframeSequence/Animation, RETARGETED onto the target rig BY JOINT NAME (clean R15→R15) with a coverage
   report. `src/AnimationImport.luau` + `Tools/Import.luau`. v1 is name-retarget only; cross-skeleton is v2
   (deferred, §3).
4. **3 more rubric categories → 4 total across 3 DOMAINS** (animation / 2D UI / 3D world): **combat** (29),
   **gui** (35, first non-animation), **environment** (28, first to pass the back-test gate directly).
   Each via the category-general `train-category` workflow → `docs/superpowers/rubrics/<cat>.{config,rubric}.json`
   + `.md` + `<cat>-pilot-report.md` → `scripts/gen_builtin_rubrics.py` → `src/BuiltinRubrics.luau` (now 4
   rubrics) → `use_rubric`/`evaluate` gain the category with no code change.
5. **`evaluate` grades all 4 categories on REAL structure** — `src/GuiEvidence.luau` (UI class census + layout
   quality: scale-vs-offset, AnchorPoint, layouts, UICorner/UIPadding, constraints) + `src/EnvEvidence.luau`
   (Part/Mesh/Model census + material craft + lights + Lighting Atmosphere/post-effects), both folded into
   `Tools/Evaluate.luau` `gatherStructural` category-agnostically. Plus the **grade-call maxTokens 4096→8192**
   fix (a 35-criterion rubric overflowed 4096 → empty result).
6. **Grounded judgment / deferrals:** deferred the FBX→R15 retargeter after inspecting the user's real
   Quaternius import (§3); recovered the stalled GUI workflow via resume; caught + fixed real PluginSecurity
   bugs live (`Lighting.Technology`).

## 3. Key live-learned facts to carry (don't re-derive)
- **Rubric gate nuance:** combat (29) + gui (35) back-tests separated strongly (mean 0.00, gap ~0.5–0.69) but
  `great` missed the 0.70 floor because the `greatArtifactHint` under-claimed the demanding EXCEPTIONAL tier.
  The fix is NOT to weaken the rubric — it's to **re-validate with a FAITHFUL top exemplar**: dispatch ONE
  grader agent to grade the MEAN + a rich GREAT (claiming the full criteria range) against the final rubric,
  then compute the weighted aggregate (baseline w1 / good w2 / exceptional w3; pass1/partial0.5/fail0). Both
  re-validated to great≈0.97 / gap≈0.97 = PASS. **environment (28) passed the gate DIRECTLY (great 0.754)** —
  its hint claimed enough. Survival was 76% (loco) / 100% (combat,gui) / 93% (env) — high; a human-calibration
  pass is the standing optional valve.
- **`evaluate` grade-call needs `maxTokens=8192`** (not 4096) for large rubrics — the 35-criterion gui rubric
  truncated the forced grade response to an empty result at 4096. Fixed in `Tools/Evaluate.luau`. (>~50-criterion
  rubrics would need a compact grade schema — not built.)
- **`Lighting.Technology` is UNREADABLE at PluginSecurity** ("cannot read Technology — lacking capability
  RobloxScript"); reading it throws. `EnvEvidence` dropped it (Atmosphere + post-effects via children are fine).
  Lesson: a plugin can't read RobloxScript-gated Lighting props.
- **`KeyframeSequenceProvider:GetKeyframeSequenceAsync(id)` WORKS at PluginSecurity in edit** (returned the
  default R15 run: 14 keyframes / 224 poses) — the basis of `import_animation` by asset id.
- **Quaternius "Universal Animation Library 2 [Standard]"** imports (Studio 3D Importer) as a **53-bone
  Unreal-mannequin SKINNED rig** (`Bone` instances, NOT Motor6D; UE naming `pelvis`/`spine_01`/`upperarm_l`/
  `thigh_l`/…; T-pose rest; per-bone rest CFrames in an `InitialPoses` folder). **"Import Only as a Model" (the
  default) STRIPS the animations** — to get the clips you must re-import with it UNCHECKED. This is the genuine
  FBX→R15 retarget wall (Bone-skinned → Motor6D + bone-axis + T→A-pose + many-to-one) — DEFERRED (§5).
- **`run_luau` does NOT expose the `plugin` global** — you can't read `SetSetting` directly via the bridge
  `luau` escape hatch (verify Learnings via a `prompt` or the tools instead).
- **`exemplar_refs` is populated for locomotion but EMPTY for combat/gui/environment** (inconsistent
  workflow assemble output) — a relevant detail for exemplar anchoring (§5). `RubricCatalog.render` already
  surfaces exemplar_refs when present.
- **Onboarding a category** = `train-category` (Claude Code, big Workflow) → write the 4 rubric files +
  STAMP top-level `version` + `system_module` (the validator requires them; the workflow output omits them) →
  `python scripts/validate_rubric.py <json>` → `python scripts/gen_builtin_rubrics.py` → `.\build.ps1` +
  USER restart → `use_rubric <cat>` (+ optionally `evaluate <cat>`). Pass workflow `args` as a real OBJECT.

## 4. Module map deltas this session (under `src/`)
- NEW: `Learnings.luau` + `LearningsSpec.luau`, `Tools/Learnings.luau`; `AnimationImport.luau` +
  `AnimationImportSpec.luau`, `Tools/Import.luau`; `GuiEvidence.luau` + `GuiEvidenceSpec.luau`;
  `EnvEvidence.luau` + `EnvEvidenceSpec.luau`; `BuiltinRubrics.luau` regenerated (4 rubrics).
- MOD: `Tools/Capture.luau` (swept-extent framing + `zoom`), `CaptureCore.luau` (`unionAABB`, exposed
  `aabbOf`), `Tools/Evaluate.luau` (learnings fold-in + Gui/Env evidence + 8192), `AgentLoop.luau` +
  `init.server.luau` + `UI/Widget.luau` + `DevBridge.luau` (learnings threading), `Relay.luau` + `RelaySpec.luau`
  (learn/unlearn LOCAL; import_animation RELAY), `SystemPrompt.luau` (Priority-learnings + import sections),
  `Tools/init.luau` (learn/unlearn/import registered).
- Specs run in-Studio via a temporary `require(script.XSpec).run()` in `init.server.luau` (always reverted
  after the dogfood). Static gate every step: `stylua src ; selene src ; rojo build` — selene MUST be 0/0.

## 5. NEXT options (pick one — none are pending/blocking)
**Recommended highest lever (needs the USER's input — a short design chat):**
- **Full exemplar-image anchoring (§17 #5)** — make `evaluate`/the agent SEE what "great" looks like, not
  just read text criteria. The real version: `evaluate` captures the build + visually grades it against
  CURATED exemplar images per category. It needs the user's call on **exemplar sources + the tiered licensing
  rule** (CC0/own/official → store+ship; copyrighted → reference-only, learn method not expression). A LIGHT
  solo version exists too: backfill the empty `exemplar_refs` (combat/gui/environment) from each criterion's
  `provenance.sources` + a SystemPrompt nudge to `web_fetch`/view them — modest, but activates a dormant slot.

**Other solo-feasible:**
- A 5th rubric category (diminishing returns — generalization is already proven across 3 domains).
- More category-aware `evaluate` evidence is DONE for the 4 live categories; a new category would want its own
  evidence gatherer if it's a new domain.

**Deferred (need a concrete trigger / external input):**
- **FBX→R15 cross-skeleton retargeter** — the Quaternius/UE-mannequin wall (§3). Only worth it when there's a
  real need to BUILD with those clips (not just study). First step if revisited: have the user re-import a
  Quaternius FBX with "Import Only as a Model" UNCHECKED so the animations land as KeyframeSequences.
- **Open Cloud animation export** (the real animation publish) — needs a scoped Open Cloud API key.
- **Client-play structured grading** (evaluate in the Play CLIENT view) — relay rework.

## 6. Build / verify loop
`stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0).
`.\build.ps1` installs to the Plugins folder. For DataModel/API behavior use the **dev bridge** (don't guess),
and **always LOOK at the capture/result**, not coordinates. You cannot run Luau locally. Execute multi-task
plans with **superpowers:subagent-driven-development** (fresh implementer + review per task), exactly as this
session did. Commit per task; don't push.
