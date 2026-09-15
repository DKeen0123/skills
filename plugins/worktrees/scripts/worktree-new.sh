#!/usr/bin/env bash
# Create a new worktree/workspace, run its post-create hook, and copy env files.
#
# Supports both git worktrees and jj workspaces (auto-detected).
#
# Usage (git):
#   ./worktree-new.sh <branch>              # Auto-generates path
#   ./worktree-new.sh <branch> <path>       # Custom path
#   ./worktree-new.sh <branch> --no-hooks   # Skip .worktree/post-create.sh
#   ./worktree-new.sh <branch> --no-copy-files  # Skip .worktree/copy-files
#
# Usage (jj):
#   ./worktree-new.sh <name>                # Workspace at <worktree-dir>/<name>
#   ./worktree-new.sh <name> <path>         # Custom path
#   ./worktree-new.sh                       # Interactive mode
#
# What it does:
#   1. Creates a git worktree / jj workspace at <worktree-dir>/<name> (or a
#      custom path), branching new branches off the detected default branch
#   2. Copies every path listed in .worktree/copy-files (repo-root-relative,
#      typically .env / .env.* files), if that list file exists
#   3. Runs .worktree/post-create.sh <worktree-path> <branch>, if present and
#      executable — this is where a project forks its own database, installs
#      dependencies, symlinks caches, etc.
#
# Env vars:
#   WORKTREE_BASE_DIR   Directory new worktrees are created under (default: worktrees)
#   WORKTREES_BASE_BRANCH  Override the auto-detected default branch to branch new work from
#
# Runs standalone too, no `just` required: bash scripts/worktrees/worktree-new.sh <branch>
#
# For AI agents: pass name directly for non-interactive use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the repo root robustly, even when invoked from inside a linked
# worktree (git-common-dir is shared across all worktrees; its parent is the
# main checkout). Falls back to walking up for .jj when there's no .git at all.
resolve_root_dir() {
    local dir="$1" common
    if common="$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$common" ]; then
        dirname "$common"
        return 0
    fi
    local rel
    if rel="$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$rel" ]; then
        (cd "$dir" && cd "$rel/.." && pwd)
        return 0
    fi
    local d="$dir"
    while [ "$d" != "/" ]; do
        [ -d "$d/.jj" ] && { echo "$d"; return 0; }
        d="$(dirname "$d")"
    done
    return 1
}

ROOT_DIR="$(resolve_root_dir "$SCRIPT_DIR")"

if [ -d "$ROOT_DIR/.jj" ]; then
    VCS="jj"
else
    VCS="git"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[worktree]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[worktree]${NC} $1"; }
log_error() { echo -e "${RED}[worktree]${NC} $1"; }

is_interactive() { [ -t 0 ] && [ -t 1 ]; }

prompt() {
    local var_name=$1
    local prompt_text=$2
    local default=${3:-}

    if is_interactive; then
        if [ -n "$default" ]; then
            read -r -p "$(echo -e "${BLUE}>${NC} ${prompt_text} [${default}]: ")" value
            printf -v "$var_name" '%s' "${value:-$default}"
        else
            read -r -p "$(echo -e "${BLUE}>${NC} ${prompt_text}: ")" value
            printf -v "$var_name" '%s' "$value"
        fi
    else
        printf -v "$var_name" '%s' "$default"
    fi
}

# Warn once if the project's .gitignore has no root-anchored entry for the
# worktree base dir — otherwise every new worktree shows as untracked content
# in the main checkout, and worktree-gc's "git status --porcelain is empty"
# clean-check never passes, so nothing is ever collected.
check_gitignore() {
    local base_dir="$1" want gitignore
    want="/${base_dir%/}"
    gitignore="$ROOT_DIR/.gitignore"
    if [ -f "$gitignore" ] && { grep -qxF -- "$want" "$gitignore" || grep -qxF -- "$want/" "$gitignore"; }; then
        return 0
    fi
    log_warn "No root-anchored .gitignore entry for '$want/' — worktrees may show as untracked, and worktree-gc will never see them as clean. Add '$want/' to .gitignore."
}

