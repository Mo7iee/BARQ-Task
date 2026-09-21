#!/usr/bin/env bash

set -euo pipefail

CONTAINER="postgres"
DATABASE="barq_tasks"
USER="barq_app"
BACKUP_DIR="./backups"

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/${DATABASE}_${TIMESTAMP}.sql"

echo "Checking PostgreSQL container..."

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q '^true$'; then
echo "FAIL: PostgreSQL container '$CONTAINER' is not running."
exit 1
fi

echo "Creating PostgreSQL logical backup..."
docker exec "$CONTAINER" pg_dump -U "$USER" -d "$DATABASE" > "$BACKUP_FILE"

if [[ ! -s "$BACKUP_FILE" ]]; then
echo "FAIL: Backup file was not created or is empty."
rm -f "$BACKUP_FILE"
exit 1
fi

echo "PASS: PostgreSQL backup created."
echo "File: $BACKUP_FILE"
echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"
