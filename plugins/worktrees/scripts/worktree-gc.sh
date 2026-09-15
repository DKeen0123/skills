#!/usr/bin/env bash
# Garbage-collect merged worktrees and dead local branches.
#
# Usage:
#   ./worktree-gc.sh                 Dry run — report what would go (default)
#   ./worktree-gc.sh --apply         Actually remove
#   ./worktree-gc.sh --idle-days 7   Override the idle threshold (default 3)
#   ./worktree-gc.sh --base main     Override the detected default branch
#   ./worktree-gc.sh --no-branches   Skip the local-branch sweep
#
# A worktree is removed only when ALL of these hold:
#   1. It is not the main worktree, and not pinned in .worktree-keep
#   2. `git status --porcelain` is completely empty
#   3. Its branch content is already in the default branch (squash-merge aware)
#   4. Nothing has touched it for --idle-days days
# Point 3 also covers "no unpushed work": if the branch's content already
# exists in the default branch, there is nothing local-only left to lose,
# even if the branch itself was never pushed.
#
# Before removal, .worktree/pre-remove.sh <worktree-path> <branch> runs if
# present and executable — this is where a project drops its forked database.
# Unlike worktree-remove.sh, a worktree whose hook fails here is *skipped*
# (kept, to retry next run), not force-removed anyway — GC runs unattended.
#
# A worktree directory that was deleted by hand (not via these scripts) shows
# up here as "missing"; --apply prunes its stale git metadata and then lets
# its branch flow through the normal branch-sweep rules below.
#
# A local branch is deleted only when it is not checked out anywhere AND either
# its tip is on a remote branch, or its content is squash-merged into the
# default branch.
#
# Removal is fast: the directory is renamed into a graveyard inside the repo
# root (same volume, so the rename is instant), and the files are unlinked in
# parallel in the background. `rm -rf` on node_modules/similar is what makes
# the naive path slow.
#
# Runs standalone too, no `just` required: bash scripts/worktrees/worktree-gc.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always operate on the main worktree, even when invoked from a linked one:
# the git common dir is shared, and its parent is the main checkout.
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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
# launchd/cron have no TTY — drop the escapes so the log file stays readable.
if [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; NC=''; fi

log_info()  { echo -e "${GREEN}[gc]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[gc]${NC} $1"; }
log_error() { echo -e "${RED}[gc]${NC} $1"; }

# stat takes different flags on BSD (macOS) and GNU (Linux); BSD rejects -c.
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

IDLE_DAYS=3
APPLY=false
DO_BRANCHES=true
BASE_BRANCH="${WORKTREES_BASE_BRANCH:-}"

show_help() {
    sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --idle-days)
            if [ $# -lt 2 ]; then
                log_error "--idle-days requires a value"
                exit 2
            fi
            case "$2" in
                ''|*[!0-9]*)
                    log_error "--idle-days expects a non-negative integer, got '$2'"
                    exit 2
                    ;;
            esac
            IDLE_DAYS="$2"; shift 2 ;;
        --base)
            if [ $# -lt 2 ]; then
                log_error "--base requires a value"
                exit 2
            fi
            BASE_BRANCH="$2"; shift 2 ;;
        --no-branches) DO_BRANCHES=false; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$BASE_BRANCH" ]; then
    # `|| true`: under pipefail, a failed symbolic-ref (origin/HEAD unset,
    # e.g. right after `git init && git remote add`) would otherwise abort
    # the whole script here.
    BASE_BRANCH="$(git -C "$ROOT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    if [ -z "$BASE_BRANCH" ]; then
        if git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
            BASE_BRANCH="main"
        elif git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
            BASE_BRANCH="master"
        else
            BASE_BRANCH="main"
        fi
        log_warn "origin/HEAD not set — using detected base branch: $BASE_BRANCH"
    fi
fi
BASE_REF="origin/$BASE_BRANCH"

cd "$ROOT_DIR"

# Only one GC at a time. A stale lock from a killed run is cleared after 2h.
# Lives in the common dir because .git is a file, not a directory, in a linked worktree.
GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$ROOT_DIR/.git")"
LOCK_DIR="$GIT_COMMON_DIR/worktree-gc.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(file_mtime "$LOCK_DIR") ))
    if [ "$lock_age" -lt 7200 ]; then
        log_error "Another worktree-gc is running (lock: $LOCK_DIR). Exiting."
        exit 0
    fi
    log_warn "Clearing stale lock (${lock_age}s old)"
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo -e "${BOLD}Worktree GC${NC} $($APPLY && echo "(APPLY)" || echo "(dry run — pass --apply to remove)")"
echo -e "${DIM}base=$BASE_REF  idle-days=$IDLE_DAYS  branches=$DO_BRANCHES${NC}"
echo ""

