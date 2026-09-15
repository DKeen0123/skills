---
name: review
description: Review the current branch's diff against its base for correctness, edge cases, type safety, test coverage, and convention consistency. Use when the user asks for a PR review, code review, or to review the current branch/changes.
---

# PR Review Skill

Conduct a thorough review of the current branch.

## Steps

1. **Find the diff.** Determine the base branch from the repo's `CLAUDE.md` (or equivalent project doc); if undocumented, use `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`. Run `git diff <base>...HEAD` and read every changed file in full context, not just the hunks — a diff without surrounding code hides bugs.
2. **Read the project's conventions** before judging style: `CLAUDE.md` and any linked docs it points to for this area of the code (architecture, required libraries/patterns, naming, lint rules). Flag deviations from what's actually documented, not from personal preference.
3. **Check, in order:**
   - **Correctness** — does the code do what it claims; trace the actual control flow rather than trusting names/comments.
   - **Edge cases** — empty/null/zero inputs, concurrent access, error paths, off-by-ones, boundary conditions the tests don't hit.
   - **Type safety** — unsound casts, `any`/loose types, unchecked external data.
   - **Test coverage on the real path** — does a test exercise this against real state (real DB, rendered DOM, actual route), not just a mocked expectation? If the change altered behavior with no such test, say so.
   - **Consistency** — matches the codebase's established architectural patterns (service layer, data-access layer, form/validation library, etc.) as documented or as shown by surrounding code.

## Output

A structured findings list, most severe first:

- **MAJOR** — bugs, broken behavior, missing test coverage on changed behavior, security issues.
- **MINOR** — edge cases likely to bite, convention violations, weak typing.
- **NIT** — style, naming, small readability wins.

Each finding: `file:line`, what's wrong, and a one-line fix. Close with a one-line verdict (ship it / fix MAJORs first / needs rework).

Do NOT create PRD files or implementation plans — this skill only reviews.
