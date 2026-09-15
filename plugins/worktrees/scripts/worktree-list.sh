#!/usr/bin/env bash
# List all worktrees/workspaces with branch and status.
#
# Usage: ./worktree-list.sh
#
# Shows each worktree with:
#   - Path and branch (or jj workspace name)
#   - Status: clean, or number of uncommitted/untracked changes
#   - Current worktree marked with *

set -euo pipefail

case "${1:-}" in --help|-h)
    echo "Usage: $0"
    echo ""
    echo "List all worktrees/workspaces with branch and status."
    echo ""
    echo "Output columns:"
    echo "  PATH     Worktree directory (* = current)"
    echo "  BRANCH   Git branch or jj workspace name"
    echo "  STATUS   'clean', the count of uncommitted/untracked changes, or 'missing' (directory deleted by hand)"
    exit 0
;; esac

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
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

status_display() {
    local wt_path=$1
    if [ ! -d "$wt_path" ]; then
        echo -e "${RED}missing${NC}"
        return
    fi
    local dirty
    dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dirty" = "0" ]; then
        echo -e "${DIM}clean${NC}"
    else
        echo -e "${YELLOW}${dirty} change(s)${NC}"
    fi
}

list_git_worktrees() {
    printf "  ${DIM}%-50s %-30s %-15s${NC}\n" "PATH" "BRANCH" "STATUS"
    printf "  ${DIM}%-50s %-30s %-15s${NC}\n" "----" "------" "------"

    local wt_path="" wt_branch=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt_path="${line#worktree }"
                ;;
            "branch "*)
                wt_branch="${line#branch refs/heads/}"
                ;;
            "")
                if [ -n "$wt_path" ]; then
                    local display_path
                    display_path="${wt_path/$HOME/~}"

                    local prefix="  "
                    if [ "$wt_path" = "$(pwd)" ]; then
                        prefix="${GREEN}* ${NC}"
                    fi

                    printf "${prefix}%-50s %-30s " "$display_path" "${wt_branch:-detached}"
                    printf "%b\n" "$(status_display "$wt_path")"
                fi
                wt_path=""
                wt_branch=""
                ;;
        esac
    done < <(git -C "$ROOT_DIR" worktree list --porcelain)
}

list_jj_workspaces() {
    printf "  ${DIM}%-50s %-30s %-15s${NC}\n" "PATH" "WORKSPACE" "STATUS"
    printf "  ${DIM}%-50s %-30s %-15s${NC}\n" "----" "---------" "------"

    # jj workspace list format: "<name>: <change_id> <commit_id> <description>"
    while IFS= read -r line; do
        local ws_name="${line%%:*}"

        local ws_path
        ws_path=$(cd "$ROOT_DIR" && jj workspace root --name "$ws_name" 2>/dev/null) || ws_path="$ROOT_DIR"

        local display_path
        display_path="${ws_path/$HOME/~}"

        local prefix="  "
        if [ "$(cd "$ws_path" 2>/dev/null && pwd)" = "$(pwd)" ]; then
            prefix="${GREEN}* ${NC}"
        fi

        printf "${prefix}%-50s %-30s " "$display_path" "$ws_name"
        printf "%b\n" "$(status_display "$ws_path")"
    done < <(cd "$ROOT_DIR" && jj workspace list 2>/dev/null)
}

main() {
    echo -e "${BOLD}Worktrees ($VCS)${NC}"
    echo ""

    if [ "$VCS" = "jj" ]; then
        list_jj_workspaces
    else
        list_git_worktrees
    fi

    echo ""
}

main
