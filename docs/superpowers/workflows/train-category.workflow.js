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

// ---- Sweep: multi-modal source sweep ----
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

// ---- Distill: cluster into candidate criteria ----
phase('Distill')
const distilled = await agent(
  `Cluster these ${CATEGORY} techniques into concrete, gradable candidate CRITERIA organized by tier (baseline/good/exceptional). Each criterion must check SYSTEMS DEPTH, not surface presence (e.g. not "has an animation" but "locomotion warps by speed AND direction via a blend tree"). Merge duplicates. Ensure the known killer systems are represented where evidence supports them: ${JSON.stringify(KILLER)}.\n\nTECHNIQUES:\n${JSON.stringify(allTechniques, null, 1)}`,
  { label: 'distill', phase: 'Distill', schema: CRITERIA_SCHEMA })
log(`Distilled ${distilled.criteria.length} candidate criteria`)

// ---- Judge: above-generic, 3 skeptical votes per criterion ----
phase('Judge')
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

// ---- Assemble: final rubric to the schema ----
phase('Assemble')
let rubric = await agent(
  `Assemble these surviving criteria into a FINAL rubric for category "${CATEGORY}" following the schema EXACTLY. Assign stable ids and a fixed order_index (baseline first, then good, then exceptional). Fill grading.pass/partial/fail, evidence_required, concrete_fix, and provenance per criterion. Set system_module="${CATEGORY}" and module="${CATEGORY}". Keep order stable (scoring-bias defense).\n\nSURVIVORS:\n${JSON.stringify(survivors, null, 1)}`,
  { label: 'assemble', phase: 'Assemble', schema: RUBRIC_SCHEMA })

// ---- Harden: scoring-bias check + discrimination back-test + self-optimization ----
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

// ---- Critique: completeness ----
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
