---
name: ui-review
description: Review the UI of the current branch in two passes - a visual verification of every changed surface in a real browser (rodney), and a design-system audit checking that the project's shared component library and colour/typography tokens are used where they apply. Read-only, reports findings; never edits or commits. Use when asked for a "UI review", "visual review", "design system check", or as the UI reviewer inside ship:build-ticket.
---

# UI Review

Two passes over the branch, one report. You are a reviewer: **never edit
application files, never commit, never push.** The only things you may start are
the dev server and a rodney browser.

Inputs you need (ask the caller if missing, otherwise derive them):

- worktree path, branch, base (the default branch — `gh repo view --json
  defaultBranchRef -q .defaultBranchRef.name` if unstated)
- the routes/surfaces affected (derive from changed route files and from
  where changed components are imported)
- a user to log in as (the project's local-login default per CLAUDE.md, if
  it has one)

If CLAUDE.md documents no local-login mechanism, ask the caller once. If the
caller still has none, skip pass 2 entirely and report the affected surfaces
as not visually verified, with that reason.

Read CLAUDE.md's UI/component guidance in full before pass 1, including any
doc it links for the design system. Invoke `ship:rodney-tips` before pass 2.

## Pass 1: design-system audit (static)

```bash
git diff <base>...HEAD -- '*.tsx' '*.ts' '*.css'
```

Read every changed UI file whole, not just the hunks. Each item below is a
finding when it applies and a "verified OK" line when checked and clean.

Find the project's component library and token rules from CLAUDE.md first —
it usually names a components directory, and may split libraries by area
(e.g. one for end-user surfaces, a different one for admin). If CLAUDE.md
names none, grep for a `components/` or `components/ui/` directory and treat
whatever it exports as the library for this audit.

**Components over raw elements**
- Raw `<h1>`–`<h6>`/`<p>`/text `<span>` where a heading/text component fits.
  Raw `<button>`, `<a>`, `<input>`/`<select>`/`<textarea>`, `<table>` where a
  library component exists.
- If CLAUDE.md names separate libraries for different areas of the app, using
  the wrong one for the area is a finding.
- A UI primitive (toast, dialog, dropdown, menu) imported straight from its
  underlying package instead of through the project's own wrapper, when
  CLAUDE.md says to always go through the wrapper. A new lint-suppression
  comment added to get around that rule is a MAJOR.
- A local hand-rolled copy of something the library already provides (a
  modal, dropdown, tag, search input, tabs). The fix is to extend the
  library component.
- Forms built without the project's form library, if CLAUDE.md names one.
- A bespoke search input where a shared one exists.

**Tokens**
- Colours: any hex or `rgb()` in TSX/CSS, any arbitrary Tailwind colour
  (`bg-[#…]`, `text-[rgb…]`), any colour family outside the ones CLAUDE.md
  (or the token doc it links) lists as valid.
- Typography: font sizes set via raw `className` instead of a component's
  `size` prop; arbitrary `text-[13px]`; a `leading-*` override "fixing" a
  line-height the library sets deliberately.
- Spacing/radius: off-scale arbitrary values (`p-[13px]`, `rounded-[7px]`)
  where a scale step is available.

**Known traps** — check CLAUDE.md, and any component-library doc it links, for a project-specific known-traps list, and hold the diff against it.

**Lint on the changed files** (warnings count, they are the raw-element
rule): run the repo's configured linter on the changed files, using the
command CLAUDE.md gives. Skip this check if the repo has no configured
linter — never fetch one ad hoc just to run it.

## Pass 2: visual verification (browser)

1. Start the dev server if it is not running — follow CLAUDE.md's
   instructions for starting it as an agent and confirming it is ready. Never
   start a second one on the same worktree.
2. `cd <worktree> && rodney --local start`, then log in as the user from the
   Inputs section using whatever local-login method CLAUDE.md documents. If
   none is documented and the caller supplied none, stop here per the
   Inputs section above.
3. For every affected route, and every state the change introduces (empty,
   populated, error, open dialog/panel, expanded row), screenshot at desktop
   `-w 1280 -h 800` and mobile `-w 390 -h 844`. Drive interactions with
   `rodney --local js` (IIFE, `var` only). Reach states through the UI where you
   can; note any state you could not reach.
4. **Look at every screenshot** with the Read tool. Do not describe a screenshot
   you have not opened. Check: layout broken or overflowing, text clipped,
   controls off the grid, misaligned with neighbouring surfaces, low contrast,
   hover/focus/disabled states, loading flash, the change actually visible,
   and the `ship:unslop` visual blacklist (purple gradients, icon-in-circle grids,
   centred-everything, coloured left borders, emoji as decoration, generic
   copy, empty states with no action).
5. Compare against a sibling surface that already does the same job (another
   list page, another detail card) and flag anything that reads as a
   different app.
6. Keep the PNGs where they are; `ship:pr` attaches them with `gh pr create
   --attach` (see `ship:rodney-tips`). Do not upload them anywhere.
7. `rodney --local stop`. Leave the dev server running and report its port.

## Report

Severity: **MAJOR** (wrong component/token, broken layout, unreachable or
misleading state), **MINOR** (off-pattern but works), **NIT** (taste). Every
finding has `file:line`, what is wrong, and the fix in one line. Then:

- **Verified OK**: the checklist items you checked and found clean, one line each.
- **Screenshots**: `route — state — viewport — /tmp/<path>.png`, one per line.
- **Not reached**: states you could not drive from the UI and why.
- **Dev server**: port, and the local-login link for the main affected route,
  per CLAUDE.md.

Do not soften findings because the change is otherwise good. Do not report a
surface as working from code reading alone.
