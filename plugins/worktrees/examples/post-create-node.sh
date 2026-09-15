#!/usr/bin/env bash
# Example .worktree/post-create.sh: install Node dependencies with whichever
# package manager's lockfile is present.
#
# Copy to .worktree/post-create.sh, chmod +x. If you also need a database
# fork, append the body of post-create-postgres.sh here instead of running
# two separate hooks — only one post-create.sh runs.
# worktree-new.sh calls this as: post-create.sh <worktree-path> <branch>

set -euo pipefail

WORKTREE_PATH="$1"
cd "$WORKTREE_PATH"

if [ -f pnpm-lock.yaml ]; then
    echo "post-create: pnpm install"
    pnpm install
elif [ -f yarn.lock ]; then
    echo "post-create: yarn install"
    yarn install
elif [ -f package-lock.json ]; then
    echo "post-create: npm ci"
    npm ci
elif [ -f package.json ]; then
    echo "post-create: no lockfile found, running npm install"
    npm install
fi
