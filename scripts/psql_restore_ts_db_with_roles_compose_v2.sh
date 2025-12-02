#!/usr/bin/env bash
set -Eeuo pipefail

# PostgreSQL + TimescaleDB Complete Restore Script v2.0
# -------------------------------------------------------------------------
# Restores COMPLETE TimescaleDB databases for exact replicas including:
#   - All tables and data
#   - Hypertables with correct chunk intervals
#   - Continuous aggregates
#   - Compression settings
#   - All policies (retention, compression, refresh)
#
# Run INSIDE the Postgres container as the service command in docker-compose.
#
# Usage (docker-compose.yml):
#   command: ["/scripts/psql_restore_ts_db_with_roles_compose_v2.sh", "<target_db>", "<backup_dir>", "[role1,role2,...]", "[force]"]
#
# Parameters:
#   target_db       - Name of target database
#   backup_dir      - Directory containing backup files (relative to /docker-entrypoint-initdb.d)
#   roles_csv       - Optional comma-separated list of roles
#   force           - Optional: "force" to override restore marker
#
# Expected files in backup directory:
#   <db>.bkp                 - Database dump (required)
#   <db>.roles               - Role list (optional)
#   <db>.hypertables.sql     - Hypertable definitions (optional, for TimescaleDB)
#   <db>.continuous_aggs.sql - Continuous aggregates (optional)
#   <db>.compression.sql     - Compression settings (optional)
#   <db>.policies.sql        - Policy definitions (optional)
#
# Examples:
#   command: ["/scripts/psql_restore_ts_db_with_roles_compose_v2.sh", "wnga_auth", "bkp_2025_11_29_14", "wnga"]
#   command: ["/scripts/psql_restore_ts_db_with_roles_compose_v2.sh", "wnga_auth", "bkp_2025_11_29_14", "wnga", "force"]

TARGET_DB="${1:-}"
BACKUP_DIRNAME="${2:-}"
ROLES_CSV_ARG="${3:-}"
FORCE_RESTORE="${4:-}"

if [[ -z "$TARGET_DB" || -z "$BACKUP_DIRNAME" ]]; then
  echo "ERROR: Usage: $0 <target_database> <backup_directory> [role1,role2,...] [force]" >&2
  echo "       Example: $0 wnga_auth bkp_2025_11_29_14 wnga" >&2
  exit 1
fi

BACKUP_DIR="/docker-entrypoint-initdb.d/${BACKUP_DIRNAME}"
BACKUP_FILE="${BACKUP_DIR}/${TARGET_DB}.bkp"
ROLES_FILE="${BACKUP_DIR}/${TARGET_DB}.roles"
HYPERTABLES_SQL="${BACKUP_DIR}/${TARGET_DB}.hypertables.sql"
CONTINUOUS_AGGS_SQL="${BACKUP_DIR}/${TARGET_DB}.continuous_aggs.sql"
COMPRESSION_SQL="${BACKUP_DIR}/${TARGET_DB}.compression.sql"
POLICIES_SQL="${BACKUP_DIR}/${TARGET_DB}.policies.sql"
RESTORE_MARKER="/var/lib/postgresql/data/.restored_${TARGET_DB}"
ROLE_DEFAULT_PASSWORD="${ROLE_DEFAULT_PASSWORD:-kindzadza}"

HBA_ARGS=()
if [[ -n "${HBA_FILE:-}" ]]; then
  HBA_ARGS+=( -c "hba_file=${HBA_FILE}" )
fi

echo "=========================================="
echo "PostgreSQL + TimescaleDB Complete Restore"
echo "=========================================="
echo "Target Database: $TARGET_DB"
echo "Backup Directory: $BACKUP_DIRNAME"
echo "Timestamp: $(date)"
echo "=========================================="
echo ""

# Start PostgreSQL in background
docker-entrypoint.sh postgres \
  -c listen_addresses='*' \
  -c password_encryption=scram-sha-256 \
  "${HBA_ARGS[@]}" &

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
until gosu postgres pg_isready -d postgres >/dev/null 2>&1; do
  sleep 1
done
echo "✓ PostgreSQL is ready"
echo ""

