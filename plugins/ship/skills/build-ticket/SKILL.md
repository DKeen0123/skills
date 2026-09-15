---
name: build-ticket
description: Pick up a ticket and ship it end to end with subagents - Sonnet builders implement it in a worktree, then three reviewers run in parallel (Opus `review`, Sonnet `ui-review`, Sonnet `testing-review`), findings route back to fresh Sonnet fixers until clean, a `unslop` pass tidies UI and copy, then one pusher agent pushes and opens a draft PR via `pr`. The main session only orchestrates. Usage /build-ticket <ticket-id-or-url> (or paste the ticket text directly).
---

# Build Ticket

Skills in this collection are referred to by bare name. When installed as the
Claude Code plugin they are namespaced `ship:<name>`; use that form when
invoking one from Claude Code.

You are the orchestrator. **You never write code, edit application files, run
tests, start servers, or push.** You fetch the ticket, brief agents, read their
reports, route findings, and report to the user. No plan mode; start at once.

If you make more than five non-coordination tool calls in a row, stop and
delegate.

## Standing rules for every agent prompt

Paste this block verbatim into every builder, fixer, reviewer and pusher prompt:

```
Read CLAUDE.md at the repo root first, and any docs it points to for the files you touch.
Worktree: <absolute path>. Branch: <branch>. Base: <default branch>. Work only inside this worktree.
Machine safety: respect any concurrency limits or safe test-run practices CLAUDE.md documents. Default when silent: never run the full test suite, only the files you touched; if the runner supports a worker cap, cap it at 2.
Git: commit only. NEVER push. NEVER --no-verify. NEVER touch the default branch.
Report back with: files changed (one line each), tests added/changed and how you ran them, routes/surfaces affected, anything you could not do and why.
```

Rulings: number every directive you send (`R1`, `R2`…). Never reverse one
without first sending a freeze and getting an ack. One writer per worktree at
a time: a fixer starts only after the previous builder/fixer has reported.

## Phase 1: ticket

1. Resolve the ticket source, in order: a Linear-shaped id with Linear MCP
   tools available → `mcp__linear-server__get_issue` then `list_comments`,
   and `extract_images` for any embedded images; else a GitHub issue number
   or URL → `gh issue view <n> --json title,body,comments`; else treat the
   input as pasted text or a spec and work from that directly (skip the
   remaining ticket-system steps below).
2. Mark it in progress in whatever source you used (Linear `save_issue` with
   assignee me and state In Progress; `gh issue edit <n> --add-assignee @me`
   for GitHub; nothing to do for pasted text).