# Parse arguments
NAME=""
WORKTREE_PATH=""
RUN_HOOKS=true
DO_COPY_FILES=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-hooks) RUN_HOOKS=false; shift ;;
        --no-copy-files) DO_COPY_FILES=false; shift ;;
        --help|-h)
            echo "Usage: $0 [options] [name] [path]"
            echo ""
            echo "Supports git worktrees and jj workspaces (auto-detected)."
            echo "Detected VCS: $VCS"
            echo ""
            echo "Options:"
            echo "  --no-hooks       Skip .worktree/post-create.sh"
            echo "  --no-copy-files  Skip copying .worktree/copy-files"
            echo "  --help           Show this help"
            echo ""
            if [ "$VCS" = "jj" ]; then
                echo "Examples (jj):"
                echo "  $0 my-feature"
                echo "  $0 my-feature worktrees/custom-path"
            else
                echo "Examples (git):"
                echo "  $0 feat/user-auth"
                echo "  $0 feat/user-auth worktrees/my-worktree"
            fi
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$NAME" ]; then
                NAME="$1"
            elif [ -z "$WORKTREE_PATH" ]; then
                WORKTREE_PATH="$1"
            fi
            shift
            ;;
    esac
done

main() {
    echo -e "${BOLD}Create New Worktree ($VCS)${NC}"
    echo ""

    if [ -z "$NAME" ]; then
        if is_interactive; then
            if [ "$VCS" = "jj" ]; then
                echo -e "${BLUE}>${NC} Existing workspaces:"
                jj workspace list 2>/dev/null | sed 's/^/  /'
                echo ""
                prompt NAME "Workspace name"
            else
                echo -e "${BLUE}>${NC} Available recent branches:"
                git -C "$ROOT_DIR" branch --sort=-committerdate --format='  %(refname:short)' | head -10
                echo ""
                prompt NAME "Branch name (existing or new)"
            fi
        else
            log_error "Name required. Usage: $0 <name>"
            exit 1
        fi
    fi

    if [ -z "$NAME" ]; then
        log_error "Name cannot be empty"
        exit 1
    fi

    local worktree_base_dir="${WORKTREE_BASE_DIR:-worktrees}"
    check_gitignore "$worktree_base_dir"

    if [ -z "$WORKTREE_PATH" ]; then
        # Convert name to directory: feat/user-auth -> feat-user-auth
        local dir_name
        dir_name="$(echo "$NAME" | sed 's/[\/:]/-/g')"
        WORKTREE_PATH="$ROOT_DIR/$worktree_base_dir/$dir_name"

        if is_interactive; then
            prompt WORKTREE_PATH "Worktree path" "$WORKTREE_PATH"
        fi
    elif [[ "$WORKTREE_PATH" != /* ]]; then
        WORKTREE_PATH="$ROOT_DIR/$WORKTREE_PATH"
    fi

    mkdir -p "$(dirname "$WORKTREE_PATH")"

    # Reject a path that escapes the repo root (e.g. an explicit "../../etc"),
    # normalizing via the parent directory since WORKTREE_PATH itself doesn't
    # exist yet.
    local resolved_parent resolved_full
    resolved_parent="$(cd "$(dirname "$WORKTREE_PATH")" && pwd)"
    resolved_full="$resolved_parent/$(basename "$WORKTREE_PATH")"
    case "$resolved_full" in
        "$ROOT_DIR"/*) ;;
        *)
            log_error "Worktree path must be inside the repo root ($ROOT_DIR): $WORKTREE_PATH"
            exit 1
            ;;
    esac
    WORKTREE_PATH="$resolved_full"

    if [ -e "$WORKTREE_PATH" ]; then
        log_error "Path already exists: $WORKTREE_PATH"
        exit 1
    fi

    echo ""
    log_info "Creating worktree:"
    if [ "$VCS" = "jj" ]; then
        log_info "  Workspace: $NAME"
    else
        log_info "  Branch: $NAME"
    fi
    log_info "  Path:   $WORKTREE_PATH"
    log_info "  VCS:    $VCS"
    log_info "  Hooks:  $( $RUN_HOOKS && echo "yes" || echo "skip" )"
    echo ""

    if [ "$VCS" = "jj" ]; then
        log_info "Creating jj workspace: $NAME"
        (cd "$ROOT_DIR" && jj workspace add --name "$NAME" "$WORKTREE_PATH")
    else
        # Base new branches on freshly fetched origin/<default>, not whatever
        # happens to be checked out in the main repo — a stale local default
        # branch produces PRs born with conflicts.
        local default_branch="${WORKTREES_BASE_BRANCH:-}"
        if [ -z "$default_branch" ]; then
            # `|| true`: under pipefail, a failed symbolic-ref (origin/HEAD
            # unset, e.g. right after `git init && git remote add`) would
            # otherwise abort the whole script here.
            default_branch="$(git -C "$ROOT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
            if [ -z "$default_branch" ]; then
                if git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
                    default_branch="main"
                elif git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
                    default_branch="master"
                else
                    default_branch="main"
                fi
                log_warn "origin/HEAD not set — using detected base branch: $default_branch"
            fi
        fi

        local base_ref=""
        log_info "Fetching origin/$default_branch..."
        if git -C "$ROOT_DIR" fetch origin "$default_branch" 2>/dev/null; then
            base_ref="origin/$default_branch"
        else
            log_warn "Could not fetch origin/$default_branch — branching from current HEAD"
        fi

        local branch_exists=false
        if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$NAME" 2>/dev/null; then
            branch_exists=true
        elif git -C "$ROOT_DIR" show-ref --verify --quiet "refs/remotes/origin/$NAME" 2>/dev/null; then
            branch_exists=true
        fi

        if $branch_exists; then
            log_info "Creating worktree from existing branch: $NAME"
            git -C "$ROOT_DIR" worktree add "$WORKTREE_PATH" "$NAME"
        elif [ -n "$base_ref" ]; then
            log_info "Creating worktree with new branch: $NAME (from $base_ref)"
            git -C "$ROOT_DIR" worktree add --no-track -b "$NAME" "$WORKTREE_PATH" "$base_ref"
        else
            log_info "Creating worktree with new branch: $NAME"
            git -C "$ROOT_DIR" worktree add -b "$NAME" "$WORKTREE_PATH"
        fi
    fi

    if $DO_COPY_FILES; then
        local list_file="$ROOT_DIR/.worktree/copy-files"
        if [ -f "$list_file" ]; then
            while IFS= read -r rel || [ -n "$rel" ]; do
                rel="$(echo "$rel" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                [ -z "$rel" ] && continue
                case "$rel" in \#*) continue ;; esac
                local src="$ROOT_DIR/$rel"
                local dst="$WORKTREE_PATH/$rel"
                if [ -f "$src" ]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst"
                    log_info "Copied $rel"
                else
                    log_warn "Listed in .worktree/copy-files but not found: $rel"
                fi
            done < "$list_file"
        fi
    fi

    if $RUN_HOOKS; then
        local hook="$ROOT_DIR/.worktree/post-create.sh"
        if [ -f "$hook" ] && [ ! -x "$hook" ]; then
            log_warn ".worktree/post-create.sh exists but is not executable — skipping. Run: chmod +x .worktree/post-create.sh"
        elif [ -x "$hook" ]; then
            log_info "Running .worktree/post-create.sh..."
            if ! (cd "$WORKTREE_PATH" && "$hook" "$WORKTREE_PATH" "$NAME"); then
                log_error "post-create hook failed — worktree was created at $WORKTREE_PATH but setup is incomplete"
                exit 1
            fi
        fi
    fi

    echo ""
    log_info "Worktree ready!"
    echo ""
    echo -e "  ${BOLD}cd $WORKTREE_PATH${NC}"
    echo ""
}

main
