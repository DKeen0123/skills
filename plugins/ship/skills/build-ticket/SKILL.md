---
name: build-ticket
description: Pick up a ticket and ship it end to end with subagents - role agents (Sonnet builders at medium effort, capped turns, handing off when long) implement it in a worktree, then up to three reviewers run in parallel (Opus `review`, Sonnet `ui-review`, Sonnet `testing-review`; small tickets scale this down to a single generic `review` at the orchestrator's discretion), findings route back to fresh Sonnet fixers until clean (reviewers carry the `unslop` checklists, so there is no separate slop pass), then one pusher agent pushes and opens a draft PR via `pr`. The main session only orchestrates. Usage /build-ticket <ticket-id-or-url> (or paste the ticket text directly); add `ultracode` or `--workflow` to run the bundled Workflow script instead of orchestrating by hand.
---

# Build Ticket

Skills in this collection are referred to by bare name. When installed as the
Claude Code plugin they are namespaced `ship:<name>`; use that form when
invoking one from Claude Code.

## Workflow mode (ultracode)

When the invocation carries `ultracode` or `--workflow`, or a system reminder
says ultracode is on for the session, do not orchestrate by hand. Run the
bundled Workflow script and relay its result:

```
Workflow({ name: "ship:build-ticket-flow", args: { ticket: "<id, URL or pasted text>" } })
```

The plugin ships the script at `workflows/build-ticket-flow.js`, so it
resolves as `ship:build-ticket-flow` once the plugin is installed. Installed
through the `skills` CLI instead, copy that file into the project's
`.claude/workflows/` and call it as `build-ticket-flow`, or pass `scriptPath`.
Optional args: `shape` (`auto` | `full` | `partial` | `light`, default `auto`),
`maxRounds` (default 2). It runs the same agents and rules as the phases
below, with the setup steps overlapped and every review round parallel. When
it returns, do Phase 6's report from its result (it has already posted the
ticket comment). If it throws before pushing, read its `journal.jsonl` (path
in the tool result) and resume with `resumeFromRunId` rather than starting
over.

