export const meta = {
  name: 'train-recipe',
  description: 'Build a rubric-anchored, above-the-mean BUILD GUIDE for one asset category (build-angled sweep -> distill into tiered steps -> above-generic step critic -> coverage fill vs the rubric -> assemble -> completeness)',
  phases: [
    { title: 'Sweep' },
    { title: 'Distill' },
    { title: 'Critique-steps' },
    { title: 'Cover' },
    { title: 'Assemble' },
    { title: 'Review' },
  ],
}

// ---- args: the rubric is the SPINE; everything else grounds the build steps ----
let cfg = args || {}
if (typeof cfg === 'string') { try { cfg = JSON.parse(cfg) } catch (e) { cfg = {} } }
const CATEGORY = cfg.category || 'locomotion'
const DESCRIPTION = cfg.description || 'character locomotion / movement animation'
const KILLER = cfg.killerSystems || []
const RUBRIC = cfg.rubric || { module: CATEGORY, criteria: [] }
const TOOLS = cfg.toolCatalog || []
const MAX_FILL = cfg.maxFillRounds || 3

const CRIT_IDS = (RUBRIC.criteria || []).map(c => c.id).filter(Boolean)
const CRIT_BRIEF = (RUBRIC.criteria || []).map(c => ({ id: c.id, tier: c.tier, statement: c.statement }))
log(`Config: category=${CATEGORY}, rubricCriteria=${CRIT_IDS.length}, killerSystems=${KILLER.length}, tools=${TOOLS.length}, maxFill=${MAX_FILL}`)

// ---- pure helpers ----
function coveredIds(tiers) {
  const set = new Set()
  for (const t of (tiers || [])) for (const s of (t.steps || [])) for (const id of (s.addresses_criteria || [])) set.add(id)
  return set
}
function uncovered(tiers) {
  const cov = coveredIds(tiers)
  return CRIT_IDS.filter(id => !cov.has(id))
}
function allSteps(tiers) {
  const out = []
  for (const t of (tiers || [])) for (const s of (t.steps || [])) out.push({ ...s, tier: t.tier })
  return out
}

// ---- schemas ----
const FINDINGS_SCHEMA = { type: 'object', required: ['techniques'], properties: {
  angle: { type: 'string' },
  techniques: { type: 'array', items: { type: 'object', required: ['technique'], properties: {
    technique: { type: 'string' }, tier_hint: { type: 'string' },
    how_to_build: { type: 'string' }, tools: { type: 'array', items: { type: 'string' } },
    pitfall: { type: 'string' }, source: { type: 'string' } } } } } }

const STEP_OBJ = { type: 'object', required: ['id', 'instruction'], properties: {
  id: { type: 'string' }, instruction: { type: 'string' },
  addresses_criteria: { type: 'array', items: { type: 'string' } },
  tools: { type: 'array', items: { type: 'string' } }, pitfalls: { type: 'string' } } }

const TIERS_SCHEMA = { type: 'object', required: ['tiers'], properties: {
  overview: { type: 'string' },
  killer_systems: { type: 'array', items: { type: 'object', required: ['name'], properties: {
    name: { type: 'string' }, what: { type: 'string' }, how: { type: 'string' } } } },
  common_pitfalls: { type: 'array', items: { type: 'string' } },
  tiers: { type: 'array', items: { type: 'object', required: ['tier', 'steps'], properties: {
    tier: { type: 'string' }, goal: { type: 'string' },
    steps: { type: 'array', items: STEP_OBJ } } } } } }

const VOTE_SCHEMA = { type: 'object', required: ['id', 'verdict'], properties: {
  id: { type: 'string' }, verdict: { type: 'string' },
  reason: { type: 'string' }, raised_instruction: { type: 'string' } } }

const FILL_SCHEMA = { type: 'object', required: ['steps'], properties: {
  steps: { type: 'array', items: { type: 'object', required: ['id', 'instruction', 'tier', 'addresses_criteria'], properties: {
    id: { type: 'string' }, instruction: { type: 'string' }, tier: { type: 'string' },
    addresses_criteria: { type: 'array', items: { type: 'string' } },
    tools: { type: 'array', items: { type: 'string' } }, pitfalls: { type: 'string' } } } } } }

const GUIDE_SCHEMA = { type: 'object', required: ['module', 'tiers'], properties: {
  module: { type: 'string' }, version: { type: 'string' }, system_module: { type: 'string' },
  rubric_version: { type: 'string' }, overview: { type: 'string' },
  killer_systems: { type: 'array', items: { type: 'object', properties: {
    name: { type: 'string' }, what: { type: 'string' }, how: { type: 'string' } } } },
  tiers: { type: 'array', items: { type: 'object', required: ['tier', 'steps'], properties: {
    tier: { type: 'string' }, goal: { type: 'string' },
    steps: { type: 'array', items: { type: 'object', required: ['id', 'order_index', 'instruction'], properties: {
      id: { type: 'string' }, order_index: { type: 'number' }, instruction: { type: 'string' },
      addresses_criteria: { type: 'array', items: { type: 'string' } },
      tools: { type: 'array', items: { type: 'string' } }, pitfalls: { type: 'string' } } } } } } },
  common_pitfalls: { type: 'array', items: { type: 'string' } } } }