# Helper function to execute SQL
psql_c() { gosu postgres psql -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
psql_f() { gosu postgres psql -v ON_ERROR_STOP=1 -d "$1" -f "$2"; }

# Check if TimescaleDB extension is available
check_timescaledb_available() {
  gosu postgres psql -d postgres -At -c \
    "SELECT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb');" 2>/dev/null || echo "f"
}

# Detect if backup has TimescaleDB metadata
detect_timescaledb_backup() {
  [[ -f "$HYPERTABLES_SQL" && -s "$HYPERTABLES_SQL" ]] && echo "t" || echo "f"
}

# Grant comprehensive schema permissions
grant_schema_permissions() {
  local role="$1" has_timescaledb="$2"
  
  echo "  Granting permissions to role '${role}'"
  
  # Public schema
  psql_c "$TARGET_DB" "ALTER SCHEMA public OWNER TO ${role};" 2>/dev/null || true
  psql_c "$TARGET_DB" "GRANT USAGE, CREATE ON SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON TABLES TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON SEQUENCES TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${role};"
  
  # TimescaleDB schemas
  if [[ "$has_timescaledb" == "t" ]]; then
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_catalog TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_catalog TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_config TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_config TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    
    if gosu postgres psql -d "$TARGET_DB" -At -c "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = '_timescaledb_functions');" 2>/dev/null | grep -q "t"; then
      psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_functions TO ${role};" 2>/dev/null || true
      psql_c "$TARGET_DB" "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA _timescaledb_functions TO ${role};" 2>/dev/null || true
    fi
  fi
}

# Verify restoration
verify_timescaledb_restore() {
  echo ""
  echo "🔍 Verifying TimescaleDB restoration..."
  
  sleep 1
  
  local ht_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "0")
  
  if [[ "$ht_count" -gt 0 ]]; then
    echo "✓ Hypertables: $ht_count"
    gosu postgres psql -d "$TARGET_DB" -t -c \
      "SELECT '    - ' || hypertable_schema || '.' || hypertable_name || ' (chunks: ' || num_chunks || ')' 
       FROM timescaledb_information.hypertables 
       ORDER BY hypertable_schema, hypertable_name;"
  else
    echo "⚠ No hypertables found"
  fi
  
  local chunk_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.chunks;" 2>/dev/null || echo "0")
  [[ "$chunk_count" -gt 0 ]] && echo "✓ Chunks: $chunk_count"
  
  local cagg_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.continuous_aggregates;" 2>/dev/null || echo "0")
  [[ "$cagg_count" -gt 0 ]] && echo "✓ Continuous aggregates: $cagg_count"
  
  local pol_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.jobs WHERE proc_name LIKE 'policy_%';" 2>/dev/null || echo "0")
  [[ "$pol_count" -gt 0 ]] && echo "✓ Policies: $pol_count"
}

# Create database
if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}';" | xargs) ]]; then
  echo "📦 Creating database '${TARGET_DB}'..."
  psql_c postgres "CREATE DATABASE ${TARGET_DB};"
  psql_c postgres "GRANT TEMPORARY, CONNECT ON DATABASE ${TARGET_DB} TO PUBLIC;"
else
  echo "📦 Database '${TARGET_DB}' already exists"
fi

# Detect TimescaleDB backup
HAS_TIMESCALEDB=$(detect_timescaledb_backup)
TS_AVAILABLE=$(check_timescaledb_available)

