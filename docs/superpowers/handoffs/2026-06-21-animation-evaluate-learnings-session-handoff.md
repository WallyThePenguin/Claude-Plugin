# Studio Agent — Animation + Evaluate + Learnings session handoff (2026-06-21)

**Read this, then do the ONE pending step: execute the prioritized-Learnings plan
[`docs/superpowers/plans/2026-06-21-prioritized-learnings.md`](../plans/2026-06-21-prioritized-learnings.md)
(7 tasks). Everything before it is committed clean on `master`.**

## 0. Environment NOW (running — don't re-create)
- **Dev bridge + sidecar + tunnel are UP.** Drive the plugin from the shell with `scripts/studio-agent.ps1`
  (`tool <name> '<json>'`, `luau '<code>'`, `prompt '<text>'`, `logs`, `capture [out.png]`). See the dev-bridge
  spec `docs/superpowers/specs/2026-06-21-studio-agent-dev-bridge-design.md`.
- **Studio has the SLICE E (Evaluate) build loaded** (commit `e8ddc3b`). A plugin CODE change needs
  `.\build.ps1` + a **USER Studio restart** ("Restart to update") — the bridge can't hot-reload itself.
- Workspace is a clean baseplate (the Evaluate dogfood was design-only; the run-cycle `AgentRig` demo was on a
  pre-restart baseplate and is gone). **Don't delete the user's own `Rig` model** if one appears.

## 1. CRITICAL bridge gotchas (don't re-derive)
- From the **PowerShell tool**, invoke the CLI as **`& scripts/studio-agent.ps1 …`** (direct) — a nested
  `powershell -File …` double-parses and STRIPS inner double-quotes from Luau string literals. The Bash tool
  doesn't have this problem.
- Keep Luau passed via the bridge **ASCII-only** (a UTF-8 em-dash breaks PowerShell 5.1 / the sidecar JSON).
  For big Luau, Write it to a temp `.lua` (ASCII) and `Get-Content -Raw -Encoding UTF8 | & …ps1 luau $code`.
- A real **`evaluate` grade call takes >30s** — the bridge `tool` timeout was bumped to **150s**
  (`scripts/studio-agent.ps1`). Short tools return instantly.
- **A clear capture/result IS the verification — coordinates are NOT** (the user hammered this all session).

