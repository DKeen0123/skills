export const meta = {
  name: 'build-ticket-flow',
  description: 'Ship a ticket end to end: brief + worktree + plan in parallel, Sonnet build, parallel reviewers, fix loop, one push and draft PR',
  whenToUse: 'The workflow form of build-ticket. Args: { ticket: "<id, URL or pasted text>" (required), shape: "auto" | "full" | "partial" | "light" (default auto), maxRounds: 2, repo: "<absolute repo root, default: the working directory>" }. Same agents and rules as the skill, but the orchestration is deterministic: setup and planning overlap, reviewers and the push gate run concurrently, and re-reviews are scoped to the lenses whose findings were touched.',
  phases: [
    { title: 'Brief', detail: 'fetch the ticket, name the branch' },
    { title: 'Prepare', detail: 'worktree + DB fork and an implementation plan, concurrently' },
    { title: 'Build', detail: 'Sonnet builder(s) in the worktree' },
    { title: 'Review', detail: 'parallel reviewers + push-gate dry run' },
    { title: 'Fix', detail: 'one fixer per round, scoped re-review' },
    { title: 'Ship', detail: 'push, draft PR, ticket comment' },
  ],
}

// ---------- args ----------
const ticket = args && args.ticket
if (!ticket) throw new Error('args.ticket is required: an issue id, URL, or the pasted ticket text')
const REPO = (args && args.repo) || '$(git rev-parse --show-toplevel)'
const REPO_DESC = args && args.repo ? args.repo : 'the repository root (your working directory; `git rev-parse --show-toplevel`)'
const SHAPE_ARG = (args && args.shape) || 'auto'
const MAX_ROUNDS = (args && args.maxRounds) || 2

// ---------- shared prompt blocks ----------
const standing = (wt, branch) => `
STANDING RULES
Setup: run any environment setup CLAUDE.md requires (a node version manager PATH export, an env file) before tool commands.
Worktree: ${wt}. Branch: ${branch}. Base: the default branch. Work only inside this worktree. Read CLAUDE.md there first and any docs it points to for the files you touch.
Machine safety: respect any concurrency limits or safe test-run practices CLAUDE.md documents. Default when silent: never run the full test suite unless your task says so, only the files you touched; if the runner supports a worker cap, cap it at 2; before a test run, wait for any other test run on the machine to finish (typecheck and lint need no wait).
Checks: use the typecheck, lint and test commands CLAUDE.md gives, nothing slower. Typecheck once, at the end. Do not re-run a typecheck, lint or suite that a previous agent's report shows green unless your own edits touched what it covers; the pre-push hook runs the full gate at push time.
Git: commit only. NEVER push. NEVER --no-verify. NEVER touch the default branch.
Your final message is machine-read: return the structured output only, no prose for a human.`

const briefText = (b) => `
TICKET ${b.ticketId} — ${b.title}
URL: ${b.url}
Problem: ${b.problem}
Acceptance criteria:
${b.acceptanceCriteria.map((c, i) => `  ${i + 1}. ${c}`).join('\n')}
Docs to read first: ${b.contextDocs.length ? b.contextDocs.join(', ') : 'none named; follow CLAUDE.md'}
Out of scope: ${b.outOfScope.length ? b.outOfScope.join('; ') : 'nothing noted'}`

const FINDING = {
  type: 'object',
  required: ['severity', 'file', 'summary', 'fix', 'preExisting'],
  properties: {
    severity: { enum: ['MAJOR', 'MINOR', 'NIT'] },
    preExisting: { type: 'boolean', description: 'true when the defect is not introduced by this diff (goes to the PR body, not a fixer)' },
    file: { type: 'string', description: 'repo-relative path' },
    line: { type: 'number' },
    summary: { type: 'string', description: 'one sentence: what is wrong' },
    fix: { type: 'string', description: 'one line: the concrete fix' },
  },
}

const REVIEW_SCHEMA = {
  type: 'object',
  required: ['lens', 'findings', 'verifiedOk'],
  properties: {
    lens: { type: 'string' },
    findings: { type: 'array', items: FINDING },
    verifiedOk: { type: 'array', items: { type: 'string' } },
    screenshots: { type: 'array', items: { type: 'string' }, description: 'absolute PNG paths captured (ui lens only)' },
    devServerPort: { type: 'number' },
    runs: { type: 'array', items: { type: 'string' }, description: 'check commands run and pass/fail' },
  },
}