# Deciding "merged" against a stale base ref would delete unmerged work.
if ! git fetch --prune --quiet origin 2>/dev/null; then
    log_error "git fetch failed — refusing to judge merge status on stale refs."
    exit 1
fi
git rev-parse --verify --quiet "$BASE_REF" >/dev/null || { log_error "$BASE_REF not found"; exit 1; }

# Worktrees named in .worktree-keep (one basename per line, # comments allowed)
# are never touched, however merged and idle they look.
KEEP_FILE="$ROOT_DIR/.worktree-keep"
is_pinned() {
    [ -f "$KEEP_FILE" ] || return 1
    grep -v '^[[:space:]]*#' "$KEEP_FILE" 2>/dev/null \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -qxF -- "$1"
}

# True when ref adds no content to $BASE_REF. Handles squash merges: replay the
# branch's tree as one commit on the merge base and ask whether that patch is
# already upstream. A plain --contains misses squashes, which is most PRs.
is_merged() {
    local ref=$1 mb tree dangle
    [ "$(git rev-list --count "$BASE_REF..$ref" 2>/dev/null || echo 1)" = "0" ] && return 0
    mb=$(git merge-base "$BASE_REF" "$ref" 2>/dev/null) || return 1
    tree=$(git rev-parse "$ref^{tree}" 2>/dev/null) || return 1
    dangle=$(git commit-tree "$tree" -p "$mb" -m _ 2>/dev/null) || return 1
    [ "$(git cherry "$BASE_REF" "$dangle" 2>/dev/null | cut -c1)" = "-" ]
}

