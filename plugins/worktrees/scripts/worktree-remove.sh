#!/usr/bin/env bash
# Remove a worktree/workspace, running its pre-remove hook first.
#
# Supports both git worktrees and jj workspaces (auto-detected).
#
# Usage:
#   ./worktree-remove.sh <path>          Remove specific worktree/workspace
#   ./worktree-remove.sh <path> --force  Skip the uncommitted/unpushed-work guard
#   ./worktree-remove.sh                 Interactive mode (shows picker)
#
# What it does:
#   1. Refuses to proceed (without --force) if the worktree has uncommitted
#      changes or commits that exist nowhere else (no upstream, or commits
#      ahead of it) — see check_safe_to_remove.
#   2. Runs .worktree/pre-remove.sh <worktree-path> <branch>, if present and
#      executable — this is where a project drops its forked database, etc.
#      If the hook exits non-zero, its status is printed but removal
#      continues anyway (unlike worktree-gc.sh, which skips the worktree).
#   3. Removes the git worktree / jj workspace
#
# Runs standalone too, no `just` required: bash scripts/worktrees/worktree-remove.sh <path>
#
# For AI agents: pass the path directly for non-interactive use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[worktree]${NC} $1"; }
log_error() { echo -e "${RED}[worktree]${NC} $1"; }

show_help() {
    echo "Usage: $0 [options] [path]"
    echo ""
    echo "Remove a worktree/workspace, running its pre-remove hook first."
    echo ""
    echo "Arguments:"
    echo "  path         Path to worktree to remove (interactive picker if omitted)"
    echo ""
    echo "Options:"
    echo "  --force      Skip the uncommitted/unpushed-work guard"
    echo "  --help, -h   Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 worktrees/feat-user-auth           # Remove specific worktree"
    echo "  $0 worktrees/feat-user-auth --force   # ...even with unpushed work"
    echo "  $0                                    # Interactive picker"
}

is_interactive() { [ -t 0 ] && [ -t 1 ]; }

prompt_yn() {
    local prompt_text=$1
    local default=${2:-n}

    if is_interactive; then
        local yn_hint="y/N"
        [ "$default" = "y" ] && yn_hint="Y/n"
        read -r -p "$(echo -e "${BLUE}>${NC} ${prompt_text} (${yn_hint}): ")" -n 1 REPLY
        echo
        if [ "$default" = "y" ]; then
            [[ ! $REPLY =~ ^[Nn]$ ]]
        else
            [[ $REPLY =~ ^[Yy]$ ]]
        fi
    else
        [ "$default" = "y" ]
    fi
}

# Run .worktree/pre-remove.sh <worktree-path> <branch> exactly once, if
# present and executable. Prints the exit status on failure but the caller
# always proceeds with removal — unlike worktree-gc.sh, an explicit
# worktree-remove is a deliberate action the operator should be able to
# finish even if the hook (e.g. a DB drop) failed.
run_pre_remove_hook() {
    local wt_path=$1 branch=$2
    local hook="$ROOT_DIR/.worktree/pre-remove.sh"
    [ -x "$hook" ] || return 0

    log_info "Running .worktree/pre-remove.sh..."
    local status=0
    if [ -d "$wt_path" ]; then
        ( cd "$wt_path" && "$hook" "$wt_path" "$branch" ) || status=$?
    else
        "$hook" "$wt_path" "$branch" || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        log_error "  .worktree/pre-remove.sh exited $status — continuing with removal anyway"
    fi
}

# Refuse to silently discard work. Non-interactive removal (the common case
# for an agent, or worktree-gc) must not destroy uncommitted changes or
# commits that exist nowhere else. --force overrides.
check_safe_to_remove() {
    local wt_path="$1"

    $FORCE && return 0
    [ "$VCS" = "jj" ] && return 0  # jj workspaces don't own commits the way a git worktree's branch can.

    local lost=()

    local dirty
    dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
        lost+=("uncommitted changes:")
        while IFS= read -r line; do lost+=("    $line"); done <<< "$dirty"
    fi

    local upstream
    if upstream="$(git -C "$wt_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" && [ -n "$upstream" ]; then
        local unpushed
        unpushed="$(git -C "$wt_path" log --oneline "@{u}..HEAD" 2>/dev/null || true)"
        if [ -n "$unpushed" ]; then
            lost+=("commits not on $upstream:")
            while IFS= read -r line; do lost+=("    $line"); done <<< "$unpushed"
        fi
    else
        # No upstream at all — the branch may exist only in this worktree.
        # Compare against the detected default branch as a best-effort check.
        local base
        base="${WORKTREES_BASE_BRANCH:-}"
        if [ -z "$base" ]; then
            base="$(git -C "$wt_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
        fi
        base="${base:-main}"
        if git -C "$wt_path" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
            local ahead
            ahead="$(git -C "$wt_path" log --oneline "origin/$base..HEAD" 2>/dev/null || true)"
            if [ -n "$ahead" ]; then
                lost+=("no upstream tracking branch, and commits not on origin/$base:")
                while IFS= read -r line; do lost+=("    $line"); done <<< "$ahead"
            fi
        fi
    fi

    [ "${#lost[@]}" -eq 0 ] && return 0

    log_error "Refusing to remove — this would lose:"
    for line in "${lost[@]}"; do echo -e "  $line" >&2; done
    log_error "Re-run with --force to remove anyway."
    return 1
}

