export const meta = {
  name: 'verify-rubric',
  description: 'Independently stress-test a category rubric: rubric-BLIND expert build (honest great-side) + adversarial per-criterion skeptics + median of independent graders, vs the fixed generic floor',
  whenToUse: 'After train-category produces a rubric, to prove its discrimination back-test passes WITHOUT teaching-to-the-test — the great artifact is written by an expert who never sees the criteria.',
  phases: [
    { title: 'Independent', detail: 'rubric-blind expert build + 1 skeptic per criterion, in parallel' },
    { title: 'Grade', detail: '3 independent graders on the expert build (median) + 1 on the floor' },
  ],
}

// args = { category, criteria:[{id,tier,statement,grading}], mean:"<generic floor desc>", greatFraming:"<game brief>" }
const cat = args.category
const crit = args.criteria
const MEAN = args.mean
const FRAMING = args.greatFraming
const API = (args.apiSurface || '')
const TIER_W = { baseline: 1, good: 2, exceptional: 3 }
const SCORE_V = { pass: 1.0, partial: 0.5, fail: 0.0 }

const SKEPTIC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['id', 'verdict', 'reason', 'real_example'],
  properties: {
    id: { type: 'string' },
    verdict: { type: 'string', enum: ['keep', 'kill'] },
    reason: { type: 'string', description: '<=25 words' },
    real_example: { type: 'string', description: 'a concrete real shipped build that has this, or "none" if you killed it' },
  },
}
const GRADE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['rows'],
  properties: {
    rows: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['id', 'score', 'evidence'],
        properties: {
          id: { type: 'string' },
          score: { type: 'string', enum: ['pass', 'partial', 'fail'] },
          evidence: { type: 'string', description: 'quote the build text that satisfies/misses the criterion; <=30 words' },
        },
      },
    },
  },
}

function aggregate(rows) {
  const tier = {}
  for (const c of crit) tier[c.id] = c.tier
  let num = 0, den = 0
  for (const r of rows || []) {
    const w = TIER_W[tier[r.id]] || 1
    num += w * (SCORE_V[r.score] || 0)
    den += w
  }
  return den ? num / den : 0
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b)
  const m = Math.floor(s.length / 2)
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

// Category-GENERAL expert prompt (rubric-blind): the expert never sees the criteria, so the great-side
// score reflects what an excellent build contains independent of the rubric. apiSurface (optional) nudges
// the expert to enumerate the category's real Roblox API surface so the build is mechanistic, not vague.
const EXPERT_PROMPT =
  `You are a top-1% Roblox ${cat} engineer with a decade of shipped titles. A studio hires you to ` +
  `design the COMPLETE ${cat} system for this game:\n\n"${FRAMING}"\n\n` +
  `Describe, EXHAUSTIVELY and MECHANISTICALLY, the ${cat} system you would actually build — every layer, ` +
  `the exact Roblox instances, classes, services and APIs, the update/signal/per-frame flow, and the ` +
  `concrete properties and parameter values you'd dial in, the way you would in a real engineering design ` +
  `doc. Cover the full professional surface of Roblox ${cat}. ` +
  (API ? `Make sure to address this API/system surface where it genuinely applies: ${API}. ` : '') +
  `Name specific instances, properties and parameter values — do NOT hold back, summarize, or speak in ` +
  `generalities; enumerate the real mechanisms a shipped build contains. CRITICAL: describe what a ` +
  `genuinely excellent build contains; do not pad with things a real expert would NOT ship, and do not ` +
  `drift into a DIFFERENT discipline — stay strictly on ${cat}. 700-1000 words, prose + concrete mechanisms.`

function skepticPrompt(c) {
  return (
    `You are a SKEPTICAL senior Roblox engineer auditing one criterion from a "${cat}" quality rubric. ` +
    `The rubric is meant to separate an EXCELLENT build from this GENERIC FLOOR:\n"${MEAN}"\n\n` +
    `CRITERION (tier=${c.tier}):\n${c.statement}\n\n` +
    `Decide: is this a REAL above-generic quality mechanism that a top Roblox ${cat} dev genuinely ships? ` +
    `KILL it only if it is one of: (a) niche TRIVIA a great build would not actually bother with; ` +
    `(b) self-contradictory or technically impossible on Roblox; (c) satisfiable by toggling ONE property/` +
    `value (not a system); (d) something even an excellent build plausibly would NOT have. ` +
    `Otherwise KEEP it. Be honest, not contrarian. Give a concrete real shipped build that has this ` +
    `(or "none" if you killed it).`
  )
}

