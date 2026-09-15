#!/usr/bin/env bash
# Example .worktree/post-create.sh: fork an isolated Postgres database for a
# new worktree from a template database running in a Docker container.
#
# Copy to .worktree/post-create.sh, chmod +x, and adjust the variables below.
# worktree-new.sh calls this as: post-create.sh <worktree-path> <branch>

set -euo pipefail

CONTAINER_NAME="${WORKTREE_DB_CONTAINER:-dev-db}"
TEMPLATE_DB="${WORKTREE_DB_TEMPLATE:-app_dev}"
DB_USER="${WORKTREE_DB_USER:-postgres}"
DB_PASSWORD="${WORKTREE_DB_PASSWORD:-password}"
ENV_FILE_NAME="${WORKTREE_ENV_FILE:-.env.worktree}"

WORKTREE_PATH="$1"

if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" -q | grep -q .; then
    echo "post-create: $CONTAINER_NAME is not running — skipping database fork" >&2
    exit 0
fi

hash="$(echo "$WORKTREE_PATH" | (md5sum 2>/dev/null || md5 -r) | cut -c1-8)"
db_name="${TEMPLATE_DB}_${hash}"
db_port="$(docker port "$CONTAINER_NAME" 5432 2>/dev/null | head -1 | cut -d: -f2)"
db_port="${db_port:-5432}"

echo "post-create: forking $TEMPLATE_DB -> $db_name"

# Postgres refuses CREATE DATABASE ... TEMPLATE while anything is connected
# to the template, so this also disconnects the developer's own running app.
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$TEMPLATE_DB','$db_name') AND pid <> pg_backend_pid()" \
    >/dev/null 2>&1 || true
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS \"$db_name\"" >/dev/null
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -c "CREATE DATABASE \"$db_name\" TEMPLATE \"$TEMPLATE_DB\""

db_url="postgres://${DB_USER}:${DB_PASSWORD}@localhost:${db_port}/${db_name}"
echo "DATABASE_URL=$db_url" > "$WORKTREE_PATH/$ENV_FILE_NAME"

echo "post-create: database ready — $db_name (see $ENV_FILE_NAME)"
