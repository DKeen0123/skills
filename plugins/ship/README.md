# ship

Skills for taking a change from working code to a reviewed, screenshotted pull
request.

## Skills in this plugin

Skills in this collection are referred to by bare name. When installed as the
Claude Code plugin they are namespaced `ship:<name>`; use that form when
invoking one from Claude Code.

- **`build-ticket`** — picks up a ticket and ships it end to end: a prep
  agent creates the worktree while the brief is written, a builder
  implements it (every agent is spawned by role from `agents/`, which
  fixes its model, effort and turn cap, and hands off to a fresh agent
  instead of running one context long), `review`, `ui-review` and `testing-review` run in
  parallel (each carrying the `unslop` checklist for its axis), findings
  route back to fixers (re-review only after a round with a MAJOR, two
  rounds max), then one pusher pushes and opens a draft PR via `pr`.
  `/build-ticket <ticket> ultracode` runs the same process as the bundled
  Workflow script `ship:build-ticket-flow` (`workflows/build-ticket-flow.js`):
  setup overlaps planning, the review lenses run alongside a typecheck/lint
  dry run of the push gate, and re-reviews are scoped to the fix commit.
  Through the `skills` CLI the script is not delivered; copy it into your
  project's `.claude/workflows/` to get workflow mode.
- **`pr`** — commits any loose changes, writes a PR body (TLDR / Why /
  Screenshots / How to test) via `unslop`, captures UI screenshots via
  `rodney-tips` when relevant, and opens the PR with `gh`.
- **`review`** — reviews the current branch's diff against its base for
  correctness, edge cases, type safety, test coverage on the real path, and
  consistency with the repo's documented conventions. Outputs severity-rated
  findings (MAJOR/MINOR/NIT).
- **`ui-review`** — two-pass UI review: a design-system audit of
  changed files, then a visual verification of every changed surface in a
  real browser via `rodney-tips`.
- **`testing-review`** — reviews the tests on the current branch for
  quality and coverage against `testing`'s rules, and runs the suites
  the change touches.
- **`testing`** — principles and concrete rules for writing tests in
  this repo: unit, integration, and E2E.
- **`unslop`** — detects and removes AI-slop patterns, both visual
  (generic gradient/3-column/icon-in-circle templates) and written (AI
  vocabulary, filler, hedging). Used by `pr` on PR descriptions and
  worth running on any UI or doc before shipping it.
- **`rodney-tips`** — reference for driving `rodney` (headless Chrome
  CLI) and `showboat` (screenshot/notebook tool): starting isolated
  sessions, finding and clicking elements, waiting for hydration, and
  attaching screenshots to a PR with `gh pr create --attach`.

## What your CLAUDE.md should state

These skills read the host repo's `CLAUDE.md` (or equivalent project doc)
for facts they don't hardcode. Document these and the skills work with no
extra prompting; leave one out and the skill will ask you once instead of
guessing:

- **PR base branch** — which branch PRs target, and any exception (e.g. a
  release branch that behaves differently). If undocumented, `pr` and
  `review` fall back to the repo's default branch via `gh repo view`.
- **Dev server start command** — how to start it in the background/agent
  context (not an interactive TUI), and how its port is reported.
- **Local login** — how to authenticate as a test user without going through
  real auth (a dev-only bypass route, a seeded account, etc.).
- **Test/check command** — how to run typecheck, lint, and unit tests, and
  whether that already happens automatically (e.g. a pre-push hook) so the
  skills don't duplicate it.
- **Issue tracker** — which tracker the project uses (Linear, GitHub Issues,
  Jira, etc.) and its ticket URL pattern, so `pr` can link the ticket
  in the PR body.
- **Component library** — the UI library or design system components to use
  instead of raw HTML elements, for `ui-review`'s design-system audit
  and `unslop`'s visual-fix pass.

## Required tools

- [`gh`](https://cli.github.com/) ≥ 2.99.0 — needed for `gh pr create --attach`
  to upload screenshots directly to GitHub. Older versions can create the PR
  but not attach images; the skills will tell you to upgrade rather than
  fall back to a third-party image host.
- [`rodney`](https://github.com/simonw/rodney) — headless/headed Chrome CLI,
  used for visually verifying UI changes and taking screenshots. Required
  for `ui-review`, and for any PR with UI changes.
- [`showboat`](https://github.com/simonw/showboat) — pairs with rodney to
  assemble a sequence of screenshots and notes into one file. Optional:
  `pr` captures its screenshots with rodney alone and never calls
  showboat.