function gradePrompt(buildText, label) {
  return (
    `Grade this ${cat} build description against the rubric criteria. One row per criterion. Score ` +
    `pass/partial/fail STRICTLY by each criterion's stated requirement vs what the build text actually ` +
    `describes — never on vibe, never give credit for something the text does not state. If the build ` +
    `clearly satisfies the PASS gate, pass; if it gestures at the system but omits the specific required ` +
    `mechanism, partial; if absent or it matches the fail case, fail. Quote the build text in evidence.\n\n` +
    `BUILD (${label}):\n${buildText}\n\n` +
    `CRITERIA:\n${JSON.stringify(crit.map((c) => ({ id: c.id, tier: c.tier, statement: c.statement, grading: c.grading })), null, 1)}`
  )
}

// ---- Phase 1: rubric-blind expert build + adversarial skeptics, concurrently ----
phase('Independent')
log(`Verifying ${cat}: ${crit.length} criteria — rubric-blind expert build + ${crit.length} skeptics`)
const [artifact, skeptics] = await parallel([
  () => agent(EXPERT_PROMPT, { label: 'expert:rubric-blind-build', phase: 'Independent', effort: 'xhigh' }),
  () => parallel(crit.map((c) => () =>
    agent(skepticPrompt(c), { label: `skeptic:${c.id}`, phase: 'Independent', schema: SKEPTIC_SCHEMA }))),
])
const killed = (skeptics || []).filter(Boolean).filter((s) => s.verdict === 'kill')
log(`Skeptics: ${(skeptics || []).filter(Boolean).length - killed.length} keep / ${killed.length} kill`)

// ---- Phase 2: independent grading (median of 3 on the expert build; 1 on the floor) ----
phase('Grade')
const [greatGrades, meanGrade] = await parallel([
  () => parallel([0, 1, 2].map((i) => () =>
    agent(gradePrompt(artifact, 'A'), { label: `grade-build:${i}`, phase: 'Grade', schema: GRADE_SCHEMA }))),
  () => agent(gradePrompt(MEAN, 'A'), { label: 'grade-floor', phase: 'Grade', schema: GRADE_SCHEMA }),
])
const greatScores = (greatGrades || []).filter(Boolean).map((g) => aggregate(g.rows))
const great = greatScores.length ? median(greatScores) : 0
const mean = meanGrade ? aggregate(meanGrade.rows) : 0
const gap = great - mean
const pass = great >= 0.7 && mean <= 0.5 && gap >= 0.35 && killed.length === 0

// per-criterion great consensus (worst score across graders = conservative)
const order = { fail: 0, partial: 1, pass: 2 }
const byId = {}
for (const c of crit) byId[c.id] = []
for (const g of (greatGrades || []).filter(Boolean)) for (const r of g.rows || []) if (byId[r.id]) byId[r.id].push(r.score)
const greatPerCrit = crit.map((c) => {
  const scores = byId[c.id]
  const worst = scores.length ? scores.reduce((a, b) => (order[b] < order[a] ? b : a)) : 'fail'
  return { id: c.id, tier: c.tier, worstScore: worst, graderScores: scores }
})

log(`RESULT ${cat}: mean=${mean.toFixed(3)} great=${great.toFixed(3)} gap=${gap.toFixed(3)} killed=${killed.length} -> ${pass ? 'PASS' : 'FAIL'}`)

return {
  category: cat,
  pass,
  mean, great, gap,
  greatScores,
  killedCriteria: killed.map((s) => ({ id: s.id, reason: s.reason })),
  skeptics: (skeptics || []).filter(Boolean).map((s) => ({ id: s.id, verdict: s.verdict, reason: s.reason, real_example: s.real_example })),
  greatPerCrit,
  expertBuild: artifact,
}