## 2. The ONE pending step — execute the prioritized-Learnings plan
Plan: [`2026-06-21-prioritized-learnings.md`](../plans/2026-06-21-prioritized-learnings.md). Spec:
[`2026-06-21-studio-agent-prioritized-learnings-design.md`](../specs/2026-06-21-studio-agent-prioritized-learnings-design.md).
**What it builds (§17 gap #6 — the loop that LEARNS):** a dedicated `src/Learnings.luau` (mirrors
`src/Memory.luau`, but **per-category** + **global**, one `SetSetting` key per category + an index key) +
`learn`/`unlearn` tools + a "# Priority learnings (apply first)" preamble block + `evaluate` folding the graded
category's learnings into its grade prompt. 7 tasks: store+spec → tools → wiring (init.server deps + AgentLoop
preamble/context) → evaluate fold-in → SystemPrompt → Relay LOCAL → build+dogfood+HANDOFF. **Run it with
superpowers:subagent-driven-development** (the pattern used for slices D + E this session: implementer →
combined spec+quality review per code task → diff-verify the trivial edits; the full `Learnings.luau` code is
in the plan, mirroring `Memory.luau`). The final task needs a **USER Studio restart** for the bridge dogfood.
**Note (plan Task 3):** the AgentLoop edits are described by mirroring the existing `deps.memory:promptBlock()`
preamble append + the tool-context `memory =` thread — grep AgentLoop for `:promptBlock()` and the toolContext
construction and add `learnings` analogously (read AgentLoop.luau; it wasn't read this session).

## 3. What SHIPPED this session (all committed `master`, live-verified via the bridge)
1. **Rig-rework Task 7** (native R15 + `StepAnimations` posing) — dogfooded; commit `96a8e1b`. (Prior handoff:
   `2026-06-21-dev-bridge-rig-rework-session-handoff.md`.)
2. **Slice D — Animation engine** ✅ — flip-book keyposes → native edit-mode filmstrip. `src/AnimationClip.luau`
   (build a `KeyframeSequence` of nested `Pose`s under `rig/AnimSaves/<clip>`) + `Tools/Animate.luau`
   (`add_keyframe`/`list_clip`/`remove_keyframe`/`clear_clip`/`export_animation`) + the revived
   `capture_animation` filmstrip (`TimePosition` scrub + `StepAnimations(0)`). **Live bug caught+fixed:**
   `AnimationTrack:Stop()` does NOT remove a playing track in edit (it overrides manual poses) → teardown
   DESTROYS the temp Animator; `capture_animation` defaults the clip to `AgentClip`. Spec/plan
   `2026-06-21-studio-agent-animation-engine-design.md` / `2026-06-21-animation-engine.md`. Then **authored a
   real looping run cycle** live (9 keyframes, ran in the viewport) — feasibility confirmed by the user.
3. **Slice E — Evaluate tool** ✅ — grades a built locomotion SYSTEM vs the Locomotion rubric via
   SCHEMA-ENFORCED structured output. `src/EvaluateReport.luau` (`buildGradeTool`/`validateGrades`/
   `renderReport`) + **`Anthropic.requestStructured`** (forced `tool_choice` + prose fallback) +
   `Tools/Evaluate.luau` (structural dump + design claim → grade → report). **KEY RESULT: the CLIProxyAPI
   HONORS `tool_choice`** (structured, not prose). **Discrimination gradient: probe 0/16 → mid 9/16 → strong
   15/16 pass** — the grader separates with fine resolution and cites evidence + the rubric's concrete_fix. An
   adversarial-review Workflow found+fixed 2 edge bugs (empty/truncated grade responses). `evaluate` is
   **LOCAL** (needs `rubrics`+`anthropic` deps). Spec/plan `…evaluate-tool-design.md` / `…evaluate-tool.md`.

## 4. Key live-learned facts to carry (don't re-derive)
- **Structured output works through the proxy** (`tool_choice={type:"tool",name}` honored) — so the grade
  schema path is solid. The proxy still strips `system` (deliver everything via the leading preamble).
- The **Locomotion rubric grades a SYSTEM's architecture**, not a clip's looks — Evaluate judges structural +
  design-claim evidence (captures optional). A single animation clip scores low until the system exists.
- **Native edit-mode animation:** `KeyframeSequenceProvider:RegisterKeyframeSequence(ks)` → `LoadAnimation` →
  `Play(0)` → `TimePosition=t; StepAnimations(0)` evaluates any time (native interpolation). **`ks:AddKeyframe`
  is required** (bare `.Parent` leaves length 0). Tear down the Animator to return manual control.

## 5. After prioritized Learnings (NEXT options)
Per the Slice E HANDOFF block: onboard a **2nd rubric category** (re-run `train-category`); **exemplar-image
anchoring** (§17 #5); **client-play structured grading** + the **`capture_animation` zoom param** (slice-D
follow-up: the filmstrip auto-frames too tight on splayed action poses); **Open Cloud animation export** (the
real publish — Open Cloud Assets API added animation `.rbxm` upload 2025-10-23, scoped API key, via the
sidecar; live-test how a plugin produces the `.rbxm`); **slice C — drag posing** (interactive, needs
computer-use).

## 6. Build / verify loop
`stylua src ; selene src ; rojo build default.project.json --output StudioAgent.rbxm` (selene MUST be 0/0).
`.\build.ps1` installs to the Plugins folder. For DataModel/API behavior use the **dev bridge** (don't guess),
and **always LOOK at the capture / result**, not coordinates. You cannot run Luau locally.
