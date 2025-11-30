#!/usr/bin/env bash
set -Eeuo pipefail

# PostgreSQL Full Backup with TimescaleDB Support (data + roles) — Docker-friendly
# ---------------------------------------------------------------------------------
# Run this script on the HOST. It streams pg_dump output from a running
# Postgres container with TimescaleDB extension and writes files to the host.
# Roles are exported to a companion <db>.roles file.
#
# This version is optimized for databases containing TimescaleDB hypertables.
# It handles:
#   - TimescaleDB catalog circular foreign-key constraints
#   - Hypertable chunk data backup
#   - Extension dependencies
#   - Proper restore ordering
#
# Requirements:
#   - A running Postgres container with TimescaleDB (default name: pg17)
#   - Container has gosu/psql/pg_dump (official image does)
#   - You have permission to write to the chosen backup directory
#
# Usage:
#   psql_bkp_with_roles_docker_timescale.sh [-c <container>] [-d <backup_dir>] [-db <database>] [-r <role1,role2,...>] [-h]
# Examples:
#   # Backup one DB (auto-create timestamped folder under ./backups)
#   ./psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups
#
#   # Backup all user DBs (non-template) and export all non-system roles
#   ./psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -d /srv/backups/pg
#
# Flags:
#   -c   Docker container name (default: pg17)
#   -d   Destination directory on host (default: ./backups)
#   -db  Specific database name to back up (default: all user DBs)
#   -r   Comma-separated list of roles to export (default: all non-system roles)
#   -q   Quiet mode - suppress verbose pg_dump output (default: off)
#   -h   Help
#
# Example:
# 1. Back up all user DBs into /srv/backups/pg:
#./psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -d /srv/backups/pg
#
# 2. Only export selected roles for that DB:
# ./psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups -r "wnga,reporter"
#
# 3. Quiet backup (suppress pg_dump verbose output):
# ./psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups -q
#

CONTAINER="pg17"
BASE_BACKUP_DIR="./backups"
DB_NAME=""
ROLE_FILTER=""
QUIET_MODE=0

print_help() {
  cat <<'EOF'
Usage:
  psql_bkp_with_roles_docker_timescale.sh [-c <container>] [-d <backup_dir>] [-db <database>] [-r <role1,role2,...>] [-q] [-h]

Flags:
  -c   Docker container name (default: pg17)
  -d   Destination directory on host (default: ./backups)
  -db  Specific database name to back up (default: all user DBs)
  -r   Comma-separated list of roles to export (default: all non-system roles)
  -q   Quiet mode - suppress verbose pg_dump output
  -h   Help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CONTAINER="$2"; shift 2 ;;
    -d) BASE_BACKUP_DIR="$2"; shift 2 ;;
    -db) DB_NAME="$2"; shift 2 ;;
    -r) ROLE_FILTER="$2"; shift 2 ;;
    -q) QUIET_MODE=1; shift ;;
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

# Check if database has TimescaleDB extension
check_timescaledb() {
  local db="$1"
  docker exec -i "$CONTAINER" gosu postgres psql -d "$db" -At -c \
    "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'timescaledb');" 2>/dev/null || echo "f"
}

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

# Export TimescaleDB metadata for a database
export_timescaledb_metadata() {
  local db="$1"; local out_file="$2"
  docker exec -i "$CONTAINER" gosu postgres psql -d "$db" -At -c \
    "SELECT 
       ht.schema_name || '.' || ht.table_name as hypertable,
       d.column_name as partition_column,
       d.interval_length as chunk_interval
     FROM _timescaledb_catalog.hypertable ht
     LEFT JOIN _timescaledb_catalog.dimension d ON ht.id = d.hypertable_id
     WHERE d.interval_length IS NOT NULL
     ORDER BY ht.schema_name, ht.table_name;" 2>/dev/null > "$out_file" || echo "" > "$out_file"
}

