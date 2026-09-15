---
name: rodney-tips
description: Tips and workflow for using rodney (headless Chrome CLI) and showboat for screenshots, element interaction, JS execution, and PR documentation. Use when working with rodney or showboat commands, or when creating PRs with UI changes.
---

# Rodney & Showboat

## Setup & Availability

**Check availability:** `which rodney && which showboat` (rodney may be at `~/.local/bin/rodney`, showboat at `$(go env GOPATH)/bin/showboat`). If either is not installed, ask the user if they'd like you to install them:
- **rodney**: https://github.com/simonw/rodney — download the latest `darwin-arm64` release to `~/.local/bin/rodney`
- **showboat**: https://github.com/simonw/showboat — install via `go install github.com/simonw/showboat@latest`

## Session Management: --local vs --global

Rodney supports directory-scoped sessions — **always use `--local` when working in a worktree or any checkout that isn't your only one** to avoid colliding with other sessions.

- `rodney --local start` — creates `.rodney/` in the current directory, keeps session isolated
- `rodney start` (no flag) — uses global session at `~/.rodney/`
- Auto-detection: if `./.rodney/state.json` exists, subsequent commands automatically use the local session without needing `--local` on every command
- `rodney stop` — stops whichever session is active (local if `.rodney/` exists, global otherwise)

**Worktree rule:** Always `cd` to the worktree root and use `rodney --local start`. This way multiple worktrees can each have their own browser session without interference. **Only ever stop your own local session** — never run a broad `pkill`/global `rodney stop` that could kill another session's browser.

## Determining the Dev Server URL

Ports are frequently dynamic (assigned per worktree, per port-in-use fallback, etc.) — **don't hardcode a hostname or a fixed port.** Check the project's `CLAUDE.md` for:
- the command that starts the dev server, and whether it prints the port at startup
- any port-assignment scheme (e.g. hash-of-directory, sequential fallback)

If `CLAUDE.md` doesn't say, read the port from the running process's startup output (most dev servers print a `Local: http://localhost:<port>` line), then use `http://localhost:<port>`.

## PR Documentation Workflow

Use for PRs with UI changes, new endpoints, auth flows, or anything where visual proof strengthens the review. Skip for pure refactors, type-only changes, or config updates.

1. Start browser: `rodney --local start` (or just `rodney start` if not in a worktree)
2. Authenticate: use whatever local-login mechanism the project's `CLAUDE.md` documents. Many apps expose a dev-only auth bypass URL, e.g. `rodney open 'http://localhost:<port>/dev/auth?email=<user>'`. If `CLAUDE.md` doesn't document one, ask the user rather than guessing at credentials or a login flow.
3. Init showboat: `showboat init /tmp/demo.md "Title"` then use `showboat exec`, `showboat image`, and `showboat note`
4. Screenshot: `rodney screenshot -w 1280 -h 800 file.png` (browser-sized, NOT full-page)
5. Attach the PNGs to the PR with `gh pr create --attach` (see next section). Never `git add` a screenshot and never upload to a third-party image host.
6. Stop when done: `rodney stop`

## Attaching Screenshots to a PR (`gh --attach`)

`gh` uploads local images to GitHub and rewrites the body to point at the uploaded asset. Works on private repos; no external host needed.

