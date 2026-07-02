// factory-iteration: ONE attended iteration of the game-factory loop.
// BUILD (bounded tool RPCs — NEVER the in-plugin `prompt` path, whose 170s DevBridge cap
// half-finishes builds) -> GATE (artifact walk: Source + attribute keys + names vs the reserved
// test namespace) -> VERIFY (real playtest, player-level probes; unavailable oracle => UNVERIFIED,
// never PASSED) -> STAGE (everything a 2-minute human promotion pass needs; recipes are drafts in
// staging, never auto-saved skills). Stages are SEQUENTIAL: the dev bridge is a single-command
// queue — exactly one bridge client at a time.
//
// args: { rungId: string, sabotage?: boolean }  — sabotage deliberately omits bind_hitbox so the
// verify oracle must land FAILED (the discrimination test: a loop is validated only when it
// demonstrably says NO).
export const meta = {
  name: 'factory-iteration',
  description: 'One attended game-factory iteration: build a curriculum rung, gate it, verify it in a real playtest, stage the evidence',
  phases: [
    { title: 'Build', detail: 'bounded bridge tool RPCs' },
    { title: 'Gate', detail: 'test-namespace artifact walk' },
    { title: 'Verify', detail: 'real playtest, player-level probes' },
    { title: 'Stage', detail: 'evidence + draft recipe to staging' },
  ],
}

const ROOT = 'C:\\Users\\manso\\Desktop\\Claude-Plugin'
const PS = `powershell -NoProfile -ExecutionPolicy Bypass -File "${ROOT}\\scripts\\studio-agent.ps1"`

const rungId = (args && args.rungId) || 'weapon-spear'
const sabotage = !!(args && args.sabotage)

const BRIDGE_HOWTO = `
HOW TO DRIVE THE LIVE STUDIO PLUGIN (from Bash): ${PS} <verb> …
- ${PS} tool <name> '<json>'   e.g. tool make_tool '{"target":"game.Workspace.X","name":"Y"}'
- ${PS} luau '<luau code>'     (persistent REPL; returns JSON {returns,stdout,stderr})
- ONE command at a time; each returns ok=True/False + the result text. NEVER use the 'prompt' verb.
- Available tools include: run_luau (via the luau verb), create_instance, set_property, get_tree,
  get_properties, destroy_instance, make_tool, grip_tool, bind_behavior, bind_hitbox, make_npc,
  list_scripts, get_script, edit_script, grep_source, playtest_start/act/eval/logs/capture/status/stop,
  game_pull. Repo root: ${ROOT}.
`

const t0Spent = budget.spent()

// ---- BUILD ----
phase('Build')
const BUILD_SCHEMA = {
  type: 'object',
  required: ['artifactPath', 'toolName', 'config', 'steps', 'ok'],
  properties: {
    ok: { type: 'boolean' },
    artifactPath: { type: 'string', description: 'instance path of the built artifact (the Tool)' },
    toolName: { type: 'string' },
    config: { type: 'object', description: 'the EXACT configured numbers (windup/active/cooldown/damage/reach)' },
    steps: { type: 'array', items: { type: 'string' }, description: 'the bridge calls made, in order' },
    notes: { type: 'string' },
  },
}
const build = await agent(
  BRIDGE_HOWTO +
  `\nYou are the factory BUILD stage. Read ${ROOT}\\factory\\curriculum.json and build rung "${rungId}" in the LIVE place, using ONLY bounded bridge calls (tool/luau verbs — never prompt).` +
  `\nFor a melee weapon: (1) park any existing Tools out of StarterPack first (move them to ServerStorage, remember which — report in notes); (2) build a simple but SHAPED visual from primitives in Workspace (a spear = long shaft + leaf-shaped tip, distinct from a sword); (3) make_tool with the grip part as handle; (4) move the Tool to StarterPack; (5) bind_behavior with timings matching the rung brief (spear = SLOWER than the 0.15/0.15/0.4 defaults, e.g. windup 0.5, active 0.25, cooldown 0.9); ` +
  (sabotage
    ? `(6) SABOTAGE RUN: deliberately SKIP bind_hitbox entirely — do not mention the omission anywhere in the artifact; this tests whether VERIFY catches a weapon that deals no damage.`
    : `(6) bind_hitbox with reach LONGER than a sword (e.g. 9) and damage e.g. 20, cooldown ~0.9 matching the swing.`) +
  `\nReport the exact config you set. Do NOT playtest (that is the VERIFY stage's job). Do NOT create anything named or attributed StudioAgentTest_*.`,
  { label: `build:${rungId}${sabotage ? ':sabotaged' : ''}`, phase: 'Build', schema: BUILD_SCHEMA }
)
if (!build || !build.ok) {
  return { rung: rungId, sabotage, status: 'BLOCKED', reason: 'build stage failed', build }
}
const buildSpent = budget.spent() - t0Spent

