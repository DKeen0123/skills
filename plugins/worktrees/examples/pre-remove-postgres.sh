#!/usr/bin/env bash
# Example .worktree/pre-remove.sh: drop the Postgres database forked for this
# worktree by post-create-postgres.sh. Same hash, so it finds the same DB name.
#
# Copy to .worktree/pre-remove.sh, chmod +x, and adjust the variables below.
# worktree-remove.sh / worktree-gc.sh call this as: pre-remove.sh <worktree-path> <branch>

set -euo pipefail

CONTAINER_NAME="${WORKTREE_DB_CONTAINER:-dev-db}"
TEMPLATE_DB="${WORKTREE_DB_TEMPLATE:-app_dev}"
DB_USER="${WORKTREE_DB_USER:-postgres}"

WORKTREE_PATH="$1"

if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" -q | grep -q .; then
    echo "pre-remove: $CONTAINER_NAME is not running — leaving the forked database in place" >&2
    exit 0
fi

hash="$(echo "$WORKTREE_PATH" | (md5sum 2>/dev/null || md5 -r) | cut -c1-8)"
db_name="${TEMPLATE_DB}_${hash}"

docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name' AND pid <> pg_backend_pid()" \
    >/dev/null 2>&1 || true
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS \"$db_name\"" >/dev/null 2>&1 \
    && echo "pre-remove: dropped database $db_name"