// ---------- Phase 1: brief ----------
phase('Brief')
const brief = await agent(`Resolve this ticket input: ${JSON.stringify(ticket)}

Source, in order: a Linear-shaped id or URL with Linear MCP tools available → mcp__linear-server__get_issue then list_comments, and extract_images for embedded images, then save_issue with assignee me and state In Progress; a GitHub issue number or URL → \`gh issue view <n> --json title,body,comments\` then \`gh issue edit <n> --add-assignee @me\`; otherwise treat the input as pasted text or a spec (ticketSource = "text", no state change).

Read CLAUDE.md in ${REPO_DESC}. Write a brief an implementer can act on without the ticket: the problem in your words, acceptance criteria as a numbered list (infer sensible ones if the ticket has none, and say so in notes), the docs CLAUDE.md names as relevant to the areas involved, out-of-scope notes. Pick a branch name \`<ticket-id>/<slug>\` when there is an id, else \`feat/<slug>\` (slug under six words, lowercase, dashes). Worktree path: what CLAUDE.md or the repo's worktree tooling says (\`just --list 2>/dev/null | grep worktree-new\`), else \`<parent-of-repo>/<repo-name>-<branch with slashes as dashes>\`; return it absolute. Also return localLoginHint: how CLAUDE.md says to log in locally as a test user (a URL pattern with a <port> placeholder), or empty.

Also guess: does the ticket touch rendered UI (a .tsx route/component, CSS)? Does it touch services, migrations or tests? Is it small (a copy change, a one-file fix) or not? These pick the review shape.

If the ticket contradicts itself or lacks something no implementer could infer, say so in blockingQuestions and still produce your best brief.`, {
  label: 'brief',
  phase: 'Brief',
  model: 'sonnet',
  effort: 'medium',
  schema: {
    type: 'object',
    required: ['ticketId', 'ticketSource', 'url', 'title', 'problem', 'acceptanceCriteria', 'contextDocs', 'outOfScope', 'branch', 'worktree', 'localLoginHint', 'touchesUi', 'touchesServicesOrTests', 'isSmall', 'blockingQuestions', 'notes'],
    properties: {
      ticketId: { type: 'string', description: 'issue id, or a short slug for pasted text' },
      ticketSource: { enum: ['linear', 'github', 'text'] },
      url: { type: 'string', description: 'empty for pasted text' },
      title: { type: 'string' },
      problem: { type: 'string' },
      acceptanceCriteria: { type: 'array', items: { type: 'string' } },
      contextDocs: { type: 'array', items: { type: 'string' } },
      outOfScope: { type: 'array', items: { type: 'string' } },
      branch: { type: 'string' },
      worktree: { type: 'string', description: 'absolute path' },
      localLoginHint: { type: 'string' },
      touchesUi: { type: 'boolean' },
      touchesServicesOrTests: { type: 'boolean' },
      isSmall: { type: 'boolean' },
      blockingQuestions: { type: 'array', items: { type: 'string' } },
      notes: { type: 'string' },
    },
  },
})
if (!brief) throw new Error('brief agent returned nothing')
if (brief.blockingQuestions.length) {
  log(`Ticket has open questions; proceeding on the brief's assumptions: ${brief.blockingQuestions.join(' | ')}`)
}
const WT = brief.worktree
const BRANCH = brief.branch
const RULES = standing(WT, BRANCH)
const BRIEF = briefText(brief)
log(`Branch ${BRANCH}`)

