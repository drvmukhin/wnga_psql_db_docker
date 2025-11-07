#!/bin/bash
set -Eeuo pipefail

# Usage: /scripts/docker-entrypoint-init-custom.sh <target_database_name> <backup_filename>
TARGET_DB="${1:-}"
BACKUP_FILE="${2:-}"

if [[ -z "$TARGET_DB" || -z "$BACKUP_FILE" ]]; then
  echo "ERROR: Usage: $0 <target_database_name> <backup_filename>" >&2
  exit 1
fi

BACKUP_PATH="/docker-entrypoint-initdb.d/${BACKUP_FILE}"
RESTORE_MARKER="/var/lib/postgresql/data/.restored_${TARGET_DB}"

# Start official entrypoint with our runtime settings in background
docker-entrypoint.sh postgres \
  -c listen_addresses='*' \
  -c password_encryption=scram-sha-256 \
  -c hba_file='/etc/postgresql/pg_hba_custom.conf' &

echo "Waiting for Postgres to be ready (peer auth via socket)..."
until gosu postgres pg_isready -d postgres >/dev/null 2>&1; do
  sleep 1
done

# Restore ONCE if marker not present
if [[ ! -f "$RESTORE_MARKER" ]]; then
  if [[ -f "$BACKUP_PATH" ]]; then
    echo "Restoring custom-format backup '${BACKUP_FILE}' into DB '${TARGET_DB}'..."

    # Quietly create DB if missing
    if ! gosu postgres psql -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" | grep -q 1; then
      gosu postgres createdb "${TARGET_DB}"
    fi

    # Restore with safer flags
    gosu postgres pg_restore \
      --clean --if-exists --no-owner --no-privileges \
      -d "${TARGET_DB}" \
      "${BACKUP_PATH}"

    # Sanity ping and write marker
    gosu postgres psql -d "${TARGET_DB}" -c "SELECT 'restore ok' AS status, now();"
    touch "$RESTORE_MARKER"
    echo "Restore complete. Marker written to ${RESTORE_MARKER}."

    # Verification: list restored tables
    echo "Listing tables in '${TARGET_DB}':"
    gosu postgres psql -d "${TARGET_DB}" -c "\dt"
  else
    echo "WARNING: Backup file not found at: ${BACKUP_PATH}. Skipping restore."
  fi
else
  echo "Restore marker exists (${RESTORE_MARKER}) — skipping restore."
fi

# Keep postgres in foreground
wait
