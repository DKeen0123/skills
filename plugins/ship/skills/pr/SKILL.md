---
name: pr
description: Create a pull request with description, screenshots, and reproduction checklist. Use when the user wants to open a PR for their current branch.
---

# Create Pull Request

## Steps

1. **Commit uncommitted changes** — check `git status` and `git diff` for any staged or unstaged changes. If there are any, stage them all and create a single atomic commit with a descriptive message summarizing the changes. Do NOT leave uncommitted work behind.

2. **Determine the base branch.** Check the repo's `CLAUDE.md` (or equivalent project doc) for an explicit PR/base-branch policy — follow it exactly, including any rule about which branches are exceptions. If nothing is documented, detect the default branch with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` and use that. Never hardcode a base branch and never override what the project doc says.

3. **Gather context** — run `git diff <base>...HEAD` and `git log <base>...HEAD --oneline` to understand all changes on the branch.

4. **Identify the issue-tracker ticket.** Check `CLAUDE.md` for which tracker the project uses (Linear, GitHub Issues, Jira, etc.) and its URL pattern. If the branch name encodes a ticket ID, link it using that pattern. If no ID is found and the doc doesn't clarify, ask the user once rather than guessing.

5. **Write the PR body.** First invoke the `ship:unslop` skill and apply its prose rules to the description — no AI vocabulary, filler phrases, or corporate hedging. Then use this structure:

```markdown
## TLDR

One paragraph stating exactly what this PR does and changes — the reader knows
what merging it will do after this paragraph alone. Link the ticket here.

## Why

Motivation and context, only what the TLDR doesn't carry. Omit if the TLDR says it all.

## Screenshots

<if visual changes, include screenshots — see step 6. Omit this section for non-visual changes.>

## How to test

Step-by-step checklist to reproduce the issue / verify the fix:

- [ ] Step 1...
- [ ] Step 2...
- [ ] Verify expected outcome...
```

   TLDR rules: it opens the body and describes the change itself (behaviour, files,
   data) — not the investigation, the motivation, or the review history. Concrete
   nouns and numbers ("removes vi.mock from 49 test files, adds `authedRequest.ts`"),
   not categories ("improves test infrastructure").

   Body-wide rules:
   - **Current truth only, stated once.** Never a claim followed by an "Update:"
     paragraph walking it back — rewrite the original claim. If the premise changed
     during the work, the body describes the final reality.
   - **No session narration.** "Before this session", "in this pass", "the previous
     agent", "I then found" — a PR reader doesn't know or care how the work was
     sliced. Describe the diff, not the diary.
   - **Numbers must agree with each other and with the diff.** One file count, used
     consistently; measurements labelled with what they were measured against.
   - **Verification reflects the branch head**, not an earlier state — update the
     body after a rebase or fix-up push if the results changed.

6. **Screenshots (only for visual changes).** If the caller already supplied screenshot paths (e.g. from `ship:ui-review`), use those directly and skip capture below. Otherwise, if the PR includes UI changes, use the `ship:rodney-tips` skill workflow to capture screenshots proving the change works. Skip this step entirely for non-visual changes (config, backend, refactors, etc.).
   - Start rodney (`rodney --local start`)
   - Start the dev server if not already running — see the project's `CLAUDE.md` for the command and how it reports its port.
   - Authenticate using whatever local-login mechanism `CLAUDE.md` documents (a dev-auth bypass, a seeded test account, etc.). If none is documented, ask the user once rather than guessing credentials.
   - Navigate to the relevant page and screenshot the before/after or final state to a temp path, e.g. `/tmp/<slug>-<name>.png`
   - Check `gh --version` is ≥ 2.99.0. If not, stop and ask the user to upgrade `gh` (`brew upgrade gh`) — do not upload to a third-party host and do not open the PR without the screenshots. Details in `ship:rodney-tips` § Attaching Screenshots.
   - Reference the **local PNG paths** in the PR body as **markdown tables with a header row naming each screenshot** — never a bare list of images. `gh pr create --attach` rewrites each path to the uploaded GitHub asset in place, so the tables survive. Group related screenshots into one table per theme/surface (e.g. one table for admin views, one for a public page), max 3 columns per table so images stay readable:
     ```markdown
     | Admin tab | Creation dialog | After create |
     |---|---|---|
     | ![admin table](/tmp/pr-admin.png) | ![dialog](/tmp/pr-dialog.png) | ![after create](/tmp/pr-after.png) |

     | List — empty | List — populated |
     |---|---|
     | ![list empty](/tmp/pr-list-empty.png) | ![list populated](/tmp/pr-list-populated.png) |
     ```
     Header labels should be short and descriptive (`Surface — state`, e.g. `List — populated`). For before/after comparisons, use a two-column `| Before | After |` table.
   - Stop rodney when done

7. **Push and create the PR:**
   - Push the branch with `-u` if needed
   - Create via `gh pr create --base <base> --body-file <body.md>` (the base from step 2), passing one `--attach <path>` per screenshot referenced in the body (same path string as in the markdown):
     ```bash
     gh pr create --draft --base <base> --title "..." --body-file /tmp/pr-body.md \
       --attach /tmp/pr-admin.png \
       --attach /tmp/pr-dialog.png
     ```
     Use `--draft` unless the user asked for a ready-for-review PR.
   - Return the PR URL to the user