// ---------- Phase 2: prepare (worktree || plan) ----------
phase('Prepare')
const [worktreeResult, plan] = await parallel([
  () => agent(`Create the worktree for branch ${BRANCH} at ${WT} from ${REPO_DESC}, using the repo's own tooling if it has any (\`just worktree-new ${BRANCH}\` when \`just --list\` offers it, after any setup CLAUDE.md requires), else \`git worktree add ${WT} -b ${BRANCH}\` followed by the dependency install CLAUDE.md gives. If setup warns about a database or migration problem, apply the fix CLAUDE.md documents. Confirm the worktree exists, \`git -C ${WT} status\` is clean, and dependencies are installed. Do not edit any file.${brief.touchesUi ? ' Then start the dev server the way CLAUDE.md says to start it in an agent/background context, wait until it answers, and report the port.' : ' Do not start a dev server.'}`, {
    label: 'worktree',
    phase: 'Prepare',
    model: 'sonnet',
    effort: 'low',
    schema: {
      type: 'object',
      required: ['ok', 'worktree', 'devServerPort', 'notes'],
      properties: { ok: { type: 'boolean' }, worktree: { type: 'string' }, devServerPort: { type: 'number', description: '0 if none' }, notes: { type: 'string' } },
    },
  }),
  () => agent(`${BRIEF}

You are a read-only planner working in ${REPO_DESC} (the branch does not exist yet, so read code here). Read the docs named above plus any CLAUDE.md maps to the areas involved. Find the exact files, routes, services, components and tests the change touches. Produce an implementation plan a Sonnet builder can follow without further exploration: ordered steps, each naming the file and what changes, the tests to write (real path: integration against Postgres or Playwright through the route, per the Definition of Done), and the doc CLAUDE.md requires you to update if the domain changes.

If the work splits cleanly into slices with DISJOINT file sets that can be built in parallel, list them as slices with their file lists. Otherwise return one slice. Do not edit anything.`, {
    label: 'plan',
    phase: 'Prepare',
    effort: 'high',
    schema: {
      type: 'object',
      required: ['steps', 'testsToWrite', 'docsToUpdate', 'slices', 'routesAffected'],
      properties: {
        steps: { type: 'array', items: { type: 'string' } },
        testsToWrite: { type: 'array', items: { type: 'string' } },
        docsToUpdate: { type: 'array', items: { type: 'string' } },
        routesAffected: { type: 'array', items: { type: 'string' } },
        slices: {
          type: 'array',
          items: {
            type: 'object',
            required: ['name', 'files', 'instructions'],
            properties: { name: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, instructions: { type: 'string' } },
          },
        },
      },
    },
  }),
])
if (!worktreeResult || !worktreeResult.ok) throw new Error(`worktree setup failed: ${worktreeResult && worktreeResult.notes}`)
if (!plan) throw new Error('planner returned nothing')

const PLAN = `
IMPLEMENTATION PLAN (from a read-only planner; verify as you go, deviate if the code disagrees)
Steps:
${plan.steps.map((s, i) => `  ${i + 1}. ${s}`).join('\n')}
Tests to write: ${plan.testsToWrite.join(' | ')}
Docs to update: ${plan.docsToUpdate.join(', ') || 'none'}
Routes affected: ${plan.routesAffected.join(', ') || 'none'}`

// ---------- Phase 3: build ----------
phase('Build')
const BUILD_RULES = `
Implement the ticket. Invoke the \`testing\` skill (Skill tool, name "testing", or "ship:testing" when installed as the plugin) before writing tests. Cover each acceptance criterion on the real path: an integration test against a real database or an E2E test through the route; a fully-mocked unit test alone does not count.
Build UI from the project's shared component library and follow its form and notification patterns, as CLAUDE.md documents.
Update any doc CLAUDE.md requires for the domain you changed, in the same commit.`

const BUILD_SCHEMA = {
  type: 'object',
  required: ['filesChanged', 'tests', 'checks', 'routesAffected', 'devServerPort', 'couldNotDo', 'commit'],
  properties: {
    filesChanged: { type: 'array', items: { type: 'string' }, description: 'path — one-line description' },
    tests: { type: 'array', items: { type: 'string' }, description: 'test file — how it was run and the result' },
    checks: { type: 'array', items: { type: 'string' }, description: 'exact typecheck/lint/test commands run and their result, so reviewers can trust them' },
    routesAffected: { type: 'array', items: { type: 'string' } },
    devServerPort: { type: 'number', description: '0 if none started' },
    couldNotDo: { type: 'array', items: { type: 'string' } },
    commit: { type: 'string', description: 'commit sha, or empty if not committed' },
  },
}

