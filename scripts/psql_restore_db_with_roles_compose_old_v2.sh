#!/usr/bin/env bash
set -Eeuo pipefail

# psql_restore_db_with_roles_compose.sh (clean roles+data flow)
# ------------------------------------------------------------
# Run INSIDE the Postgres container as the service command in docker-compose.
# Starts the official entrypoint (postgres), waits ready, restores roles (from
# a roles file or CSV), then restores the database dump. Idempotent via marker.
#
# Usage (compose command):
#   /scripts/psql_restore_db_with_roles_compose.sh <target_db> <backup_filename> [role1,role2,...] [force]
#
# Parameters:
#   target_db       - Name of the target database
#   backup_filename - Name of backup file in /docker-entrypoint-initdb.d
#   roles_csv       - Optional comma-separated list of roles to create
#   force           - Optional: "force" to override restore marker and force restoration
#
# Expectations:
#   - <backup_filename> resides in /docker-entrypoint-initdb.d (e.g. mydb.bkp)
#   - Optional roles file at /docker-entrypoint-initdb.d/<target_db>.roles
#     (comma or whitespace separated, # comments allowed). If a CSV arg is
#     provided, it overrides the file.
#   - Uses peer auth by running as the postgres OS user (gosu postgres).
#
# Env knobs:
#   ROLE_DEFAULT_PASSWORD  default password when creating roles (default: kindzadza)
#   HBA_FILE               if set, passed to postgres as -c hba_file=...
#   RESTORE_JOBS           number of parallel jobs for pg_restore (e.g., 4)
#
# How to Check:
# docker logs pg17
# docker compose down
# docker compose down -v (ATTENTION: This diconnects volume so it reinit and delte data at next run)
# docker compose up -d
# docker exec -it pg17 psql -U vasily -d appdb -c "SELECT version();" 
#
# Quick persistence test
# docker exec -it pg17 psql -U vasily -d appdb -c "CREATE TABLE t(x int); INSERT INTO t VALUES (1);"
# docker restart pg17
# docker exec -it pg17 psql -U vasily -d appdb -c "SELECT * FROM t;"

TARGET_DB="${1:-}"
BACKUP_FILE="${2:-}"
ROLES_CSV_ARG="${3:-}"
FORCE_RESTORE="${4:-}"

if [[ -z "$TARGET_DB" || -z "$BACKUP_FILE" ]]; then
  echo "ERROR: Usage: $0 <target_database_name> <backup_filename> [role1,role2,...] [force]" >&2
  echo "       Use 'force' as 4th parameter to override restore marker and force restoration" >&2
  exit 1
fi

BACKUP_PATH="/docker-entrypoint-initdb.d/${BACKUP_FILE}"
ROLES_PATH="/docker-entrypoint-initdb.d/${TARGET_DB}.roles"
RESTORE_MARKER="/var/lib/postgresql/data/.restored_${TARGET_DB}"
ROLE_DEFAULT_PASSWORD="${ROLE_DEFAULT_PASSWORD:-kindzadza}"

# Build optional hba_file arg
HBA_ARGS=()
if [[ -n "${HBA_FILE:-}" ]]; then
  HBA_ARGS+=( -c "hba_file=${HBA_FILE}" )
fi

# Start official entrypoint (postgres) in background with sane defaults

docker-entrypoint.sh postgres \
  -c listen_addresses='*' \
  -c password_encryption=scram-sha-256 \
  "${HBA_ARGS[@]}" &

# Wait until Postgres is ready (peer over Unix socket)
echo "Waiting for Postgres to be ready (peer auth via socket)..."
until gosu postgres pg_isready -d postgres >/dev/null 2>&1; do
  sleep 1
done

# Helper to run a single SQL
psql_c(){ gosu postgres psql -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }

# Helper to grant comprehensive schema permissions to a role
grant_schema_permissions() {
  local role="$1"
  echo "Granting comprehensive schema permissions to role '${role}'"
  psql_c "$TARGET_DB" "ALTER SCHEMA public OWNER TO ${role};"
  psql_c "$TARGET_DB" "GRANT USAGE, CREATE ON SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON TABLES    TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON SEQUENCES TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${role};"
}