const REVIEW_SCHEMA = { type: 'object', required: ['assessment'], properties: {
  killer_systems_covered: { type: 'array', items: { type: 'string' } },
  killer_systems_missing: { type: 'array', items: { type: 'string' } },
  build_order_sound: { type: 'boolean' }, assessment: { type: 'string' } } }

// ---- Sweep: build-angled (how to BUILD, not what separates good/generic — the rubric has that) ----
phase('Sweep')
const ANGLES = [
  { key: 'workflow', prompt: `Search the Roblox creator-docs GitHub mirror + create.roblox.com + DevForum for the step-by-step WORKFLOW pros use to BUILD ${DESCRIPTION} (the build ORDER, what to set up first, how the pieces connect). Extract concrete BUILD techniques, each with a tier_hint (baseline/good/exceptional), how_to_build (the actual steps), the Roblox tools/APIs it uses, a pitfall, and the source URL.` },
  { key: 'killer-impl', prompt: `For ${DESCRIPTION}, research HOW to IMPLEMENT its killer systems in Roblox: ${JSON.stringify(KILLER)}. For each, find the concrete build technique (APIs, instances, structure). Extract techniques with tier_hint, how_to_build, tools, pitfall, source URL.` },
  { key: 'pitfalls', prompt: `Search DevForum CRITIQUE + "why does my ${CATEGORY} look bad / feel off" threads. Extract the BUILD MISTAKE and the FIX for each (the fix is the technique), with tier_hint, how_to_build (the corrected approach), tools, the pitfall it avoids, and source URL.` },
  { key: 'video', prompt: `Find YouTube build tutorials/breakdowns on ${DESCRIPTION} and read their transcripts. Extract the BUILD steps the author actually performs (in order), each with tier_hint, how_to_build, tools, pitfall, and source URL.` },
]
const sweep = (await parallel(ANGLES.map(a => () =>
  agent(a.prompt, { label: `sweep:${a.key}`, phase: 'Sweep', schema: FINDINGS_SCHEMA })
))).filter(Boolean)
const allTech = sweep.flatMap(s => s.techniques || [])
log(`Sweep: ${allTech.length} build techniques across ${sweep.length} angles`)

// ---- Distill: cluster into tier-structured ordered steps, each mapped to rubric criterion ids ----
phase('Distill')
const REAL_TOOLS = TOOLS.length ? `\n\nThe agent's REAL build tools (cite these by name in step.tools; do NOT invent tool names): ${JSON.stringify(TOOLS)}` : ''
let draft = await agent(
  `You are writing a BUILD GUIDE for "${CATEGORY}" — the proactive, tier-by-tier approach for HOW to build a great one. The guide must let a builder CLEAR this rubric, so map each step to the rubric criterion ids it satisfies. Organize steps by tier (baseline -> good -> exceptional), in BUILD ORDER (dependencies before dependents). Each step: a concrete instruction citing the real tools, the addresses_criteria (rubric ids it satisfies), and a pitfall. Also give an overview, the killer_systems (name/what/how-to-build), and common_pitfalls.\n\nRUBRIC CRITERIA (the bar to cover):\n${JSON.stringify(CRIT_BRIEF, null, 1)}\n\nBUILD TECHNIQUES (from research):\n${JSON.stringify(allTech, null, 1)}${REAL_TOOLS}`,
  { label: 'distill', phase: 'Distill', schema: TIERS_SCHEMA })
log(`Distilled ${allSteps(draft.tiers).length} steps; uncovered after distill: ${uncovered(draft.tiers).length}/${CRIT_IDS.length}`)