let build
const slices = plan.slices && plan.slices.length > 1 ? plan.slices : null
if (slices) {
  log(`${slices.length} disjoint slices; parallel builders, then one integrator`)
  const parts = (await parallel(slices.map((s) => () =>
    agent(`${RULES}
${BRIEF}
${PLAN}

You own slice "${s.name}" and may edit ONLY these files (create them if new): ${s.files.join(', ')}. Other builders own the rest concurrently in the same worktree.
${s.instructions}
${BUILD_RULES}
Run the tests you wrote (the integrator typechecks). DO NOT COMMIT; an integrator commits after all slices land. Do not start a dev server.`, { label: `build:${s.name}`, phase: 'Build', model: 'sonnet', schema: BUILD_SCHEMA })
  ))).filter(Boolean)
  build = await agent(`${RULES}
${BRIEF}

Parallel builders left uncommitted work in the worktree. Their reports:
${JSON.stringify(parts, null, 1)}

Typecheck once, lint the changed files, resolve any seams between slices, run every test they wrote, then make ONE commit: \`feat|fix: <desc>${brief.ticketSource === 'text' ? '' : ` (${brief.ticketId})`}\` with whatever commit trailer the project or harness specifies.${worktreeResult.devServerPort ? ` A dev server is already running on port ${worktreeResult.devServerPort}; do not start another.` : ' Do not start a dev server.'}`, { label: 'integrate', phase: 'Build', model: 'sonnet', schema: BUILD_SCHEMA })
} else {
  build = await agent(`${RULES}
${BRIEF}
${PLAN}
${BUILD_RULES}
Run typecheck once, lint on changed files, and the tests you wrote, with the commands CLAUDE.md gives. Commit as \`feat|fix: <desc>${brief.ticketSource === 'text' ? '' : ` (${brief.ticketId})`}\` with whatever commit trailer the project or harness specifies. Do not push.
${worktreeResult.devServerPort ? `A dev server is already running on port ${worktreeResult.devServerPort}; do not start another. If you changed a rendered surface, load it once with rodney (\`--local\`) to confirm it renders; do not loop on screenshots, the UI reviewer does the full pass.` : 'Do not start a dev server.'}`, { label: 'build', phase: 'Build', model: 'sonnet', schema: BUILD_SCHEMA })
}
if (!build || !build.commit) throw new Error(`build did not commit: ${build && build.couldNotDo.join('; ')}`)
if (!build.devServerPort && worktreeResult.devServerPort) build.devServerPort = worktreeResult.devServerPort
if (build.couldNotDo.length) log(`Builder could not: ${build.couldNotDo.join(' | ')}`)

// ---------- Phase 4: review shape ----------
const uiInDiff = brief.touchesUi || build.filesChanged.some((f) => /\.(tsx|jsx|vue|svelte|css|scss)\b|\/(routes|pages|components)\//.test(f))
const testsInDiff = brief.touchesServicesOrTests || build.filesChanged.some((f) => /\.test\.|\.spec\.|_test\.|\/migrations?\/|\/services?\//.test(f))
let shape = SHAPE_ARG
if (shape === 'auto') shape = brief.isSmall && !uiInDiff ? 'light' : (uiInDiff && testsInDiff) ? 'full' : 'partial'
const lenses = shape === 'light'
  ? ['code']
  : ['code'].concat(uiInDiff ? ['ui'] : []).concat(testsInDiff ? ['tests'] : [])
if (shape === 'full' && !lenses.includes('ui')) lenses.push('ui')
if (shape === 'full' && !lenses.includes('tests')) lenses.push('tests')
log(`Review shape: ${shape} (${lenses.join(', ')})`)

const REVIEW_BRIEF = () => `
REVIEW BRIEF
${BRIEF}
Files changed:
${build.filesChanged.map((f) => `  - ${f}`).join('\n')}
Tests: ${build.tests.join(' | ') || 'none reported'}
Checks already green (trust these; do not re-run unless a finding depends on it): ${build.checks.join(' | ') || 'none reported'}
Routes affected: ${(build.routesAffected.length ? build.routesAffected : plan.routesAffected).join(', ') || 'none'}
Dev server port: ${build.devServerPort || 'none running'}
You are READ-ONLY: no edits, no commits. Severity-rate every finding MAJOR / MINOR / NIT with file:line and a one-line fix. Mark preExisting=true when the defect is not introduced by this diff (including a test layer the repo does not have). A MAJOR claiming a test cannot fail must be demonstrated: mutate the code under test, run it, quote the output; from types alone it is MINOR at most. Do not soften findings; do not pad with NITs.`

const lensPrompt = (lens, scope) => {
  const scoped = scope ? `\nSCOPE: a fixer just addressed these findings in commits after ${scope.sha}. Review \`git diff ${scope.sha}..HEAD\` only, not the whole branch. Confirm each is resolved and that the fixes introduced nothing new. For the ui lens, re-shoot only the surfaces the fix touched. Report only what is still wrong or newly wrong:\n${scope.text}` : ''
  const common = `${RULES}\n${REVIEW_BRIEF()}${scoped}\nReport lens="${lens}".`
  if (lens === 'code') return { model: 'opus', prompt: `${common}\nInvoke the \`review\` skill (Skill tool, name "review", or "ship:review" when installed as the plugin) on this branch and follow it. Run no suites and no lint (the builder's checks and the push hook cover them); run a single test file only when a finding depends on it. Also apply the \`unslop\` writing checklist (Skill tool, name "unslop" / "ship:unslop", audit mode only) to user-facing copy, error messages, empty states and any docs in the diff, and report slop as findings so one fixer handles both.` }
  if (lens === 'ui') return { model: 'sonnet', prompt: `${common}\nInvoke the \`ui-review\` skill (Skill tool, name "ui-review" / "ship:ui-review") and follow it, both passes. You are the only agent allowed to start rodney (\`--local\`) or the dev server if none is running. Include the \`unslop\` visual blacklist in pass 2 and report slop as findings. Desktop viewport only unless the ticket asks for mobile or the surface is customer-facing. Return every screenshot path.` }
  return { model: 'sonnet', prompt: `${common}\nInvoke the \`testing-review\` skill (Skill tool, name "testing-review" / "ship:testing-review") and follow it, including running the touched suites (capped per the standing rules). You are the only reviewer that runs suites; skip any the builder's checks show green unless the diff changed them since.` }
}

const runReviews = (activeLenses, scope, round) => parallel(activeLenses.map((lens) => () => {
  const p = lensPrompt(lens, scope)
  return agent(p.prompt, { label: `review:${lens}${round > 1 ? `-${round}` : ''}`, phase: round > 1 ? 'Fix' : 'Review', model: p.model, schema: REVIEW_SCHEMA })
}))

const GATE_PROMPT = () => `${RULES}
Dry-run the cheap half of the push gate on the committed HEAD so failures surface now instead of at push time. Find the repo's pre-push hook if it has one (\`git config core.hooksPath\`, else .git/hooks/pre-push) and read it; otherwise use the check commands CLAUDE.md gives. Run, in the worktree: the repo-wide typecheck and the full lint. Do NOT run the main unit suite (the tests reviewer and the hook cover it, and it would block the other reviewers on the machine's test-run mutex); run only a small suite of a package the diff touches that nothing else exercises. Do NOT push, do NOT edit, do NOT commit. Report each check as a finding only if it FAILS (severity MAJOR, file = the failing file, fix = what the log says), and list every check you ran in runs.`

// ---------- Phase 4: review round 1 (+ gate dry run) ----------
phase('Review')
const round1 = await parallel([
  ...lenses.map((lens) => () => {
    const p = lensPrompt(lens, null)
    return agent(p.prompt, { label: `review:${lens}`, phase: 'Review', model: p.model, schema: REVIEW_SCHEMA })
  }),
  () => agent(GATE_PROMPT(), { label: 'gate-dry-run', phase: 'Review', model: 'sonnet', effort: 'low', schema: REVIEW_SCHEMA }),
])
const rank = { MAJOR: 0, MINOR: 1, NIT: 2 }
const key = (f) => `${f.file}:${f.line || 0}:${f.summary.slice(0, 60).toLowerCase()}`
const collect = (reports) => {
  const seen = new Set()
  return reports.filter(Boolean).flatMap((r) => r.findings.map((f) => ({ ...f, lens: r.lens }))).filter((f) => {
    const k = key(f); if (seen.has(k)) return false; seen.add(k); return true
  }).sort((a, b) => rank[a.severity] - rank[b.severity])
}
let screenshots = round1.filter(Boolean).flatMap((r) => r.screenshots || [])
let devServerPort = round1.filter(Boolean).map((r) => r.devServerPort).find(Boolean) || build.devServerPort
const roundsLog = []
const triagedOut = []
const triage = (list) => list.filter((f) => { if (f.preExisting) { triagedOut.push(f); return false } return true })
let open = triage(collect(round1))
let baseSha = build.commit
log(`Round 1: ${open.length} findings (${open.filter((f) => f.severity === 'MAJOR').length} MAJOR), ${triagedOut.length} pre-existing triaged to the PR body`)

// ---------- Phase 5: fix loop ----------
phase('Fix')
const residual = []
const disputed = []
let round = 1
while (open.some((f) => f.severity !== 'NIT') && round <= MAX_ROUNDS) {
  const actionable = open.filter((f) => f.severity !== 'NIT')
  const cheapNits = open.filter((f) => f.severity === 'NIT').slice(0, 5)
  const list = actionable.concat(cheapNits)
  const listText = list.map((f, i) => `${i + 1}. [${f.severity}] [${f.lens}] ${f.file}${f.line ? ':' + f.line : ''} — ${f.summary}\n   fix: ${f.fix}`).join('\n')
  const fix = await agent(`${RULES}
${BRIEF}
Fix each finding below in the worktree. Fix the MAJOR and MINOR ones; NITs only if cheap. Update any doc CLAUDE.md requires for what you change. Screenshot with rodney only for a finding that was visual, once; never poll for a surface to render. Run typecheck once, oxlint on changed files, and the touched tests (capped). Commit as \`fix: review round ${round}${brief.ticketSource === 'text' ? '' : ` (${brief.ticketId})`}\` with whatever commit trailer the project or harness specifies. If you disagree with a finding, leave it and say why in one sentence.

FINDINGS
${listText}`, {
    label: `fix-${round}`,
    phase: 'Fix',
    model: 'sonnet',
    schema: {
      type: 'object',
      required: ['fixed', 'disagreed', 'commit', 'devServerPort'],
      description: 'commit = sha of the fix commit',
      properties: {
        fixed: { type: 'array', items: { type: 'number' }, description: 'finding numbers fixed' },
        disagreed: { type: 'array', items: { type: 'object', required: ['n', 'why'], properties: { n: { type: 'number' }, why: { type: 'string' } } } },
        commit: { type: 'string' },
        devServerPort: { type: 'number' },
      },
    },
  })
  if (!fix) { log(`fixer ${round} died; stopping the loop`); break }
  const fixedSet = new Set(fix.fixed)
  const fixedFindings = list.filter((_, i) => fixedSet.has(i + 1))
  fix.disagreed.forEach((d) => { const f = list[d.n - 1]; if (f) disputed.push({ ...f, why: d.why, round }) })
  const touchedLenses = [...new Set(fixedFindings.map((f) => f.lens))].filter((l) => lenses.includes(l))
  const hadMajor = actionable.some((f) => f.severity === 'MAJOR')
  roundsLog.push({ round, findings: list.length, majors: actionable.filter((f) => f.severity === 'MAJOR').length, fixed: fixedFindings.length, disagreed: fix.disagreed.length, reReviewed: hadMajor && touchedLenses.length > 0 })
  if (!hadMajor) { log(`Round ${round} had no MAJOR; batched fixes without a re-review`); open = []; break }
  if (!touchedLenses.length) break
  const scope = { sha: baseSha, text: fixedFindings.map((f) => `- [${f.lens}] ${f.file}${f.line ? ':' + f.line : ''} — ${f.summary}`).join('\n') }
  const reReports = await runReviews(touchedLenses, scope, round + 1)
  screenshots = screenshots.concat(reReports.filter(Boolean).flatMap((r) => r.screenshots || []))
  open = triage(collect(reReports))
  baseSha = fix.commit || baseSha
  round++
  log(`Round ${round}: ${open.length} findings remain (${open.filter((f) => f.severity === 'MAJOR').length} MAJOR)`)
}
residual.push(...open.filter((f) => f.severity !== 'NIT'))
if (residual.length) log(`Residual after ${round - 1} fix round(s): ${residual.length}`)

// ---------- Phase 6: ship ----------
phase('Ship')
const pushPrompt = (attempt) => `${RULES}
${BRIEF}
Push the branch and open a DRAFT PR.
1. If the repo has a pre-push hook, wait until no other copy of it is running, two-minute cap, anchored pattern only: \`for i in $(seq 1 24); do pgrep -fl "^bash <path-to-hook>" || break; sleep 5; done\` (never a \`ps | grep -E\` alternation; it matches its own shell). If it never cleared, print what matched and push anyway.
2. Push in the foreground from ${WT} with a 10-minute timeout, logging to a scratch file. Verify with \`git ls-remote origin ${BRANCH}\`. If the hook fails: do NOT --no-verify; return ok=false with the last 40 lines of the log in hookFailure and stop.
3. Open the PR by invoking the \`pr\` skill (Skill tool, name "pr", or "ship:pr" when installed as the plugin) and following it: base = the default branch unless CLAUDE.md says otherwise, draft. Give it the ticket URL ${brief.url || '(none, pasted ticket)'}, the acceptance criteria for the How to test checklist, these already-captured screenshots so it does not re-shoot: ${screenshots.join(', ') || 'none'}, and a Review section listing: shape ${shape}, rounds ${JSON.stringify(roundsLog)}, residual findings ${residual.map((f) => `${f.file} — ${f.summary}`).join('; ') || 'none'}, pre-existing findings triaged out ${triagedOut.map((f) => `${f.file} — ${f.summary}`).join('; ') || 'none'}, disputed ${disputed.map((f) => `${f.file} — ${f.summary} (${f.why})`).join('; ') || 'none'}.
4. Post the PR URL back to the ticket: ${brief.ticketSource === 'linear' ? `a Linear comment on ${brief.ticketId} with mcp__linear-server__save_comment` : brief.ticketSource === 'github' ? `\`gh issue comment ${brief.ticketId.replace(/^#/, '')}\`` : 'nothing to post, the ticket was pasted text'}. Do not change the ticket state.
Do not re-shoot screenshots, do not start rodney or a dev server. Return the PR URL.${attempt > 1 ? '\nThis is push attempt ' + attempt + ' after a hook fix.' : ''}`

const PUSH_SCHEMA = {
  type: 'object',
  required: ['ok', 'prUrl', 'hookFailure'],
  properties: { ok: { type: 'boolean' }, prUrl: { type: 'string' }, hookFailure: { type: 'string' } },
}
let push = await agent(pushPrompt(1), { label: 'push', phase: 'Ship', model: 'sonnet', schema: PUSH_SCHEMA })
if (push && !push.ok && push.hookFailure) {
  log('Pre-push hook failed; one fixer then one more push')
  await agent(`${RULES}
