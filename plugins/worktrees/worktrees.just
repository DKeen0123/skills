# One isolated git worktree (or jj workspace) per branch.
#
# Import this into a project's root justfile:
#   import 'scripts/worktrees/worktrees.just'
#
# Recipes call the scripts next to this file via `source_directory()`, not
# `justfile_directory()` — the latter resolves to the *importing* justfile's
# directory (the repo root), since this module is installed and imported from
# a subdirectory (scripts/worktrees/). `source_directory()` stays pinned to
# wherever this module itself lives. The scripts then resolve the actual repo
# root themselves (via the shared git dir), so recipes work the same whether
# they're run from the main checkout or from inside a linked worktree.
#
# See skills/worktrees/SKILL.md for the .worktree/ hook contract.

# Shebang recipes receive their just-recipe args as real shell positional
# params ($1, $2, ... / "$@") instead of text-interpolated {{ARGS}} — required
# so an argument containing a space (a quoted branch name, a path) survives
# intact instead of being word-split.
set positional-arguments := true

# Directory new worktrees are created under, relative to the repo root.
worktree_dir := env_var_or_default("WORKTREE_BASE_DIR", "worktrees")

# Branch new worktrees and judge "merged" against this branch. Empty = auto
# (origin/HEAD, falling back to main).
worktree_base_branch := env_var_or_default("WORKTREES_BASE_BRANCH", "")

# Pass-through args (not separate params) so flags like --no-hooks can follow the name:
# `just worktree-new feat/foo --no-hooks`.
# Create a new worktree/workspace. E.g. `just worktree-new feat/foo`. Run from anywhere in the repo.
worktree-new *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    export WORKTREE_BASE_DIR={{quote(worktree_dir)}}
    export WORKTREES_BASE_BRANCH={{quote(worktree_base_branch)}}
    exec {{quote(source_directory())}}/worktree-new.sh "$@"

# List all worktrees/workspaces with branch and status.
worktree-list:
    @{{quote(source_directory())}}/worktree-list.sh

# Remove a worktree and run its pre-remove hook. E.g. `just worktree-remove worktrees/feat-foo --force`. Omit args for the interactive picker.
worktree-remove *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    exec {{quote(source_directory())}}/worktree-remove.sh "$@"

# Report merged, idle, clean worktrees + dead branches that GC would remove (no changes)
worktree-gc *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    export WORKTREES_BASE_BRANCH={{quote(worktree_base_branch)}}
    exec {{quote(source_directory())}}/worktree-gc.sh "$@"

# Actually remove them. Same rules as the scheduled job.
worktree-gc-apply *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    export WORKTREES_BASE_BRANCH={{quote(worktree_base_branch)}}
    exec {{quote(source_directory())}}/worktree-gc.sh --apply "$@"

# Install the weekly launchd job (Mondays 09:30) that runs worktree-gc --apply. macOS only.
worktree-gc-install:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" != "Darwin" ]; then
        echo "worktree-gc-install: launchd is macOS-only."
        echo "On Linux, schedule 'just worktree-gc-apply' with cron or a systemd timer instead."
        exit 0
    fi
    SCRIPT_DIR={{quote(source_directory())}}
    ROOT="$(cd "$SCRIPT_DIR" && dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
    REPO_NAME="$(basename "$ROOT")"
    REPO_NAME="${REPO_NAME//[^a-zA-Z0-9]/-}"
    LABEL="local.worktree-gc.$REPO_NAME"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    LOG="$HOME/Library/Logs/worktree-gc-$REPO_NAME.log"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    command -v git >/dev/null || echo "warning: git not on PATH — the job may fail"
    sed -e "s|__LABEL__|$LABEL|g" \
        -e "s|__ROOT_DIR__|$ROOT|g" \
        -e "s|__SCRIPT__|$SCRIPT_DIR/worktree-gc.sh|g" \
        -e "s|__LOG_PATH__|$LOG|g" \
        -e "s|__PATH__|$PATH|g" \
        "$SCRIPT_DIR/worktree-gc.plist.template" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed: $PLIST"
    echo "Runs Mondays 09:30 against $ROOT"
    echo "Log: $LOG  ('just worktree-gc-log')"

# Remove the weekly launchd job
worktree-gc-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" != "Darwin" ]; then
        echo "worktree-gc-uninstall: launchd is macOS-only — nothing to remove."
        exit 0
    fi
    SCRIPT_DIR={{quote(source_directory())}}
    ROOT="$(cd "$SCRIPT_DIR" && dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
    REPO_NAME="$(basename "$ROOT")"
    REPO_NAME="${REPO_NAME//[^a-zA-Z0-9]/-}"
    LABEL="local.worktree-gc.$REPO_NAME"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
    echo "Uninstalled the weekly worktree GC job ($LABEL)"

# Tail the weekly GC log
worktree-gc-log:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" != "Darwin" ]; then
        echo "worktree-gc-log: launchd is macOS-only — no log to tail."
        exit 0
    fi
    SCRIPT_DIR={{quote(source_directory())}}
    ROOT="$(cd "$SCRIPT_DIR" && dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")"
    REPO_NAME="$(basename "$ROOT")"
    REPO_NAME="${REPO_NAME//[^a-zA-Z0-9]/-}"
    LOG="$HOME/Library/Logs/worktree-gc-$REPO_NAME.log"
    tail -50 "$LOG" 2>/dev/null || echo "No log yet — the job has not run."
