#!/usr/bin/env bash
set -Eeuo pipefail

# PostgreSQL Full Backup (data + roles) — Docker-friendly
# -------------------------------------------------------
# Run this script on the HOST. It streams pg_dump output from a running
# Postgres container (official image) and writes files to the host.
# Roles are exported to a companion <db>.roles file.
#
# Requirements:
#   - A running Postgres container (default name: pg17)
#   - Container has gosu/psql/pg_dump (official image does)
#   - You have permission to write to the chosen backup directory
#
# Usage:
#   psql_bkp_with_roles_docker.sh [-c <container>] [-d <backup_dir>] [-db <database>] [-r <role1,role2,...>] [-h]
# Examples:
#   # Backup one DB (auto-create timestamped folder under ./backups)
#   ./psql_bkp_with_roles_docker.sh -c pg17 -db wnga_auth -d ./backups
#
#   # Backup all user DBs (non-template) and export all non-system roles
#   ./psql_bkp_with_roles_docker.sh -c pg17 -d /srv/backups/pg
#
# Flags:
#   -c   Docker container name (default: pg17)
#   -d   Destination directory on host (default: ./backups)
#   -db  Specific database name to back up (default: all user DBs)
#   -r   Comma-separated list of roles to export (default: all non-system roles)
#   -h   Help
#
# Example:
# 1. Back up all user DBs into /srv/backups/pg:
#./psql_bkp_with_roles_docker.sh -c pg17 -d /srv/backups/pg
#
# 2. Only export selected roles for that DB:
# ./psql_bkp_with_roles_docker.sh -c pg17 -db wnga_auth -d ./backups -r "wnga,reporter"
#

CONTAINER="pg17"
BASE_BACKUP_DIR="./backups"
DB_NAME=""
ROLE_FILTER=""

print_help() {
  cat <<'EOF'
Usage:
  psql_bkp_with_roles_docker.sh [-c <container>] [-d <backup_dir>] [-db <database>] [-r <role1,role2,...>] [-h]
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONTAINER="$2"; shift 2 ;;
    -d) BASE_BACKUP_DIR="$2"; shift 2 ;;
    -db) DB_NAME="$2"; shift 2 ;;
    -r) ROLE_FILTER="$2"; shift 2 ;;
    -h) print_help ;;
    *) echo "Unknown option: $1" >&2; print_help ;;
  esac
done

# Ensure container is running
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "❌ Container '$CONTAINER' is not running" >&2
  exit 1
fi

# Ensure base dir exists
mkdir -p "$BASE_BACKUP_DIR"

# Build timestamped subfolder: bkp_YYYY_MM_DD_N
CURRENT_DATE=$(date +"%Y_%m_%d")
find_next_backup_dir() {
  local base_dir=$1 date_str=$2 n=0 path
  while true; do
    path="${base_dir}/bkp_${date_str}_${n}"
    [[ ! -d "$path" ]] && { echo "$path"; return; }
    n=$((n+1))
  done
}
BACKUP_DIR=$(find_next_backup_dir "$BASE_BACKUP_DIR" "$CURRENT_DATE")
mkdir -p "$BACKUP_DIR"

# Helper to run commands inside container as postgres
psql_exec() { # psql_exec <db> <psql-args>
  docker exec -i "$CONTAINER" gosu postgres psql -v ON_ERROR_STOP=1 -d "$1" ${@:2}
}

# Get list of DBs
if [[ -n "$DB_NAME" ]]; then
  mapfile -t DBS < <(printf '%s\n' "$DB_NAME")
else
  mapfile -t DBS < <(docker exec -i "$CONTAINER" gosu postgres psql -d postgres -At -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1;")
fi

# Export role list (either filtered or all non-system)
export_roles_for_db() {
  local db="$1"; local out_file="$2"
  if [[ -n "$ROLE_FILTER" ]]; then
    # normalize: split commas, join with ', '
    IFS=',' read -ra ROLES <<<"$ROLE_FILTER"
    printf '%s\n' "${ROLES[@]}" | sed '/^$/d' | paste -sd ', ' - > "$out_file"
  else
    docker exec -i "$CONTAINER" gosu postgres psql -d "$db" -At -c \
      "SELECT string_agg(rolname, ', ')
         FROM pg_roles
        WHERE rolname !~ '^pg_'
          AND rolname <> 'postgres';" > "$out_file"
  fi
}

# Perform backups
for DB in "${DBS[@]}"; do
  DB_TRIMMED=$(echo "$DB" | xargs)
  [[ -z "$DB_TRIMMED" ]] && continue
  echo "📦 Backing up database: $DB_TRIMMED"
  # Stream pg_dump custom format to host file
  docker exec -i "$CONTAINER" gosu postgres pg_dump -F c -b -v -d "$DB_TRIMMED" > "$BACKUP_DIR/${DB_TRIMMED}.bkp"

  echo "👥 Exporting roles for: $DB_TRIMMED"
  export_roles_for_db "$DB_TRIMMED" "$BACKUP_DIR/${DB_TRIMMED}.roles"

  echo "✅ Backup completed for: $DB_TRIMMED"
done

echo "🎉 All done. Files in: $BACKUP_DIR"
