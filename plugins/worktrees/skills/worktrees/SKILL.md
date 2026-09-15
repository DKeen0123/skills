---
name: worktrees
description: Set up or use one isolated git worktree (or jj workspace) per branch, via just recipes. Use when a user wants per-branch worktree isolation, asks to create/list/remove/clean-up worktrees, says "never work on main/default branch", or a project's justfile already has worktree-* recipes and the user wants to use them.
---

# Worktrees

One git worktree (or jj workspace) per branch, driven by `just` recipes, with a hook system for project-specific setup (installing deps, forking a database, copying secrets). Ships as scripts + a `just` module, not a long-running service.

## Installing into a project

```bash
mkdir -p scripts/worktrees
cp "${CLAUDE_PLUGIN_ROOT}/worktrees.just" scripts/worktrees/
cp "${CLAUDE_PLUGIN_ROOT}/scripts/"* scripts/worktrees/
chmod +x scripts/worktrees/*.sh
```

Add one line to the project's root `justfile`:

```just
import 'scripts/worktrees/worktrees.just'
```

`worktrees.just` and the `.sh` scripts must end up as siblings in the same directory — recipes find the scripts via `source_directory()`, which resolves relative to `worktrees.just` itself, not the importing justfile (see comment at the top of `worktrees.just` for why `justfile_directory()` is wrong here: it resolves to the *importing* justfile's directory — the repo root — since this module is installed and imported from a subdirectory, `scripts/worktrees/`, not the root itself).

The scripts also run standalone, without `just`: `bash scripts/worktrees/worktree-new.sh feat/my-change`.

Then set up hooks for whatever the project needs (see below) and, optionally, install the weekly cleanup job:

```bash
just worktree-gc-install
```

### gitignore

`scripts/worktrees/` collides with an unanchored `worktrees/` entry elsewhere in `.gitignore`. Use root-anchored entries — `/worktrees/`, `/.worktree-graveyard/`, `/.worktree-keep` — and gitignore anything `.worktree/copy-files` copies into a worktree (`.env`, etc.): otherwise every new worktree is dirty from the moment it's created, and `worktree-gc`'s clean-check (below) never passes, so GC never collects it. `worktree-new` prints a one-time warning if the worktree directory itself isn't root-anchored in `.gitignore`.

### Configuration

| Var / just variable | Default | Effect |
|---|---|---|
| `WORKTREE_BASE_DIR` env var / `worktree_dir` just variable | `worktrees` | Directory new worktrees are created under, relative to the repo root |
| `WORKTREES_BASE_BRANCH` env var / `worktree_base_branch` just variable | empty = auto | Branch new worktrees are cut from, and what GC judges "merged" against; see the auto-detection rule below |

## Day-to-day use

```bash
just worktree-new feat/my-change     # create a worktree + branch, run hooks
just worktree-new feat/x --no-hooks  # skip .worktree/post-create.sh
just worktree-list                   # path, branch, dirty/clean status
just worktree-remove worktrees/feat-my-change   # run pre-remove hook, then remove
just worktree-remove worktrees/feat-my-change --force  # ...even with uncommitted/unpushed work
just worktree-remove                 # interactive picker
just worktree-gc                     # dry run: what merged+idle+clean worktrees would go
just worktree-gc-apply               # actually remove them
```

**Rule of thumb for an agent: never edit code on the repo's default branch. If in doubt, `just worktree-new <branch>` first.**

New branches are cut from the freshly-fetched default branch (`git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main`, then `master` if `main` doesn't exist — override with the `worktree_base_branch` just variable or `WORKTREES_BASE_BRANCH` env var), not whatever happens to be checked out locally. `origin/HEAD` being unset (e.g. right after `git init && git remote add`) doesn't abort the script — it falls back and logs which base branch it picked.

`worktree-remove` refuses, without `--force`, to remove a worktree that has uncommitted changes or commits that exist nowhere else (no upstream, or ahead of it) — it prints exactly what would be lost. `worktree-gc`'s removal criteria (below) already guarantee this for GC: a worktree is only removed once its branch content is confirmed merged into the default branch, so there's nothing unpushed left to lose.

## The `.worktree/` hook contract

All optional. Create these at the repo root:

| File | Contract |
|---|---|
| `.worktree/post-create.sh` | Run after the worktree/workspace is created: `post-create.sh <worktree-path> <branch>`, cwd = the new worktree. Must be executable — an existing-but-non-executable hook is skipped with a warning telling you to `chmod +x` it, not silently. Install deps, fork a database, symlink shared caches — whatever the project needs before it's usable. If it exits non-zero, `worktree-new` stops and says so; the worktree exists but setup is incomplete. |
| `.worktree/pre-remove.sh` | Run before a worktree is removed (by `worktree-remove` or `worktree-gc`): `pre-remove.sh <worktree-path> <branch>`, cwd = the worktree if it's still readable. Must be executable. Drop a forked database, deregister a port, etc. Runs exactly once. A non-zero exit is handled differently by the two callers: `worktree-remove` prints the exit status and removes anyway (it's a deliberate, attended action); `worktree-gc` skips (keeps) that worktree and retries next run (GC runs unattended, so it never force-removes past a failed hook). |
| `.worktree/copy-files` | One repo-root-relative path per line (`#` comments and blank lines OK), typically `.env` / `.env.*` files gitignored from source control. Each listed file, if present at the repo root, is copied into the new worktree at the same relative path before hooks run. `worktree-new --no-copy-files` skips this. |
| `.worktree-keep` | One worktree directory basename per line. `worktree-gc` never removes anything listed here, however merged and idle it looks. |

See `examples/post-create-postgres.sh`, `examples/pre-remove-postgres.sh`, and `examples/post-create-node.sh` for hooks to copy and adapt — Postgres template-DB forking per worktree, dropping that fork, and installing Node deps with whichever lockfile is present.

## GC rules (`worktree-gc` / the weekly job)

A worktree is removed only when **all** hold:

1. Not the main worktree, and not listed in `.worktree-keep`.
2. `git status --porcelain` is completely empty (untracked files count).
3. Its branch content is already in the default branch — squash-merge aware (replays the branch tree as one commit on the merge base and checks `git cherry`, since a plain `--contains` misses squashed PRs). This also rules out "unpushed work": once content is confirmed upstream, there's nothing local-only left, whether or not the branch itself was ever pushed.
4. Nothing has touched it for `--idle-days` (default 3) — idle time is the newer of the branch tip's commit date and the git index's mtime, not directory mtime (builds/dev servers churn the directory constantly).

A worktree whose directory was deleted by hand (not via these scripts) is reported as "missing" by both `worktree-list` and `worktree-gc`; `worktree-gc --apply` prunes its stale git metadata (`git worktree prune`) and its branch then flows through the normal branch-sweep rules below.

A local branch is deleted separately and more loosely: not checked out anywhere, and either its tip is on some remote branch or its content is squash-merged into the default branch. Branch refs are cheap, so an unmerged branch survives its worktree being removed. Dry-run output names every branch it would delete, not just a count.

Removal renames the worktree into `.worktree-graveyard/` inside the repo root (instant, same filesystem) and unlinks it in the background — `rm -rf` on `node_modules`-sized trees is what makes the naive path slow. The GC lock lives in the git common dir (shared across worktrees), and a failed `git fetch` aborts the run rather than judging "merged" against a stale ref.

`worktree-gc-install` / `-uninstall` / `-log` manage a weekly (Mondays 09:30) `launchd` job — **macOS only**; on Linux they print a message pointing at cron or a systemd timer instead of failing. The installed job's label and log file are derived from the repo's directory name, so multiple projects on one machine don't collide.

## What will trip you up

- **`just worktree-gc` reports "0 to remove" while worktrees pile up.** They're dirty. It prints the reason next to each `keep` — a stray untracked file (build output, a stray IDE file) is the usual cause. Often this is `worktrees/` itself not being root-anchored in `.gitignore` — see the gitignore section above.
- **A worktree you're actively using gets listed for removal.** Its branch merged and there are no uncommitted changes. Add its directory basename to `.worktree-keep`.
- **No `.worktree/post-create.sh`** means a fresh worktree has no dependencies installed and no forked database — `worktree-new` only creates the checkout and copies `.worktree/copy-files`; everything else is the hook's job.
- **Hooks aren't found** because `worktrees.just` and the `.sh` scripts ended up in different directories after install, or the hook file isn't `chmod +x` — `worktree-new` now warns explicitly when `.worktree/post-create.sh` exists but isn't executable.
- **`worktree-remove` refuses to remove something you expected it to.** It's protecting uncommitted or unpushed work — the output lists exactly what would be lost. Pass `--force` if you're sure.