# Seconds since this worktree was last worked in: the newer of its branch tip and
# its index mtime. The index is touched by checkout/add/status, so it tracks real
# use; directory mtime does not, because builds and dev servers churn it.
idle_seconds() {
    local wt=$1 tip_ts idx idx_ts now
    now=$(date +%s)
    tip_ts=$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)
    # --git-path returns a path relative to the worktree, so resolve it there.
    idx=$(cd "$wt" && git rev-parse --git-path index 2>/dev/null || echo "")
    idx_ts=0
    if [ -n "$idx" ]; then
        case "$idx" in /*) ;; *) idx="$wt/$idx" ;; esac
        [ -f "$idx" ] && idx_ts=$(file_mtime "$idx")
    fi
    local newest=$tip_ts
    [ "$idx_ts" -gt "$newest" ] && newest=$idx_ts
    echo $(( now - newest ))
}

# .worktree/pre-remove.sh <worktree-path> <branch>, run exactly once. Returns
# the hook's own exit status so the caller can decide whether to skip removal.
run_pre_remove_hook() {
    local wt_path=$1 branch=$2
    local hook="$ROOT_DIR/.worktree/pre-remove.sh"
    [ -x "$hook" ] || return 0
    log_info "  running .worktree/pre-remove.sh"
    if [ -d "$wt_path" ]; then
        ( cd "$wt_path" && "$hook" "$wt_path" "$branch" )
    else
        "$hook" "$wt_path" "$branch"
    fi
}

IDLE_SECS=$(( IDLE_DAYS * 86400 ))
# Inside the repo root (never beside it, never TMPDIR): the rename is only
# instant within one filesystem, and a checkout on an external or second
# volume would silently degrade to a copy.
GRAVEYARD="$ROOT_DIR/.worktree-graveyard"

removed=0; kept=0
declare -a TO_REMOVE=()
declare -a MISSING=()

# --porcelain, not the human listing: a worktree path may contain spaces, and
# splitting the plain output on whitespace truncates it.
while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ "$wt" = "$ROOT_DIR" ] && continue
    name=$(basename "$wt")

    # Hand-deleted worktree directory: git still has metadata for it, but
    # there's nothing here to check status/merge/idle on. Flag it for
    # pruning; its branch then flows through the normal branch-sweep rules
    # below (once pruned, it's no longer "checked out" anywhere).
    if [ ! -d "$wt" ]; then
        echo -e "  ${YELLOW}missing${NC} $name ${DIM}(directory gone — will prune)${NC}"
        MISSING+=("$wt")
        continue
    fi

    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

    if is_pinned "$name"; then
        echo -e "  ${DIM}keep${NC}   $name ${DIM}(pinned in .worktree-keep)${NC}"; kept=$((kept+1)); continue
    fi
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dirty" -gt 0 ]; then
        echo -e "  ${YELLOW}keep${NC}   $name ${DIM}($dirty uncommitted/untracked file(s))${NC}"; kept=$((kept+1)); continue
    fi
    # All worktrees share one object store, so the tip SHA is resolvable from here.
    tip=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")
    if [ -z "$tip" ] || ! is_merged "$tip"; then
        echo -e "  ${DIM}keep${NC}   $name ${DIM}($branch not in $BASE_REF)${NC}"; kept=$((kept+1)); continue
    fi
    idle=$(idle_seconds "$wt")
    if [ "$idle" -lt "$IDLE_SECS" ]; then
        echo -e "  ${DIM}keep${NC}   $name ${DIM}(active $(( idle / 86400 ))d ago, under ${IDLE_DAYS}d)${NC}"; kept=$((kept+1)); continue
    fi

    echo -e "  ${RED}remove${NC} $name ${DIM}($branch — merged, idle $(( idle / 86400 ))d)${NC}"
    TO_REMOVE+=("$wt")
done < <(git worktree list --porcelain | sed -n 's/^worktree //p')

echo ""
log_info "worktrees: ${#TO_REMOVE[@]} to remove, ${#MISSING[@]} missing (pruned on --apply), $kept kept"

if [ "$APPLY" = true ]; then
    if [ "${#TO_REMOVE[@]}" -gt 0 ]; then
        mkdir -p "$GRAVEYARD"
        for wt in "${TO_REMOVE[@]}"; do
            name=$(basename "$wt")
            log_info "removing $name"
            branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
            hook_status=0
            run_pre_remove_hook "$wt" "$branch" || hook_status=$?
            if [ "$hook_status" -ne 0 ]; then
                log_error "  pre-remove hook failed for $name (exit $hook_status) — skipping removal, will retry next run"
                kept=$((kept+1))
                continue
            fi
            # Rename onto the same volume: instant, versus minutes of node_modules unlink.
            if mv "$wt" "$GRAVEYARD/$name.$$" 2>/dev/null; then
                removed=$((removed+1))
            else
                log_warn "  mv failed, falling back to git worktree remove"
                git worktree remove "$wt" --force && removed=$((removed+1)) || log_error "  failed: $name"
            fi
        done
    fi
    if [ "${#TO_REMOVE[@]}" -gt 0 ] || [ "${#MISSING[@]}" -gt 0 ]; then
        git worktree prune
        [ "${#MISSING[@]}" -gt 0 ] && log_info "pruned ${#MISSING[@]} missing worktree(s)"
    fi
    if [ "$removed" -gt 0 ]; then
        # Unlink in the background; the worktree list is already correct.
        ( ls -d "$GRAVEYARD"/* 2>/dev/null | xargs -P 8 -I{} rm -rf {} ; rmdir "$GRAVEYARD" 2>/dev/null ) >/dev/null 2>&1 &
        log_info "removed $removed worktree(s); files unlinking in the background"
    elif [ "${#TO_REMOVE[@]}" -gt 0 ]; then
        log_info "removed 0 worktree(s) (all skipped — see above)"
    fi
fi

if [ "$DO_BRANCHES" = true ]; then
    echo ""
    checked_out=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')
    b_del=0; b_keep=0
    declare -a BRANCH_KILL=()
    while IFS= read -r b; do
        if echo "$checked_out" | grep -qxF -- "$b"; then b_keep=$((b_keep+1)); continue; fi
        case "$b" in "$BASE_BRANCH") b_keep=$((b_keep+1)); continue ;; esac
        sha=$(git rev-parse "$b")
        if [ -n "$(git branch -r --contains "$sha" 2>/dev/null)" ] || is_merged "$b"; then
            echo -e "  ${RED}delete${NC} $b"
            BRANCH_KILL+=("$b"); b_del=$((b_del+1))
        else
            b_keep=$((b_keep+1))
        fi
    done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

    log_info "branches: $b_del to delete, $b_keep kept (unmerged or checked out)"
    if [ "$APPLY" = true ]; then
        for b in ${BRANCH_KILL+"${BRANCH_KILL[@]}"}; do git branch -D "$b" >/dev/null; done
        [ "$b_del" -gt 0 ] && log_info "deleted $b_del branch(es)"
    fi
fi

echo ""
if [ "$APPLY" = true ]; then
    log_info "Done. $(git worktree list --porcelain | grep -c '^worktree ') worktree(s), $(git for-each-ref refs/heads/ | wc -l | tr -d ' ') branch(es) remain."
else
    log_info "Dry run only. Re-run with --apply (or 'just worktree-gc-apply') to remove."
fi