**Version gate — check before anything else.** `--attach` needs `gh` ≥ 2.99.0:
```bash
gh --version   # need 2.99.0 or newer
```
If it is older, **stop and ask the user to upgrade** (`brew upgrade gh` on macOS, or the project's normal way of updating its toolchain images). Do not fall back to a third-party image host and do not open the PR without the screenshots.

**Reference the local path in the body, then attach the same path.** `gh` rewrites each `![alt](path)` in place, so markdown tables keep their layout:
```bash
cat > /tmp/pr-body.md <<'EOF'
## Screenshots

| Admin tab | Creation dialog |
|---|---|
| ![admin table](/tmp/shot-admin.png) | ![dialog](/tmp/shot-dialog.png) |
EOF

gh pr create --draft --base <base> --title "..." --body-file /tmp/pr-body.md \
  --attach /tmp/shot-admin.png \
  --attach /tmp/shot-dialog.png
```
`<base>` is the branch from `ship:pr` step 2 (the project's documented base, or the repo's default branch). The path string in the markdown must match the `--attach` path exactly. Alt text comes from the markdown.

**Unreferenced attachments are appended** to the end of the body in flag order, using `#` for the alt text (filename if omitted):
```bash
gh pr create --draft --base <base> --title "..." --body-file /tmp/pr-body.md \
  --attach '/tmp/shot-1.png#Modal on navigation' \
  --attach '/tmp/shot-2.png#Empty state'
```
Use this only when a bare list of images is acceptable; `ship:pr` wants tables, so reference them in the body instead.

**Adding screenshots after the PR exists:** `gh pr edit <n> --body-file ... --attach ...` and `gh pr comment <n> --attach ...` take the same flag.

Gotchas:
- Up to 50 files per command; the same file cannot be attached twice.
- Uploaded asset URLs are GitHub-authenticated. They render in the PR but not in other tools (chat, issue tracker) — link the PR from there instead of pasting the image URL.
- A failed upload still creates the PR; `gh` reports which files failed. Re-attach with `gh pr edit --attach`.

## Auth

- `rodney open 'http://localhost:<port>/<dev-auth-path>?email=<user>'` returns JSON — navigate separately after. Replace `<dev-auth-path>` with whatever the project's `CLAUDE.md` documents as its dev-only auth bypass.
- Scrolling: `rodney js 'window.scrollBy(0, 500)'` or `window.scrollTo(0, document.body.scrollHeight)`

## JS Execution Quirks

- `rodney js` does NOT support `const`/`let` — use `var` or wrap in IIFE: `(function(){var x=1;return x})()`
- Quoting: use single quotes around the JS expression, double quotes inside
- `rodney click 'text'` often fails on dynamic UI — prefer `rodney js` with DOM queries

## Finding & Clicking Elements

- Buttons: `rodney js '(function(){var btns=document.querySelectorAll("button");for(var i=0;i<btns.length;i++){if(btns[i].textContent.trim()==="Save"){btns[i].click();return "clicked"}}return "not found"})()'`
- Radio buttons: find by a stable attribute (e.g. `input[name="<field>-boolean"]`), check `parentElement.textContent` for the label
- Dropdowns/comboboxes built on a headless UI library (Radix, Headless UI, etc.) often render as `<button>` not `<select>` — click the button to open, then find options via `[data-value]` or leaf `<span>` elements

## Accessibility Tree (Finding Elements by Role/Name)

Use `ax-tree` and `ax-find` to locate elements without guessing selectors:

- `rodney ax-tree --depth 3` — dump the accessibility tree (limit depth to avoid huge output)
- `rodney ax-find --role button --name "Save"` — find accessible nodes by role and/or name
- `rodney ax-node 'button.submit'` — show accessibility info for a specific element
- Add `--json` to any ax command for machine-readable output

This is especially useful for finding elements in complex UIs where CSS selectors are fragile.

## Dropdown/Combobox Pattern (headless-UI-style components, e.g. Radix)

- Select trigger is a `<button>`, not `<select>` or `<input>`
- Clicking opens a popover — search input may appear inside
- Use `rodney input 'input[placeholder="..."]' 'text'` to type in search
- Options appear as `[data-value]` elements — click by matching textContent
- "Create new" options render as `<span>` leaf nodes with text like `Add "Name"`

## Waiting & Assertions

- `rodney wait 'selector'` — wait for element to appear
- `rodney waitload` — wait for page load event
- `rodney waitstable` — wait for DOM to stop changing (useful after navigation/form submission)
- `rodney waitidle` — wait for network idle (all requests settled)
- `rodney assert 'document.title' 'Expected Title' -m 'wrong page'` — assert JS expression equals expected value
- `rodney exists 'selector'` / `rodney visible 'selector'` — exit code 1 if check fails

## Showboat

- `showboat image` expects a **command to execute**, not a path to an existing file
- Wrong: `showboat image demo.md /tmp/screenshot.png "caption"`
- Right: `showboat image demo.md "rodney screenshot -w 1280 -h 800 /tmp/shot.png" "caption"`
- For existing files: `showboat image demo.md "echo /tmp/screenshot.png" "caption"`

## Common Pitfalls

- An "Unsaved Changes" dialog can appear when navigating away from a dirty form — click through it (discard or save) before continuing, or the next navigation/click will silently no-op.
- In worktrees (or any secondary checkout), forgetting `--local` on `rodney start` will use/clobber the global session — always use `--local` there.
- **No WebGL in rodney's Chrome** — WebGL-dependent libraries (e.g. mapbox-gl) throw "Failed to initialize WebGL". If a component renders such a library inside an unguarded effect, the throw can take the whole page down via the app's error boundary; components that catch the error just render a fallback and keep working. There is no rodney flag to enable software WebGL — verify WebGL-dependent flows via curl/SSR instead, or via a headed browser (see below).
- **A page that crashes headless Chrome itself** (heavy embeds, some third-party widgets) kills the rodney session on load — every command afterward fails `connection refused` and the session needs `rm -rf .rodney && rodney --local start`. Workaround: launch a real headed Chrome and drive it via `rodney connect` — headed Chrome tends to survive pages that kill headless:
  ```bash
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    --remote-debugging-port=9333 --user-data-dir=/tmp/chrome-rodney-profile \
    --no-first-run --no-default-browser-check --window-size=1290,940 "about:blank" &
  sleep 4 && rodney connect 127.0.0.1:9333   # then open/js/screenshot as normal; kill the Chrome PID when done
  ```
  (Older rodney builds predate `start --show`, so `connect` is the only headed path on those.) Without this, you get roughly one shot of 2-3 quick commands after `open` on a crash-prone page — batch DOM reads into a single `rodney js` call, or assert via curl instead.
- **Radix Select triggers do not open via synthetic events** — `.click()`, dispatched PointerEvents, and Enter keydown all leave `aria-expanded=false` (rodney's native `click` included). For a Radix Select, don't fight it: set the value at a lower layer (POST the form via curl) or drive the feature another way.
- **Radix DropdownMenu triggers need rodney's native `click`, not `.click()`** — a synthetic `.click()` from `rodney js` leaves `aria-expanded=false` and renders no menu. Tag the trigger in `rodney js` (`el.id="x"`), then `rodney click '#x'`; do the same for each `[role=menuitem]`.