# Create DB if missing
if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}';" | xargs) ]]; then
  echo "Creating database '${TARGET_DB}'..."
  psql_c postgres "CREATE DATABASE ${TARGET_DB};"
  psql_c postgres "GRANT TEMPORARY, CONNECT ON DATABASE ${TARGET_DB} TO PUBLIC;"
else
  echo "Database '${TARGET_DB}' already exists."
fi

# Gather roles: CSV arg overrides roles file if present
ROLE_LIST=()
if [[ -n "$ROLES_CSV_ARG" ]]; then
  IFS=',' read -ra ROLE_LIST <<<"$ROLES_CSV_ARG"
elif [[ -f "$ROLES_PATH" ]]; then
  echo "Reading roles from ${ROLES_PATH}"
  while IFS= read -r line; do
    # strip comments and split by comma/space
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    # replace commas with spaces, then iterate
    for r in ${line//,/ }; do ROLE_LIST+=("$r"); done
  done < "$ROLES_PATH"
fi

# Create listed roles BEFORE restore so pg_restore can apply ownership/privs
if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
  echo "Ensuring roles exist: ${ROLE_LIST[*]}"
  for ROLE in "${ROLE_LIST[@]}"; do
    ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
    if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname='${ROLE}';" | xargs) ]]; then
      echo "Creating role '${ROLE}'"
      psql_c postgres "CREATE ROLE ${ROLE} WITH LOGIN PASSWORD '${ROLE_DEFAULT_PASSWORD}';"
      psql_c postgres "ALTER ROLE ${ROLE} SET client_encoding TO 'utf8';"
      psql_c postgres "ALTER ROLE ${ROLE} SET default_transaction_isolation TO 'read committed';"
      psql_c postgres "ALTER ROLE ${ROLE} SET TimeZone TO 'UTC';"
    else
      echo "Role '${ROLE}' already exists."
    fi
    # Allow connecting to the DB; object ownership/privs will come from dump
    psql_c postgres "GRANT CONNECT ON DATABASE ${TARGET_DB} TO ${ROLE};"
    
    # Grant comprehensive schema permissions
    grant_schema_permissions "$ROLE"
  done
fi

# Restore ONCE (idempotent) unless forced
SKIP_RESTORE=false
if [[ -f "$RESTORE_MARKER" && "$FORCE_RESTORE" != "force" ]]; then
  echo "Restore marker exists (${RESTORE_MARKER}) — skipping restore."
  echo "Use 'force' as 4th parameter to override marker and force restoration."
  SKIP_RESTORE=true
fi

if [[ "$SKIP_RESTORE" == "false" ]]; then
  if [[ -f "$BACKUP_PATH" ]]; then
    if [[ "$FORCE_RESTORE" == "force" && -f "$RESTORE_MARKER" ]]; then
      echo "FORCE mode: Removing existing restore marker and proceeding with restoration."
      rm -f "$RESTORE_MARKER"
    fi
    echo "Restoring '${TARGET_DB}' from: ${BACKUP_PATH}"
    JOBS_ARGS=()
    if [[ -n "${RESTORE_JOBS:-}" ]]; then JOBS_ARGS+=( --jobs="${RESTORE_JOBS}" ); fi
    # Important: do NOT use --no-owner/--no-privileges so ownership/GRANTs from dump apply
    gosu postgres pg_restore \
      --format=c --verbose --clean --if-exists \
      "${JOBS_ARGS[@]}" \
      --dbname "$TARGET_DB" \
      "$BACKUP_PATH"
    gosu postgres psql -d "$TARGET_DB" -c "SELECT 'restore ok' AS status, now();"
    touch "$RESTORE_MARKER"
    echo "Restore complete. Marker written to ${RESTORE_MARKER}."
  else
    echo "WARNING: Backup file not found at ${BACKUP_PATH}. Skipping restore."
  fi
fi

# Verification
echo "Listing first 20 public tables in '${TARGET_DB}':"
gosu postgres psql -d "$TARGET_DB" -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1 LIMIT 20;"

# Keep postgres in foreground
wait