// ---- Critique-steps: above-generic judge per step (drop/raise generic filler) ----
phase('Critique-steps')
const steps = allSteps(draft.tiers)
const judged = (await parallel(steps.map(s => () =>
  agent(`ABOVE-GENERIC BUILD-STEP JUDGE (STRICT). The GENERIC FLOOR for ${CATEGORY} is what default/generic builds + a basic tutorial already produce. REJECT this build step if it is generic filler the floor already does (e.g. "add a walk animation", "make a part") rather than deliberate systems-depth authoring. Use "raise" (with a tougher raised_instruction) if it is only slightly above the floor. Keep only steps that teach above-the-mean construction. When in doubt about genuine generic-ness, prefer "raise" over "reject" so we don't lose rubric coverage.\n\nSTEP: ${JSON.stringify(s)}`,
    { label: `judge:${s.id}`, phase: 'Critique-steps', schema: VOTE_SCHEMA })
))).filter(Boolean)
const verdictById = {}
for (const v of judged) verdictById[v.id] = v
for (const t of draft.tiers) {
  t.steps = (t.steps || []).filter(s => (verdictById[s.id]?.verdict !== 'reject')).map(s => {
    const v = verdictById[s.id]
    return (v && v.verdict === 'raise' && v.raised_instruction) ? { ...s, instruction: v.raised_instruction } : s
  })
}
log(`Critique: ${steps.length - allSteps(draft.tiers).length} generic steps dropped; uncovered now: ${uncovered(draft.tiers).length}`)

// ---- Cover: fill loop until every rubric criterion is addressed by some step ----
phase('Cover')
let round = 0
while (uncovered(draft.tiers).length > 0 && round < MAX_FILL) {
  const gaps = uncovered(draft.tiers)
  const fill = await agent(
    `These rubric criteria are NOT yet addressed by any build step in the "${CATEGORY}" guide. Write the concrete BUILD step(s) that would satisfy each — above the generic floor, citing the real tools, assigned to the right tier (match the criterion's tier). If a criterion is genuinely un-buildable with the available tools, still return a best-effort step describing what WOULD satisfy it and note the gap in pitfalls.\n\nUNADDRESSED CRITERIA:\n${JSON.stringify((RUBRIC.criteria || []).filter(c => gaps.includes(c.id)), null, 1)}\n\nREAL TOOLS: ${JSON.stringify(TOOLS)}`,
    { label: `fill#${round}`, phase: 'Cover', schema: FILL_SCHEMA })
  for (const ns of (fill.steps || [])) {
    let tier = draft.tiers.find(t => t.tier === ns.tier)
    if (!tier) { tier = { tier: ns.tier || 'good', goal: '', steps: [] }; draft.tiers.push(tier) }
    tier.steps.push({ id: ns.id, instruction: ns.instruction, addresses_criteria: ns.addresses_criteria || [], tools: ns.tools || [], pitfalls: ns.pitfalls || '' })
  }
  round++
  log(`Cover r${round}: uncovered ${uncovered(draft.tiers).length}/${CRIT_IDS.length}`)
}
const finalUncovered = uncovered(draft.tiers)

// ---- Assemble: to the build-guide schema ----
phase('Assemble')
const assembled = await agent(
  `Assemble this into a FINAL build guide for category "${CATEGORY}" following the schema EXACTLY. Set module="${CATEGORY}", system_module="${CATEGORY}", version="1.0", rubric_version="${RUBRIC.version || '1.0'}". Order tiers baseline -> good -> exceptional; within each tier assign a stable order_index in build order starting at 1. Keep every step's addresses_criteria + tools + pitfalls. Preserve overview, killer_systems, common_pitfalls.\n\nDRAFT:\n${JSON.stringify(draft, null, 1)}`,
  { label: 'assemble', phase: 'Assemble', schema: GUIDE_SCHEMA })
// stamp provenance.coverage deterministically (do not trust the model for the count)
assembled.module = CATEGORY
assembled.version = assembled.version || '1.0'
assembled.system_module = CATEGORY
assembled.rubric_version = assembled.rubric_version || (RUBRIC.version || '1.0')
const addressedCount = CRIT_IDS.length - finalUncovered.length
assembled.provenance = {
  sources: allTech.map(t => t.source).filter(Boolean),
  confidence: finalUncovered.length === 0 ? 'high' : 'medium',
  coverage: { criteria_total: CRIT_IDS.length, criteria_addressed: addressedCount, uncovered: finalUncovered },
}

// ---- Review: completeness ----
phase('Review')
const review = await agent(
  `Completeness review of the "${CATEGORY}" BUILD GUIDE. Killer systems that MUST appear as build steps: ${JSON.stringify(KILLER)}. Report which are covered vs missing, whether the build ORDER is sound (dependencies before dependents), and an overall assessment of whether this guide, if followed, produces an above-the-mean build that clears the rubric (coverage = ${addressedCount}/${CRIT_IDS.length}).\n\nGUIDE:\n${JSON.stringify(assembled.tiers.map(t => ({ tier: t.tier, steps: (t.steps || []).map(s => ({ id: s.id, instruction: s.instruction })) })), null, 1)}`,
  { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA })

return {
  category: CATEGORY,
  guide: assembled,
  coverage: { total: CRIT_IDS.length, addressed: addressedCount, uncovered: finalUncovered },
  review,
  provenance: { angles: ANGLES.map(a => a.key), techniqueCount: allTech.length, fillRounds: round },
}