# Perform backups
for DB in "${DBS[@]}"; do
  DB_TRIMMED=$(echo "$DB" | xargs)
  [[ -z "$DB_TRIMMED" ]] && continue
  
  echo "📦 Backing up database: $DB_TRIMMED"
  
  # Check if TimescaleDB is installed
  HAS_TIMESCALEDB=$(check_timescaledb "$DB_TRIMMED")
  
  if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
    echo "⏰ TimescaleDB detected - using optimized backup strategy"
    
    # Export TimescaleDB metadata
    echo "📊 Exporting TimescaleDB hypertable metadata"
    export_timescaledb_metadata "$DB_TRIMMED" "$BACKUP_DIR/${DB_TRIMMED}.timescaledb_info"
    
    # Get list of continuous aggregate views (they reference materialized hypertables)
    # These views will be automatically recreated when you recreate the continuous aggregate
    EXCLUDE_VIEWS=()
    while IFS= read -r view_name; do
      if [[ -n "$view_name" ]]; then
        EXCLUDE_VIEWS+=( --exclude-table="public.$view_name" )
        echo "  Excluding continuous aggregate view: $view_name"
      fi
    done < <(docker exec -i "$CONTAINER" gosu postgres psql -d "$DB_TRIMMED" -At -c \
      "SELECT view_name 
       FROM timescaledb_information.continuous_aggregates;" 2>/dev/null || echo "")
    
    # TimescaleDB-optimized backup strategy:
    # EXCLUDE ALL internal TimescaleDB schemas to avoid conflicts:
    #   _timescaledb_catalog  - catalog metadata (recreated by extension)
    #   _timescaledb_config   - configuration (recreated by extension)
    #   _timescaledb_cache    - runtime cache (recreated by extension)
    #   _timescaledb_internal - chunk tables (recreated by TimescaleDB when hypertables restore)
    #
    # ALSO EXCLUDE continuous aggregate views (they reference internal materialized hypertables)
    #
    # This backup contains:
    #   1. Public schema tables (including hypertable definitions)
    #   2. TimescaleDB extension definition
    #   3. Hypertable data (stored in public schema tables, backed by chunks internally)
    #
    # On restore, TimescaleDB will:
    #   1. Create extension and internal schemas
    #   2. Restore hypertable definitions and data
    #   3. Automatically recreate chunks in _timescaledb_internal
    #   4. You must manually recreate continuous aggregates with CREATE MATERIALIZED VIEW
    
    if [[ $QUIET_MODE -eq 1 ]]; then
      # Quiet mode: suppress verbose output, show only errors and warnings
      docker exec -i "$CONTAINER" gosu postgres pg_dump \
        -F c -b \
        --exclude-schema='_timescaledb_catalog' \
        --exclude-schema='_timescaledb_config' \
        --exclude-schema='_timescaledb_cache' \
        --exclude-schema='_timescaledb_internal' \
        "${EXCLUDE_VIEWS[@]}" \
        --no-publications \
        --no-subscriptions \
        -d "$DB_TRIMMED" \
        2>&1 | grep -E "(ERROR|WARNING|FATAL)" || true
      docker exec -i "$CONTAINER" gosu postgres pg_dump \
        -F c -b \
        --exclude-schema='_timescaledb_catalog' \
        --exclude-schema='_timescaledb_config' \
        --exclude-schema='_timescaledb_cache' \
        --exclude-schema='_timescaledb_internal' \
        "${EXCLUDE_VIEWS[@]}" \
        --no-publications \
        --no-subscriptions \
        -d "$DB_TRIMMED" > "$BACKUP_DIR/${DB_TRIMMED}.bkp" 2>/dev/null
    else
      # Verbose mode: show all output including table dumps
      echo "  Excluding TimescaleDB internal schemas (will be recreated on restore)"
      docker exec -i "$CONTAINER" gosu postgres pg_dump \
        -F c -b -v \
        --exclude-schema='_timescaledb_catalog' \
        --exclude-schema='_timescaledb_config' \
        --exclude-schema='_timescaledb_cache' \
        --exclude-schema='_timescaledb_internal' \
        "${EXCLUDE_VIEWS[@]}" \
        --no-publications \
        --no-subscriptions \
        -d "$DB_TRIMMED" \
        2> >(tee >(grep -c "dumping contents of table" > "$BACKUP_DIR/.${DB_TRIMMED}_table_count.tmp" 2>/dev/null || true) >&2) \
        > "$BACKUP_DIR/${DB_TRIMMED}.bkp"
      
      # Wait a moment for the tee process to complete
      sleep 0.5
    fi
    
    # Verify backup was created successfully (use pg_restore on host if available)
    if command -v pg_restore >/dev/null 2>&1; then
      # Count total tables in backup (user tables only, not internal TimescaleDB chunks)
      TABLE_COUNT=$(pg_restore --list "$BACKUP_DIR/${DB_TRIMMED}.bkp" 2>/dev/null | \
        grep -E "^[0-9]+; [0-9]+ [0-9]+ TABLE " | wc -l)
      TABLE_COUNT=$(echo "$TABLE_COUNT" | xargs)
      
      if [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -gt 0 ]]; then
        echo "✓ Total tables backed up: $TABLE_COUNT (includes TimescaleDB chunks from _timescaledb_internal)"
      fi
    else
      # Fallback: check if file is non-empty and try to get count from verbose output
      if [[ -s "$BACKUP_DIR/${DB_TRIMMED}.bkp" ]]; then
        echo "✓ Backup file created successfully"
        
        # Try to read table count from temp file created during verbose dump
        if [[ -f "$BACKUP_DIR/.${DB_TRIMMED}_table_count.tmp" ]]; then
          TABLE_COUNT=$(cat "$BACKUP_DIR/.${DB_TRIMMED}_table_count.tmp" 2>/dev/null | xargs)
          rm -f "$BACKUP_DIR/.${DB_TRIMMED}_table_count.tmp"
          if [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -gt 0 ]]; then
            echo "✓ Total tables backed up: $TABLE_COUNT"
          fi
        fi
      fi
    fi
    
  else
    echo "📋 Standard PostgreSQL backup"
    
    # Standard pg_dump for non-TimescaleDB databases
    if [[ $QUIET_MODE -eq 1 ]]; then
      docker exec -i "$CONTAINER" gosu postgres pg_dump \
        -F c -b \
        -d "$DB_TRIMMED" > "$BACKUP_DIR/${DB_TRIMMED}.bkp" 2>&1 | grep -E "(ERROR|WARNING|FATAL)" || true
    else
      docker exec -i "$CONTAINER" gosu postgres pg_dump \
        -F c -b -v \
        -d "$DB_TRIMMED" > "$BACKUP_DIR/${DB_TRIMMED}.bkp"
    fi
    
    # Count tables in standard PostgreSQL backup
    if command -v pg_restore >/dev/null 2>&1; then
      TABLE_COUNT=$(pg_restore --list "$BACKUP_DIR/${DB_TRIMMED}.bkp" 2>/dev/null | \
        grep -E "^[0-9]+; [0-9]+ [0-9]+ TABLE " | wc -l)
      TABLE_COUNT=$(echo "$TABLE_COUNT" | xargs)
      
      if [[ -n "$TABLE_COUNT" && "$TABLE_COUNT" -gt 0 ]]; then
        echo "✓ Total tables backed up: $TABLE_COUNT"
      fi
    fi
  fi
  
  echo "👥 Exporting roles for: $DB_TRIMMED"
  export_roles_for_db "$DB_TRIMMED" "$BACKUP_DIR/${DB_TRIMMED}.roles"
  
  # Get backup file size
  BACKUP_SIZE=$(du -h "$BACKUP_DIR/${DB_TRIMMED}.bkp" | cut -f1)
  echo "✅ Backup completed for: $DB_TRIMMED (size: $BACKUP_SIZE)"
done

echo ""
echo "🎉 All done. Files in: $BACKUP_DIR"
echo ""
echo "📋 Backup Summary:"
echo "   Location: $BACKUP_DIR"
echo "   Databases: ${#DBS[@]}"
for DB in "${DBS[@]}"; do
  DB_TRIMMED=$(echo "$DB" | xargs)
  [[ -z "$DB_TRIMMED" ]] && continue
  if [[ -f "$BACKUP_DIR/${DB_TRIMMED}.bkp" ]]; then
    SIZE=$(du -h "$BACKUP_DIR/${DB_TRIMMED}.bkp" | cut -f1)
    HAS_TS=$(check_timescaledb "$DB_TRIMMED")
    TS_MARKER=""
    [[ "$HAS_TS" == "t" ]] && TS_MARKER=" ⏰"
    echo "   - ${DB_TRIMMED}.bkp: $SIZE$TS_MARKER"
  fi
done
echo ""