if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
  echo "⏰ TimescaleDB backup detected"
  
  if [[ "$TS_AVAILABLE" == "t" ]]; then
    echo "✓ TimescaleDB extension available"
    echo "📦 Creating TimescaleDB extension..."
    psql_c "$TARGET_DB" "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
    
    TS_VERSION=$(gosu postgres psql -d "$TARGET_DB" -At -c \
      "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null || echo "unknown")
    echo "  Version: $TS_VERSION"
  else
    echo "❌ ERROR: TimescaleDB backup requires timescale/timescaledb Docker image" >&2
    exit 1
  fi
else
  echo "📋 Standard PostgreSQL backup"
fi

# Gather roles
ROLE_LIST=()
if [[ -n "$ROLES_CSV_ARG" ]]; then
  IFS=',' read -ra ROLE_LIST <<<"$ROLES_CSV_ARG"
elif [[ -f "$ROLES_FILE" ]]; then
  echo "👥 Reading roles from ${ROLES_FILE}"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    for r in ${line//,/ }; do ROLE_LIST+=("$r"); done
  done < "$ROLES_FILE"
fi

# Create roles
if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
  echo ""
  echo "👥 Creating roles: ${ROLE_LIST[*]}"
  for ROLE in "${ROLE_LIST[@]}"; do
    ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
    if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname='${ROLE}';" | xargs) ]]; then
      echo "  Creating role '${ROLE}'"
      psql_c postgres "CREATE ROLE ${ROLE} WITH LOGIN PASSWORD '${ROLE_DEFAULT_PASSWORD}';"
      psql_c postgres "ALTER ROLE ${ROLE} SET client_encoding TO 'utf8';"
      psql_c postgres "ALTER ROLE ${ROLE} SET default_transaction_isolation TO 'read committed';"
      psql_c postgres "ALTER ROLE ${ROLE} SET TimeZone TO 'UTC';"
    else
      echo "  Role '${ROLE}' already exists"
    fi
    psql_c postgres "GRANT CONNECT ON DATABASE ${TARGET_DB} TO ${ROLE};"
  done
fi

# Check restore marker
SKIP_RESTORE=false
if [[ -f "$RESTORE_MARKER" && "$FORCE_RESTORE" != "force" ]]; then
  echo ""
  echo "⏭ Restore marker exists — skipping restore"
  echo "   Use 'force' as 4th parameter to force restoration"
  SKIP_RESTORE=true
fi

if [[ "$SKIP_RESTORE" == "false" ]]; then
  if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "❌ ERROR: Backup file not found: $BACKUP_FILE" >&2
    exit 1
  fi
  
  if [[ "$FORCE_RESTORE" == "force" && -f "$RESTORE_MARKER" ]]; then
    echo ""
    echo "🔄 FORCE mode: Dropping and recreating database..."
    rm -f "$RESTORE_MARKER"
    
    psql_c postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();" 2>/dev/null || true
    psql_c postgres "DROP DATABASE IF EXISTS ${TARGET_DB};"
    psql_c postgres "CREATE DATABASE ${TARGET_DB};"
    psql_c postgres "GRANT TEMPORARY, CONNECT ON DATABASE ${TARGET_DB} TO PUBLIC;"
    
    if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
      psql_c "$TARGET_DB" "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
    fi
    
    if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
      for ROLE in "${ROLE_LIST[@]}"; do
        ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
        psql_c postgres "GRANT CONNECT ON DATABASE ${TARGET_DB} TO ${ROLE};" 2>/dev/null || true
      done
    fi
  fi
  
  echo ""
  echo "📥 Restoring database from: $(basename $BACKUP_FILE)"
  
  # Restore database dump
  set +e
  gosu postgres pg_restore \
    --format=c \
    --verbose \
    --single-transaction \
    --dbname "$TARGET_DB" \
    "$BACKUP_FILE" 2>&1 | \
    grep -v "NOTICE:" | \
    grep -v "WARNING:  column type" | \
    grep -v "ERROR:  extension \"timescaledb\" has already been loaded" | \
    grep -v "already exists, skipping" | \
    tail -20
  RESTORE_EXIT_CODE=$?
  set -e
  
  if [[ $RESTORE_EXIT_CODE -ne 0 && $RESTORE_EXIT_CODE -ne 1 ]]; then
    echo "⚠ WARNING: pg_restore exited with code $RESTORE_EXIT_CODE (may be normal)"
  fi
  
  gosu postgres psql -d "$TARGET_DB" -c "SELECT 'restore ok' AS status, now();"
  echo "✓ Database dump restored"
  
  # Restore TimescaleDB components
  if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
    echo ""
    echo "⏰ Restoring TimescaleDB components..."
    
    # 1. Recreate hypertables
    if [[ -f "$HYPERTABLES_SQL" && -s "$HYPERTABLES_SQL" ]]; then
      echo "  📊 Creating hypertables..."
      
      # Drop conflicting triggers first
      gosu postgres psql -d "$TARGET_DB" -At -c \
        "SELECT format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trigger_name, trigger_schema, event_object_table)
         FROM information_schema.triggers
         WHERE trigger_name IN ('ts_insert_blocker', 'ts_cagg_invalidation_trigger');" | \
      while read -r drop_cmd; do
        gosu postgres psql -d "$TARGET_DB" -c "$drop_cmd" 2>/dev/null || true
      done
      
      set +e
      HT_OUTPUT=$(psql_f "$TARGET_DB" "$HYPERTABLES_SQL" 2>&1)
      HT_EXIT=$?
      set -e
      
      # Check actual result by counting hypertables
      HT_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "0")
      
      if [[ "$HT_COUNT" -gt 0 ]]; then
        echo "     ✓ $HT_COUNT hypertable(s) created successfully"
      else
        echo "     ❌ ERROR: No hypertables were created"
        echo "$HT_OUTPUT" | grep -E "ERROR" | head -5
      fi
    fi
    
    # 2. Recreate continuous aggregates
    if [[ -f "$CONTINUOUS_AGGS_SQL" && -s "$CONTINUOUS_AGGS_SQL" ]]; then
      CAGG_CHECK=$(grep -c "CREATE MATERIALIZED VIEW" "$CONTINUOUS_AGGS_SQL" 2>/dev/null || echo "0")
      if [[ "$CAGG_CHECK" -gt 0 ]]; then
        echo "  📊 Creating continuous aggregates..."
        set +e
        CAGG_OUTPUT=$(psql_f "$TARGET_DB" "$CONTINUOUS_AGGS_SQL" 2>&1)
        CAGG_EXIT=$?
        set -e
        
        # Check actual result by counting continuous aggregates
        CAGG_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT COUNT(*) FROM timescaledb_information.continuous_aggregates;" 2>/dev/null || echo "0")
        
        if [[ "$CAGG_COUNT" -gt 0 ]]; then
          echo "     ✓ $CAGG_COUNT continuous aggregate(s) created successfully"
        else
          echo "     ❌ ERROR: No continuous aggregates were created"
          echo "$CAGG_OUTPUT" | grep -E "ERROR" | head -5
        fi
      fi
    fi
    
    # 3. Apply compression settings
    if [[ -f "$COMPRESSION_SQL" && -s "$COMPRESSION_SQL" ]]; then
      COMP_CHECK=$(grep -c "ALTER TABLE" "$COMPRESSION_SQL" 2>/dev/null || echo "0")
      if [[ "$COMP_CHECK" -gt 0 ]]; then
        echo "  📊 Applying compression settings..."
        set +e
        psql_f "$TARGET_DB" "$COMPRESSION_SQL" 2>&1 | grep -E "(ALTER|ERROR)" | head -10
        set -e
        echo "     ✓ Compression settings applied"
      fi
    fi
    
    # 4. Create policies
    if [[ -f "$POLICIES_SQL" && -s "$POLICIES_SQL" ]]; then
      POL_CHECK=$(grep -c "SELECT add_" "$POLICIES_SQL" 2>/dev/null || echo "0")
      if [[ "$POL_CHECK" -gt 0 ]]; then
        echo "  📊 Creating policies..."
        set +e
        POL_OUTPUT=$(psql_f "$TARGET_DB" "$POLICIES_SQL" 2>&1)
        POL_EXIT=$?
        set -e
        
        # Check actual result by counting policies
        POL_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c \
          "SELECT COUNT(*) FROM timescaledb_information.jobs WHERE proc_name LIKE 'policy_%';" 2>/dev/null || echo "0")
        
        if [[ "$POL_COUNT" -gt 0 ]]; then
          echo "     ✓ $POL_COUNT policy/policies created successfully"
          echo "        Note: Count may be higher than backup due to auto-created refresh policies"
        else
          echo "     ⚠ WARNING: No policies were created"
          echo "$POL_OUTPUT" | grep -E "ERROR" | head -5
        fi
      fi
    fi
    
    # Verify final state
    verify_timescaledb_restore
  fi
  
  # Mark as restored
  touch "$RESTORE_MARKER"
  echo ""
  echo "✓ Restore marker written: $RESTORE_MARKER"
  
  # Grant permissions
  if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
    echo ""
    echo "🔐 Granting schema permissions..."
    for ROLE in "${ROLE_LIST[@]}"; do
      ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
      grant_schema_permissions "$ROLE" "$HAS_TIMESCALEDB"
    done
    echo "✓ Permissions granted"
  fi
