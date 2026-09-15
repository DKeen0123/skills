---
name: testing-review
description: Review the tests on the current branch for quality and coverage - do the tests prove the changed behaviour on the real path (real database, rendered DOM, actual route), do they follow the repo's ship:testing rules, and is anything the change touched left untested. Runs the relevant suites. Read-only, reports findings; never edits or commits. Use when asked for a "testing review", "test coverage review", "check the tests", or as the testing reviewer inside ship:build-ticket.
---

# Testing Review

You are a reviewer: **never edit files, never commit, never push.** You may run
tests.

Inputs (ask if missing, otherwise derive): worktree path, branch, base (the
default branch — `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`
if unstated), a one-paragraph summary of the change, the ticket's acceptance
criteria.

Read first: the `ship:testing` skill (invoke it), and any repo-specific testing
docs CLAUDE.md names for files the diff touches (integration-test
conventions, E2E conventions, and so on).

## 1. Map behaviour to tests

```bash
git diff --stat <base>...HEAD
git diff <base>...HEAD -- '*.test.*' '*.integration.test.*' '*.spec.*'
```

Write down, before reading the tests, the list of behaviours the change
introduces or alters: each acceptance criterion from the ticket, each new
branch in a loader/action/service, each new UI state, each permission or
tenant boundary crossed. This list is the coverage yardstick. Then for each
behaviour record which test proves it, at which layer (unit / integration /
E2E), or **none**.

Check CLAUDE.md's definition of done or testing philosophy for whether the
change must be exercised on the real path (a real database, rendered DOM, an
actual route) rather than mocks. Default when CLAUDE.md is silent: require
the real path. When it applies, a behaviour proven only by a fully-mocked
unit test counts as **none** for that purpose. Flag it as MAJOR when the
behaviour writes or reads the database, enforces auth or tenant scope, or is
an acceptance criterion; MINOR otherwise.

## 2. Quality of the tests that exist

Read every new or changed test file whole. Findings, with severity:

**MAJOR**
- Asserts on a mock being called instead of on an effect (a database row, the
  rendered DOM, the redirect, the response body).
- Test would pass without the production change. You are read-only, so do not
  stash or revert to check; reason from the assertion. A test that cannot fail
  is not a test.
- Assertion coupled to implementation detail: CSS classes, `#id`, internal
  state, `data-value`, render-tree shape, placeholder where a label exists.
- `waitForTimeout`, `waitForLoadState('networkidle')`, `waitForLoadState('load')`
  after client-side navigation, `.first()` hiding a multi-match.
- Integration test that leaks rows: no teardown of what it created (via the
  repo's factories/cleanup helpers if it has them, or manual deletes), or
  hard-coded ids that collide across parallel runs.
- Test depends on host timezone, wall-clock, or ordering of an unordered query.
- E2E spec added as a new sibling directory instead of the project/suite that
  already covers the feature, if the repo splits E2E into named projects.

**MINOR**
- Description does not read as "user does X → observes Y".
- Happy path only where the change added an error/empty/forbidden branch.
- Duplicate coverage of the same behaviour at three layers while a neighbouring
  behaviour has none.
- Fixture built by hand where the repo's shared test factories, if any,
  already build it.
- Snapshot assertion on a large object where two specific fields carry the meaning.

**NIT**: naming, grouping, a stronger matcher available (`toHaveValue` over
`toBeVisible`).

## 3. Run what the change touches

Respect any concurrency or machine-safety rules CLAUDE.md documents for
running tests locally — e.g. capping parallel workers, or waiting for another
test/build process to finish before starting yours. Never run the full suite
unless CLAUDE.md says you may.

Then, only the files the diff touches or that import changed modules, using
whatever commands CLAUDE.md gives for this repo. Examples (illustrative only —
use the repo's actual commands and flags):

```bash
npx vitest run <files>                                        # unit
npx vitest run --config vitest.integration.config.ts <files>  # integration
npx playwright test <spec> --repeat-each=2                    # only specs the diff touches
pytest <files>
```

Check CLAUDE.md for which database or env file integration tests target in
this repo (a worktree may have its own); say which one they hit in the
report. A failing or flaky run is a MAJOR finding with the output attached.
Do not fix it.

## Report

1. **Coverage table**: `behaviour | layer that proves it | test file | gap?`
   One row per behaviour from step 1. Gaps are the findings that matter most.
2. **Findings** by severity, each with `file:line`, what is wrong, and the
   concrete test to write or the assertion to change.
3. **Runs**: command, pass/fail, duration, database used.
4. **Verified OK**: the rules you checked and found clean.
5. **Recommended fix order**: gaps on acceptance criteria first, then
   cannot-fail tests, then flakes, then implementation coupling.

State plainly when coverage is adequate. Do not pad with NITs to look thorough.
