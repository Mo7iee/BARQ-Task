#!/usr/bin/env bash

set -euo pipefail

CONTAINER="postgres"
DATABASE="barq_tasks"
USER="barq_app"
BACKUP_FILE="${1:-}"

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <backup.sql>"
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "FAIL: Backup file does not exist: $BACKUP_FILE"
    exit 1
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
    echo "FAIL: Backup file is empty: $BACKUP_FILE"
    exit 1
fi

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q '^true$'; then
    echo "FAIL: PostgreSQL container '$CONTAINER' is not running."
    exit 1
fi

echo "WARNING: This will DROP and recreate database '$DATABASE'."
echo "Backup: $BACKUP_FILE"
read -r -p "Continue? [y/N] " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Restore cancelled."
    exit 0
fi

echo "Stopping application containers so they cannot hold database connections..."
docker compose stop app-01 app-02

echo "Dropping and recreating database..."

docker exec "$CONTAINER" \
    psql -U "$USER" -d postgres \
    -c "DROP DATABASE IF EXISTS $DATABASE;"

docker exec "$CONTAINER" \
    psql -U "$USER" -d postgres \
    -c "CREATE DATABASE $DATABASE OWNER $USER;"

echo "Restoring backup..."

docker exec -i "$CONTAINER" \
    psql -U "$USER" -d "$DATABASE" \
    < "$BACKUP_FILE"

echo "Starting application containers..."
docker compose start app-01 app-02

echo "PASS: PostgreSQL restore completed."
echo "Database '$DATABASE' was restored from:"
echo "$BACKUP_FILE"