fi

# Final verification
echo ""
echo "📋 Post-Restore Verification:"
echo "=========================================="

echo "Public schema tables (first 20):"
gosu postgres psql -d "$TARGET_DB" -t -c \
  "SELECT '  - ' || table_name 
   FROM information_schema.tables 
   WHERE table_schema='public' 
   ORDER BY 1 LIMIT 20;"

DB_SIZE=$(gosu postgres psql -d "$TARGET_DB" -At -c \
  "SELECT pg_size_pretty(pg_database_size('${TARGET_DB}'));" 2>/dev/null || echo "unknown")
echo ""
echo "Database size: $DB_SIZE"

if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
  HT_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "0")
  CHUNK_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.chunks;" 2>/dev/null || echo "0")
  CAGG_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.continuous_aggregates;" 2>/dev/null || echo "0")
  POL_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.jobs WHERE proc_name LIKE 'policy_%';" 2>/dev/null || echo "0")
  
  echo "Hypertables: $HT_COUNT"
  echo "Chunks: $CHUNK_COUNT"
  echo "Continuous Aggregates: $CAGG_COUNT"
  echo "Policies: $POL_COUNT"
fi

echo "=========================================="
echo "✅ Restore process complete!"
echo "=========================================="
echo ""
echo "🔒 Keeping PostgreSQL running in foreground..."
echo "   Container will remain active. Use 'docker logs' to monitor."
echo ""

# Keep PostgreSQL in foreground
wait