The push hook failed with this output. Consult any failure → fix table CLAUDE.md names, fix the cause in the worktree, re-run the failing check locally, commit as \`fix: push gate${brief.ticketSource === 'text' ? '' : ` (${brief.ticketId})`}\` with whatever commit trailer the project or harness specifies. Do not push.

${push.hookFailure}`, { label: 'fix-gate', phase: 'Ship', model: 'sonnet', schema: { type: 'object', required: ['commit', 'notes'], properties: { commit: { type: 'string' }, notes: { type: 'string' } } } })
  push = await agent(pushPrompt(2), { label: 'push-2', phase: 'Ship', model: 'sonnet', schema: PUSH_SCHEMA })
}

const mainRoute = (build.routesAffected[0] || plan.routesAffected[0] || '/')
return {
  ticket: brief.ticketId,
  branch: BRANCH,
  worktree: WT,
  prUrl: push && push.prUrl,
  pushOk: !!(push && push.ok),
  hookFailure: push && !push.ok ? push.hookFailure : '',
  built: build.filesChanged,
  reviewShape: shape,
  lenses,
  rounds: roundsLog,
  residual,
  triagedOut,
  disputed,
  screenshots,
  devServerLogin: devServerPort && brief.localLoginHint ? `${brief.localLoginHint.replace('<port>', String(devServerPort))} (main route: ${mainRoute})` : '',
}