3. Determine the default branch if unstated:
   `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
   Branch name: `<ticket-id>/<slug>` when there is an id, else `feat/<slug>`
   (slug under six words). Create the worktree with the `worktrees` plugin's
   `just worktree-new <branch>` if `just --list 2>/dev/null | grep -q
   worktree-new`, else `git worktree add ../<repo-name>-<branch> -b
   <branch>`. If worktree creation warns about a database or migration
   problem, follow the fix CLAUDE.md documents for it. Read the absolute
   worktree path for the standing-rules block from this command's own
   output, or from `git worktree list` — the other read-only git command
   you may run yourself (see Phase 3).
4. Write a **brief** you will reuse for every agent: ticket id and URL (if
   any), the problem in your words, acceptance criteria as a numbered list,
   links to any docs CLAUDE.md names as relevant, out-of-scope notes. Tell
   the user the branch name and go.

If the ticket contradicts itself or lacks something no agent could infer, ask
the user once, then proceed.

## Phase 2: build (Sonnet)

Spawn one builder: `Agent(model: "sonnet", name: "builder", subagent_type: "general-purpose")`.
Its prompt = standing rules + brief + these instructions:

- Set up the worktree per Phase 1 step 3 if not already created.
- Implement the ticket. Invoke `testing` before writing tests. Cover each
  acceptance criterion on the real path: an integration test against a real
  database or an E2E test through the route; a fully-mocked unit test alone
  does not count.
- Build UI from the project's shared component library and follow its form
  and toast/notification patterns, as CLAUDE.md documents.
- Update any doc CLAUDE.md requires for the domain you changed, in the same
  commit.
- Run the typecheck, lint, and test commands CLAUDE.md gives, scoped to what
  you touched. Commit as `feat|fix: <desc> (<ticket-id>)` (omit the
  parenthetical if there is no ticket id), with whatever commit trailer the
  project or harness specifies, if any. Do not push.
- Leave the dev server running if it started one, and report the port.

Split into parallel builders only when the ticket has slices with disjoint file
sets. Then each builder owns a named file list, none commits, and after all
report you spawn one `integrator` (Sonnet) to typecheck, lint, resolve seams
and make the single commit.

If a builder reports it is blocked, spawn a fresh builder with the missing
information. Do not take over.

## Phase 3: review (three agents in parallel, one message)

When the builder's report is in, collect the review brief: worktree path
(from `git worktree list`, or the builder's report), branch, `git diff
--stat <default-branch>...HEAD` in the worktree — these two are the only
read-only git commands you may run yourself — the file list with one-line
descriptions from the builder's report, routes affected, dev server port,
acceptance criteria.

Spawn all three in a single message so they run concurrently. Each prompt =
standing rules + review brief + "You are read-only: no edits, no commits" +
the line below. Each must severity-rate every finding MAJOR / MINOR / NIT with
`file:line` and a one-line fix.

| agent | model | instruction |
|---|---|---|
| `reviewer-code` | opus | Invoke the `review` skill on this branch and follow it. |
| `reviewer-ui` | sonnet | Invoke the `ui-review` skill and follow it, both passes. Skip this agent entirely, and say so in the final report, only when the diff touches no UI or style file. |
| `reviewer-tests` | sonnet | Invoke the `testing-review` skill and follow it, including running the touched suites. |

Reviewers share the worktree read-only. Only `reviewer-ui` may start a rodney
session (`--local`) and only it may start the dev server if none is running.

## Phase 4: fix loop

1. Merge the three reports. De-duplicate. Drop a finding only if you can say in
   one sentence why it is wrong, and list every dropped finding in the final
   report.
2. Group the remaining MAJOR and MINOR findings into one fix task (or a few,
   by area, run **sequentially** since one worktree has one writer). NITs go in
   the same task only if cheap.
3. Spawn `fixer-<n>` (Sonnet) with standing rules + the findings verbatim
   (file:line, reviewer's wording, reviewer's suggested fix) + "fix each one,
   re-run typecheck, lint and the touched tests, commit, report which findings
   you fixed and which you disagree with and why".
4. Re-review: spawn only the reviewers whose findings were touched, scoped to
   "confirm these findings are resolved and the fixes introduced nothing new"
   (fresh agents, new names, e.g. `reviewer-ui-2`). A reviewer that returned
   only NITs is not re-run.
5. Converge when no MAJOR or MINOR remains. Cap at three rounds; after that,
   list the residuals for the user and continue to Phase 5.

A fixer's disagreement with a finding is settled by you, in writing, in the
next directive. Do not let a fixer and a reviewer argue through you unnamed.

## Phase 4b: unslop (one Sonnet agent, after the loop converges)

Spawn `unslopper` (Sonnet) with standing rules and: "Invoke the `unslop`
skill. Audit every file in `git diff --name-only <default-branch>...HEAD`,
both the visual checklist on changed UI and the writing checklist on
user-facing copy, error messages, empty states, comments and any docs
changed. Fix in place using the project's shared component library,
re-verify changed surfaces with rodney, run the typecheck/lint commands
CLAUDE.md gives, commit as `chore: unslop (<ticket-id>)` (omit the
parenthetical if there is no ticket id). Report each fix and each finding you
left alone with a one-line reason." Skip only when the diff has no UI and no
prose; say so in the final report. If it restyled a surface, run a scoped
`reviewer-ui-<n>` once more on those files before Phase 5.

## Phase 5: push and PR (one Sonnet pusher)

Spawn `pusher` (Sonnet) with standing rules and:

- This workflow runs a single pusher. If CLAUDE.md documents a wait command
  for its push hook, run it; otherwise push directly.
- Push in the foreground with a reasonable timeout, logging to a scratch
  file. Verify with `git ls-remote origin <branch>`. If a pre-push check
  fails, do not bypass it; report the failure with the log tail and stop.
- Open the PR by invoking the `pr` skill and following it (it writes
  the body through `unslop`, base is the default branch, never
  overridden to a release branch unless CLAUDE.md says otherwise). Pass it:
  the ticket URL (if any), acceptance criteria for the **How to test**
  checklist, the screenshot paths already captured by `ui-review` so
  it does not re-shoot, and a **Review** section listing the review rounds
  and residual findings. Create it as a draft.
- Return the PR URL.

If the push check fails, spawn a fixer for the reported failure (see any
failure → fix table CLAUDE.md names), then a new pusher.

## Phase 6: close out

1. Post the PR URL back to the ticket source (Linear comment / `gh issue
   comment`); skip for pasted text. Do not change the ticket's state past In
   Progress; the user moves it on review.
2. Report to the user, in this order: PR URL; what was built in three lines;
   review rounds and what each round fixed; findings dropped or residual, with
   your one-line reason each; the local login URL per CLAUDE.md, if any, for
   the main affected route.

Never merge. Never mark the ticket done.
