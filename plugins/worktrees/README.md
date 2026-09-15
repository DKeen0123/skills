# worktrees

One isolated git worktree (or [jj](https://github.com/jj-vcs/jj) workspace) per branch, driven by a small `just` module, with a hook system for whatever project-specific setup a fresh worktree needs (installing dependencies, forking a database, copying secrets).

A Claude Code plugin. Install with:

```
/plugin install worktrees@dankeen
```

## Install into a project

```bash
mkdir -p scripts/worktrees
cp "${CLAUDE_PLUGIN_ROOT}/worktrees.just" scripts/worktrees/
cp "${CLAUDE_PLUGIN_ROOT}/scripts/"* scripts/worktrees/
chmod +x scripts/worktrees/*.sh
```

Then add one line to the project's root `justfile`:

```just
import 'scripts/worktrees/worktrees.just'
```

The scripts also run standalone, without `just`:

```bash
bash scripts/worktrees/worktree-new.sh feat/my-change
bash scripts/worktrees/worktree-remove.sh worktrees/feat-my-change
```

### gitignore

`scripts/worktrees/` collides with an unanchored `worktrees/` entry elsewhere
in `.gitignore` (it would also match the install directory itself). Use
root-anchored entries:

```gitignore
/worktrees/
/.worktree-graveyard/
/.worktree-keep
```

Anything a `.worktree/copy-files` hook copies into a worktree (`.env`, etc.)
must also be gitignored — otherwise every new worktree shows up dirty, and
`worktree-gc`'s clean-check never passes, so it never gets collected.
`worktree-new` prints a one-time warning if the worktree directory itself
isn't root-anchored in `.gitignore`.

### Configuration

| Var / just variable | Default | Effect |
|---|---|---|
| `WORKTREE_BASE_DIR` env var / `worktree_dir` just variable | `worktrees` | Directory new worktrees are created under, relative to the repo root |
| `WORKTREES_BASE_BRANCH` env var / `worktree_base_branch` just variable | auto (`origin/HEAD`, falling back to `main`/`master`) | Branch new worktrees are cut from, and what GC judges "merged" against |

## The three commands

```bash
just worktree-new feat/my-change   # create a worktree + branch, run hooks
just worktree-list                 # path, branch, dirty/clean status
just worktree-remove <path>        # run pre-remove hook, then remove
```

Plus cleanup:

```bash
just worktree-gc            # dry run — what merged+idle+clean worktrees would go
just worktree-gc-apply      # actually remove them
just worktree-gc-install    # weekly launchd job (macOS); prints a note elsewhere
```

## The hook contract

Create these at the repo root, all optional:

- **`.worktree/post-create.sh <worktree-path> <branch>`** — runs after a worktree is created, cwd set to it. Install deps, fork a database, symlink caches.
- **`.worktree/pre-remove.sh <worktree-path> <branch>`** — runs before a worktree is removed. Drop a forked database, etc.
- **`.worktree/copy-files`** — one repo-root-relative path per line; each is copied into new worktrees before hooks run. For gitignored `.env` files.
- **`.worktree-keep`** — one worktree directory basename per line; `worktree-gc` never touches these.

See `examples/` for ready-to-copy hooks: forking and dropping a Postgres database per worktree, and installing Node dependencies with whichever package manager's lockfile is present.

Full reference, including the GC merge/idle rules: `skills/worktrees/SKILL.md`.

## License

MIT