## Manual mode

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
Machine safety: respect any concurrency limits or safe test-run practices CLAUDE.md documents. Default when silent: never run the full test suite, only the files you touched; if the runner supports a worker cap, cap it at 2; before a test run, wait for any other test run on the machine to finish (typecheck and lint need no wait).
Checks: use the typecheck, lint and test commands CLAUDE.md gives, nothing slower. Typecheck once, at the end, not after every edit. Do not re-run a typecheck, lint or suite that the previous agent's report shows green unless your own edits touched what it covers; the push hook (if the repo has one) runs the full gate at push time.
Git: commit only. NEVER push. NEVER --no-verify. NEVER touch the default branch.
Context: every tool call re-reads your whole transcript. Combine related shell commands into one call; never poll with sleep loops; read only the line ranges you need; do not re-read a file you just edited; summarise command output in your report instead of pasting it. After roughly 120 tool calls, or when a plan step is done and the next is large, commit (WIP is fine) and report `handoff: true` with the remaining steps and the sha; a fresh agent continues.
Report back with: files changed (one line each), tests added/changed and how you ran them, the exact check commands you ran and their result, routes/surfaces affected, anything you could not do and why.
```

## Agent roles

Every agent is spawned by role with `subagent_type` set to one of the
definitions in this plugin's `agents/`: `runner`, `builder`, `fixer`,
`reviewer-code`, `reviewer-ui`, `reviewer-tests`, `pusher` (namespaced
`ship:<name>` when installed as the Claude Code plugin). The definition
fixes the model, the reasoning effort and a turn cap, so **do not pass
`model`** on the Agent call. Effort is medium for builders and fixers, high
for the Opus code reviewer, low for runner and pusher.

Installed through the `skills` CLI the agent definitions are not delivered.
Then spawn `general-purpose` with the model from the table below and paste
the Context line of the standing rules into every prompt; effort stays at
the session default.

## Context budget and handoff

A subagent's cost is its transcript length times its request count, so
a builder that runs 600 tool calls in one context costs more than three
builders of 200. The agent definitions carry the budget rules (batch shell
commands, no polling, touched tests only, hand off after roughly 120 tool
calls). Your side of the contract:

- On a report with `handoff: true`, spawn `builder-<n+1>` (or `fixer-<n+1>`)
  with the brief, the remaining steps verbatim, and the commit sha. Do not
  send follow-up work to the finished agent.
- If an agent stops with no report (it hit its turn cap), run
  `git -C <worktree> log --oneline <default branch>..HEAD` and
  `git -C <worktree> status --short` (read-only, allowed), then spawn a
  continuation agent with what landed and what is left.
- Brief the next agent with the plan step it starts from, not the previous
  agent's transcript.

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
   problem, follow the fix CLAUDE.md documents for it. **Spawn `prep` (`subagent_type: "runner"`)
   (Sonnet) to do this now**, before writing the brief: it creates the
   worktree, applies any documented setup fix, and, if the ticket touches a
   route or component, starts the dev server the way CLAUDE.md describes
   and reports the port. Setup is minutes; it overlaps with step 4 instead
   of sitting inside the builder. Read the absolute worktree path for the
   standing-rules block from `prep`'s report, or from `git worktree list` —
   the other read-only git command you may run yourself (see Phase 3).
4. Write a **brief** you will reuse for every agent: ticket id and URL (if
   any), the problem in your words, acceptance criteria as a numbered list,
   links to any docs CLAUDE.md names as relevant, out-of-scope notes. Tell
   the user the branch name and go. Spawn the builder as soon as `prep`
   reports.

If the ticket contradicts itself or lacks something no agent could infer, ask
the user once, then proceed.

## Phase 2: build (Sonnet)

Spawn one builder: `Agent(name: "builder", subagent_type: "builder")`.
Its prompt = standing rules + brief + these instructions:

- The worktree already exists (`prep` created it); the dev server port, if
  any, is in the brief. Do not start a second server.
- Implement the ticket. Invoke `testing` before writing tests. Cover each
  acceptance criterion on the real path: an integration test against a real
  database or an E2E test through the route; a fully-mocked unit test alone
  does not count.
- Build UI from the project's shared component library and follow its form
  and toast/notification patterns, as CLAUDE.md documents.
- Update any doc CLAUDE.md requires for the domain you changed, in the same
  commit.
- Run the typecheck once, lint on changed files, and the tests you wrote,
  with the commands CLAUDE.md gives. Commit as `feat|fix: <desc> (<ticket-id>)`
  (omit the parenthetical if there is no ticket id), with whatever commit
  trailer the project or harness specifies, if any. Do not push.
- Verify a changed surface visually once with rodney if it is new or its
  layout changed; do not loop on screenshots, `reviewer-ui` does the full pass.
- Report the check commands and results verbatim so reviewers can trust them.

Split into parallel builders only when the ticket has slices with disjoint file
sets. Then each builder owns a named file list, none commits, and after all
report you spawn one `integrator` (`subagent_type: "builder"`) to typecheck, lint, resolve seams
and make the single commit.

If a builder reports it is blocked, spawn a fresh builder with the missing
information. Do not take over.

## Phase 3: review (up to three agents in parallel, one message)

When the builder's report is in, collect the review brief: worktree path
(from `git worktree list`, or the builder's report), branch, `git diff
--stat <default-branch>...HEAD` in the worktree — these two are the only
read-only git commands you may run yourself — the file list with one-line
descriptions from the builder's report, routes affected, dev server port,
acceptance criteria.

### Pick the review shape

Decide from the diff stat and the builder's report which reviewers the change
earns. The full set is the default; scale down only when you can say why in
one line, and put that line in the final report.

| shape | when | reviewers |
|---|---|---|
| Full | default: new behaviour, a new route or surface, schema or service changes, anything touching more than a handful of files | all three below |
| Partial | the change is real but one axis is empty: no UI touched → drop `reviewer-ui`; no test-worthy behaviour changed (copy, config, a doc, a pure refactor with existing coverage) → drop `reviewer-tests` | the remaining one or two |
| Light | a small, self-contained change: a one-liner, a copy fix, a config tweak, a doc-only ticket, a bug fix inside one function with an existing test | one generic `reviewer` (see below) |

Rules for scaling down:

- A diff touching a UI or style file always keeps `reviewer-ui` unless you go
  Light, and Light is not allowed when a rendered surface changed in a way a
  screenshot would catch (layout, new component, new state). A copy change
  inside an existing component may go Light.
- A diff that adds or changes a test file, a migration, or a service module
  keeps `reviewer-tests`.
- When unsure, go Full. Three cheap reviews cost less than a missed MAJOR.

### Spawn

Spawn the chosen reviewers in a single message so they run concurrently. Each
prompt = standing rules + review brief (including the builder's check results)
+ "You are read-only: no edits, no commits" + the line below. Each must
severity-rate every finding MAJOR / MINOR / NIT with `file:line` and a one-line
fix, and must mark a finding `pre-existing` when the defect is not introduced
by this diff (those go to the PR body, never to a fixer). A MAJOR that claims a
test cannot fail must be demonstrated (mutate the code under test, run it,
quote the output); an assertion from types alone is a MINOR at most.

| agent (= `subagent_type`) | model, effort | instruction |
|---|---|---|
| `reviewer-code` | opus, high | Invoke the `review` skill on this branch and follow it. Also run the `unslop` writing checklist (audit mode) over user-facing copy, error messages, empty states and docs in the diff and report slop as findings. |
| `reviewer-ui` | sonnet, medium | Invoke the `ui-review` skill and follow it, both passes, including the `unslop` visual blacklist in pass 2. Mobile viewport only if the ticket asks for it or the surface is customer-facing. |
| `reviewer-tests` | sonnet, medium | Invoke the `testing-review` skill and follow it. It is the only round-1 reviewer that runs suites; skip any the builder's report shows green and the diff did not change since. |
| `reviewer` (Light only) | opus | Invoke the `review` skill on this branch and follow it, plus the `unslop` writing checklist. Also confirm the builder ran the touched tests, and if a UI file changed, load the surface once with rodney and say what you saw. |

Reviewers share the worktree read-only. Only `reviewer-ui` (or `reviewer` in
the Light shape) may start a rodney session (`--local`) and only it may start
the dev server if none is running. `reviewer-code` runs no suites and no lint
(the builder's report and the push hook cover them); it may run a single file
when a finding depends on it. In the Light shape the single report is the
one reviewer report for Phase 4, and a re-review is another `reviewer-<n>`
scoped to the fixed findings.

## Phase 4: fix loop

1. Merge the reviewer reports. De-duplicate. **Triage before dispatch**: a
   finding marked pre-existing, or one asking for a test layer the repo does
   not have, goes to the PR body's Review section or a new ticket, not to a
   fixer. Drop a finding only if you can say in one sentence why it is wrong,
   and list every dropped finding in the final report.
2. Group the remaining MAJOR and MINOR findings into one fix task. NITs go in
   the same task only if cheap. Split into parallel fixers only when the
   groups have disjoint file sets; otherwise one fixer.
3. Spawn `fixer-<n>` (`subagent_type: "fixer"`) with standing rules + the findings verbatim
   (file:line, reviewer's wording, reviewer's suggested fix) + "fix each one,
   update any doc CLAUDE.md requires for what you change, run typecheck once,
   lint and the touched tests, commit, report which findings you fixed and
   which you disagree with and why. Screenshot with rodney only for a finding
   that was visual, once, and do not poll for a surface to render."
4. Re-review only when the round had a MAJOR. Spawn only the reviewers whose
   findings were touched, scoped to the fix commit (`git diff <builder-sha>..HEAD`)
   and to "confirm these findings are resolved and the fixes introduced nothing
   new" (fresh agents, new names, e.g. `reviewer-ui-2`). `reviewer-ui-<n>`
   re-shoots only the surfaces the fix touched. A reviewer that returned only
   NITs is not re-run.
5. When a round's findings were all MINOR/NIT, one fixer batches them and the
   loop ends with no re-review; the push hook and the human review cover
   them. Cap at two rounds; after that, list the residuals for the user and
   continue to Phase 5. A third round has only ever found churn on the second
   round's fix.

A fixer's disagreement with a finding is settled by you, in writing, in the
next directive. Do not let a fixer and a reviewer argue through you unnamed.

## Phase 5: push and PR (one pusher)

Spawn `pusher` (`subagent_type: "pusher"`) with standing rules and:

- This workflow runs a single pusher. If the repo has a push hook and
  CLAUDE.md documents a wait command for it, run it with a two-minute cap;
  otherwise push directly. Any wait must poll with an anchored `pgrep -f`
  on the hook script's path (`^bash <path-to-hook>`); a `ps | grep -E`
  alternation matches its own shell and spins until the tool times out.
- Push in the foreground with a reasonable timeout, logging to a scratch
  file. Verify with `git ls-remote origin <branch>`. If a pre-push check
  fails, do not bypass it; report the failure with the log tail and stop.
- Open the PR by invoking the `pr` skill and following it (it writes
  the body through `unslop`, base is the default branch, never
  overridden to a release branch unless CLAUDE.md says otherwise). Pass it:
  the ticket URL (if any), acceptance criteria for the **How to test**
  checklist, the screenshot paths already captured by `ui-review` so
  it does not re-shoot, and a **Review** section listing the review rounds,
  residual findings and pre-existing findings triaged out. Create it as a
  draft. Do not re-shoot screenshots and do not start a dev server or rodney.
- Return the PR URL.

If the push check fails, spawn a `fixer` for the reported failure (see any
failure → fix table CLAUDE.md names), then a new pusher.

## Phase 6: close out

1. Post the PR URL back to the ticket source (Linear comment / `gh issue
   comment`); skip for pasted text. Do not change the ticket's state past In
   Progress; the user moves it on review.
2. Report to the user, in this order: PR URL; what was built in three lines;
   the review shape chosen (Full / Partial / Light) and, if not Full, the
   one-line reason; review rounds and what each round fixed; findings dropped,
   triaged out as pre-existing, or residual, with your one-line reason each; the local login URL per CLAUDE.md, if any, for
   the main affected route.

Never merge. Never mark the ticket done.