get_jj_workspace_name() {
    local target_path="$1"
    (cd "$ROOT_DIR" && jj workspace list 2>/dev/null) | while IFS= read -r line; do
        local ws_name="${line%%:*}"
        local ws_path
        ws_path=$(cd "$ROOT_DIR" && jj workspace root --name "$ws_name" 2>/dev/null) || ws_path="$ROOT_DIR"
        if [ "$ws_path" = "$target_path" ]; then
            echo "$ws_name"
            return
        fi
    done
}

interactive_pick_git() {
    echo -e "  ${DIM}Available worktrees:${NC}"
    local i=0
    local paths=()
    while IFS= read -r line; do
        local wt_path
        wt_path=$(echo "$line" | awk '{print $1}')
        local wt_branch
        wt_branch=$(echo "$line" | awk '{print $3}' | tr -d '[]')

        if [ "$wt_path" = "$ROOT_DIR" ]; then
            continue
        fi

        i=$((i + 1))
        paths+=("$wt_path")
        local display_path
        display_path="${wt_path/$HOME/~}"
        echo -e "  ${BOLD}$i)${NC} $display_path ${DIM}($wt_branch)${NC}"
    done < <(git -C "$ROOT_DIR" worktree list)

    if [ $i -eq 0 ]; then
        log_info "No additional worktrees found"
        exit 0
    fi

    echo ""
    read -r -p "$(echo -e "${BLUE}>${NC} Select worktree to remove (1-$i): ")" selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$i" ]; then
        log_error "Invalid selection"
        exit 1
    fi

    WORKTREE_PATH="${paths[$((selection - 1))]}"
}

interactive_pick_jj() {
    echo -e "  ${DIM}Available workspaces:${NC}"
    local i=0
    local paths=()
    while IFS= read -r line; do
        local ws_name="${line%%:*}"

        if [ "$ws_name" = "default" ]; then
            continue
        fi

        local ws_path
        ws_path=$(cd "$ROOT_DIR" && jj workspace root --name "$ws_name" 2>/dev/null) || continue

        i=$((i + 1))
        paths+=("$ws_path")
        local display_path
        display_path="${ws_path/$HOME/~}"
        echo -e "  ${BOLD}$i)${NC} $display_path ${DIM}($ws_name)${NC}"
    done < <(cd "$ROOT_DIR" && jj workspace list 2>/dev/null)

    if [ $i -eq 0 ]; then
        log_info "No additional workspaces found"
        exit 0
    fi

    echo ""
    read -r -p "$(echo -e "${BLUE}>${NC} Select workspace to remove (1-$i): ")" selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$i" ]; then
        log_error "Invalid selection"
        exit 1
    fi

    WORKTREE_PATH="${paths[$((selection - 1))]}"
}

# Parse arguments: a bare positional is the path, --force / --help work
# alongside it in any order.
FORCE=false
WORKTREE_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --help|-h) show_help; exit 0 ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [ -z "$WORKTREE_PATH" ]; then
                WORKTREE_PATH="$1"
            fi
            shift
            ;;
    esac
done

main() {
    echo -e "${BOLD}Remove Worktree ($VCS)${NC}"
    echo ""

    if [ -z "$WORKTREE_PATH" ]; then
        if ! is_interactive; then
            log_error "Path required. Usage: $0 <path>"
            exit 1
        fi

        if [ "$VCS" = "jj" ]; then
            interactive_pick_jj
        else
            interactive_pick_git
        fi
    fi

    # Resolve relative paths against the repo root, not the caller's cwd —
    # matches worktree-new.sh, and makes `worktree-remove worktrees/foo` work
    # the same from inside any worktree.
    if [[ "$WORKTREE_PATH" != /* ]]; then
        WORKTREE_PATH="$ROOT_DIR/$WORKTREE_PATH"
    fi
    WORKTREE_PATH="$(cd "$WORKTREE_PATH" 2>/dev/null && pwd || echo "$WORKTREE_PATH")"

    if [ "$WORKTREE_PATH" = "$ROOT_DIR" ]; then
        log_error "Cannot remove the main worktree"
        exit 1
    fi

    local ws_name=""
    if [ "$VCS" = "jj" ]; then
        ws_name=$(get_jj_workspace_name "$WORKTREE_PATH")
        if [ -z "$ws_name" ]; then
            log_error "Not a jj workspace: $WORKTREE_PATH"
            exit 1
        fi
    else
        if ! git -C "$ROOT_DIR" worktree list | grep -q "^$WORKTREE_PATH "; then
            log_error "Not a worktree: $WORKTREE_PATH"
            exit 1
        fi
    fi

    local display_path
    display_path="${WORKTREE_PATH/$HOME/~}"
    log_info "Will remove:"
    if [ "$VCS" = "jj" ]; then
        log_info "  Workspace: $display_path ($ws_name)"
    else
        log_info "  Worktree: $display_path"
    fi
    echo ""

    check_safe_to_remove "$WORKTREE_PATH" || exit 1

    if is_interactive; then
        if ! prompt_yn "Proceed?"; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    local branch
    branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$ws_name")
    run_pre_remove_hook "$WORKTREE_PATH" "$branch"

    if [ "$VCS" = "jj" ]; then
        log_info "Forgetting jj workspace: $ws_name"
        (cd "$ROOT_DIR" && jj workspace forget "$ws_name")
        log_info "Removing directory: $WORKTREE_PATH"
        rm -rf "$WORKTREE_PATH"
    else
        log_info "Removing worktree..."
        git -C "$ROOT_DIR" worktree remove "$WORKTREE_PATH" --force
    fi

    echo ""
    log_info "Done!"
}

main
