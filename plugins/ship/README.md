# ship

Skills for taking a change from working code to a reviewed, screenshotted pull
request.

## Skills in this plugin

Cross-references below use `ship:<name>` — plugin skills are namespaced by
plugin name when invoked through the Skill tool, so `ship:review` (not
`/review`) is what actually resolves.

- **`ship:build-ticket`** — picks up a ticket and ships it end to end:
  builds it in a worktree, runs `ship:review`, `ship:ui-review`, and
  `ship:testing-review` in parallel, routes findings back to fixers, runs
  `ship:unslop`, then pushes and opens a draft PR via `ship:pr`.
- **`ship:pr`** — commits any loose changes, writes a PR body (TLDR / Why /
  Screenshots / How to test) via `ship:unslop`, captures UI screenshots via
  `ship:rodney-tips` when relevant, and opens the PR with `gh`.
- **`ship:review`** — reviews the current branch's diff against its base for
  correctness, edge cases, type safety, test coverage on the real path, and
  consistency with the repo's documented conventions. Outputs severity-rated
  findings (MAJOR/MINOR/NIT).
- **`ship:ui-review`** — two-pass UI review: a design-system audit of
  changed files, then a visual verification of every changed surface in a
  real browser via `ship:rodney-tips`.
- **`ship:testing-review`** — reviews the tests on the current branch for
  quality and coverage against `ship:testing`'s rules, and runs the suites
  the change touches.
- **`ship:testing`** — principles and concrete rules for writing tests in
  this repo: unit, integration, and E2E.
- **`ship:unslop`** — detects and removes AI-slop patterns, both visual
  (generic gradient/3-column/icon-in-circle templates) and written (AI
  vocabulary, filler, hedging). Used by `ship:pr` on PR descriptions and
  worth running on any UI or doc before shipping it.
- **`ship:rodney-tips`** — reference for driving `rodney` (headless Chrome
  CLI) and `showboat` (screenshot/notebook tool): starting isolated
  sessions, finding and clicking elements, waiting for hydration, and
  attaching screenshots to a PR with `gh pr create --attach`.

## What your CLAUDE.md should state

These skills read the host repo's `CLAUDE.md` (or equivalent project doc)
for facts they don't hardcode. Document these and the skills work with no
extra prompting; leave one out and the skill will ask you once instead of
guessing:

- **PR base branch** — which branch PRs target, and any exception (e.g. a
  release branch that behaves differently). If undocumented, `ship:pr` and
  `ship:review` fall back to the repo's default branch via `gh repo view`.
- **Dev server start command** — how to start it in the background/agent
  context (not an interactive TUI), and how its port is reported.
- **Local login** — how to authenticate as a test user without going through
  real auth (a dev-only bypass route, a seeded account, etc.).
- **Test/check command** — how to run typecheck, lint, and unit tests, and
  whether that already happens automatically (e.g. a pre-push hook) so the
  skills don't duplicate it.
- **Issue tracker** — which tracker the project uses (Linear, GitHub Issues,
  Jira, etc.) and its ticket URL pattern, so `ship:pr` can link the ticket
  in the PR body.
- **Component library** — the UI library or design system components to use
  instead of raw HTML elements, for `ship:ui-review`'s design-system audit
  and `ship:unslop`'s visual-fix pass.

## Required tools

- [`gh`](https://cli.github.com/) ≥ 2.99.0 — needed for `gh pr create --attach`
  to upload screenshots directly to GitHub. Older versions can create the PR
  but not attach images; the skills will tell you to upgrade rather than
  fall back to a third-party image host.
- [`rodney`](https://github.com/simonw/rodney) — headless/headed Chrome CLI,
  used for visually verifying UI changes and taking screenshots. Required
  for `ship:ui-review`, and for any PR with UI changes.
- [`showboat`](https://github.com/simonw/showboat) — pairs with rodney to
  assemble a sequence of screenshots and notes into one file. Optional:
  `ship:pr` captures its screenshots with rodney alone and never calls
  showboat.