// ---- GATE ----
phase('Gate')
const GATE_SCHEMA = {
  type: 'object',
  required: ['clean', 'hits'],
  properties: {
    clean: { type: 'boolean' },
    hits: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },
  },
}
const gate = await agent(
  BRIDGE_HOWTO +
  `\nYou are the factory GATE stage. Artifact: ${build.artifactPath} (a Tool probably now in game.StarterPack.${build.toolName}). Walk the ENTIRE artifact via one luau call: for the artifact root and every descendant, check (a) Instance.Name, (b) every GetAttributes() KEY, (c) every LuaSourceContainer's ScriptEditorService:GetEditorSource — against BOTH the reserved prefix "StudioAgentTest_" AND the legacy denylist {"TestAutoKill"}. Collect hits as "kind:path[.attr]". Also run the same walk over any support instances the build created outside the Tool (check the build steps: ${JSON.stringify(build.steps)}).` +
  `\nA generated launcher mentioning nothing test-related is CLEAN. clean=true only with zero hits.`,
  { label: 'gate', phase: 'Gate', schema: GATE_SCHEMA }
)
if (!gate) {
  return { rung: rungId, sabotage, status: 'BLOCKED', reason: 'gate stage failed to run', build }
}
if (!gate.clean) {
  return { rung: rungId, sabotage, status: 'BLOCKED', reason: 'test symbols in the artifact', gate, build }
}
const gateSpent = budget.spent() - t0Spent - buildSpent

// ---- VERIFY ----
phase('Verify')
const VERIFY_SCHEMA = {
  type: 'object',
  required: ['status', 'evidence'],
  properties: {
    status: { type: 'string', enum: ['PASSED', 'FAILED', 'UNVERIFIED'] },
    evidence: { type: 'object', required: ['recordLine', 'damageLine'], properties: {
      recordLine: { type: 'string', description: 'the exact act-record output incl. the [tool= w= a= c=] echo' },
      damageLine: { type: 'string', description: 'the exact shit-verb output (dummy health before/after)' },
      logExcerpt: { type: 'string' },
    } },
    reasons: { type: 'array', items: { type: 'string' } },
  },
}
const verify = await agent(
  BRIDGE_HOWTO +
  `\nYou are the factory VERIFY stage — a SKEPTIC: your job is to find reasons to FAIL. Rung "${rungId}", artifact ${build.artifactPath}, configured: ${JSON.stringify(build.config)}. Oracle (from factory/curriculum.json): behavior timings match the CONFIGURED numbers AND the weapon deals EXACTLY the configured damage once per swing.` +
  `\nProcedure (one bridge call at a time): (1) ensure a TargetDummy exists: luau — clone game.ServerStorage.EnemyTemplate to workspace as "TargetDummy", pivot near spawn, anchor its HumanoidRootPart; (2) tool playtest_start; (3) tool playtest_act {"verb":"record"} — the output ends with [tool=<name> w=<x> a=<y> c=<z>]: FAIL if the tool name is not ${build.toolName} or the echoed config does not match the build's configured numbers, and FAIL if the observed state timings diverge wildly from them; (4) the shit damage probe: run "${PS} play shit" — FAIL unless delta equals the configured damage EXACTLY (a sabotaged/broken weapon shows delta=0); (5) tool playtest_logs {"since":0} — check for runtime errors mentioning the artifact; (6) ALWAYS tool playtest_stop, then luau to destroy workspace.TargetDummy.` +
  `\nIf ANY oracle step is unavailable (playtest will not start, probe errors), status=UNVERIFIED with the reason — never PASSED on partial evidence. Quote the raw output lines verbatim in evidence.`,
  { label: `verify:${rungId}`, phase: 'Verify', schema: VERIFY_SCHEMA, effort: 'high' }
)
if (!verify) {
  return { rung: rungId, sabotage, status: 'UNVERIFIED', reason: 'verify stage failed to run', build, gate }
}
const verifySpent = budget.spent() - t0Spent - buildSpent - gateSpent

// ---- STAGE ----
phase('Stage')
const STAGE_SCHEMA = {
  type: 'object',
  required: ['staged', 'stagingId'],
  properties: { staged: { type: 'boolean' }, stagingId: { type: 'string' }, note: { type: 'string' } },
}
const stagingId = `${rungId}${sabotage ? '-sabotaged' : ''}`
const stage = await agent(
  BRIDGE_HOWTO +
  `\nYou are the factory STAGE step. Write the staging entry for the human morning promotion pass.` +
  `\n(1) If the run PASSED (${verify.status === 'PASSED'}): move the artifact ${build.artifactPath} into a ServerStorage.FactoryStaging folder (create if absent) via luau, so the place stays clean; if it FAILED/UNVERIFIED, DESTROY the artifact instead. Restore any Tools the build parked (notes: ${JSON.stringify(build.notes || '')}).` +
  `\n(2) POST the staging entry with curl to http://127.0.0.1:8389/store/staging/${stagingId} as JSON:` +
  ` {rung:"${rungId}", sabotage:${sabotage}, status:"${verify.status}", gateReport:<gate hits/clean>, evidence:<the verify evidence verbatim>, artifactTrace:{path, config:${JSON.stringify(build.config)}, steps:${JSON.stringify(build.steps)}}, recipe:{provisional:true, text:"<3-6 line draft: how to build this rung well, from the build steps>"}}` +
  `\n(3) Confirm with curl GET that the entry reads back. Report staged=true only after the read-back.`,
  { label: `stage:${stagingId}`, phase: 'Stage', schema: STAGE_SCHEMA }
)

return {
  rung: rungId,
  sabotage,
  status: verify.status,
  gateClean: gate.clean,
  evidence: verify.evidence,
  reasons: verify.reasons || [],
  staged: stage ? stage.staged : false,
  tokens: { build: buildSpent, gate: gateSpent, verify: verifySpent, total: budget.spent() - t0Spent },
}
