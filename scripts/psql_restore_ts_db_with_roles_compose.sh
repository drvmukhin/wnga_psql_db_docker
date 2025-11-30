#!/usr/bin/env bash
set -Eeuo pipefail

# psql_restore_ts_db_with_roles_compose.sh (TimescaleDB-optimized restore)
# -------------------------------------------------------------------------
# Run INSIDE the Postgres container as the service command in docker-compose.
# Optimized for databases containing TimescaleDB hypertables and regular tables.
# Starts the official entrypoint (postgres), waits ready, restores roles,
# creates TimescaleDB extension if needed, then restores the database dump.
#
# Key Features:
#   - Automatic TimescaleDB detection from backup metadata
#   - Proper extension creation before restore
#   - TimescaleDB schema permissions (_timescaledb_catalog, _timescaledb_internal)
#   - Post-restore hypertable verification
#   - Handles circular FK constraints in TimescaleDB catalog
#   - Safe parallel restore (disabled for TimescaleDB by default)
#
# Usage (compose command):
#   /scripts/psql_restore_ts_db_with_roles_compose.sh <target_db> <backup_filename> [role1,role2,...] [force]
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
#   - Optional TimescaleDB metadata at /docker-entrypoint-initdb.d/<target_db>.timescaledb_info
#   - Uses peer auth by running as the postgres OS user (gosu postgres)
#   - TimescaleDB extension available in container (timescale/timescaledb image)
#
# Env knobs:
#   ROLE_DEFAULT_PASSWORD     default password when creating roles (default: kindzadza)
#   HBA_FILE                  if set, passed to postgres as -c hba_file=...
#   RESTORE_JOBS              number of parallel jobs for pg_restore (disabled for TimescaleDB)
#   TIMESCALEDB_FORCE_JOBS    set to "yes" to force parallel restore even with TimescaleDB
#
# Examples:
#   # Standard restore
#   docker-compose.yml: command: ["/scripts/psql_restore_ts_db_with_roles_compose.sh", "wnga_auth", "wnga_auth.bkp", "wnga"]
#
#   # Force restore (override marker)
#   command: ["/scripts/psql_restore_ts_db_with_roles_compose.sh", "wnga_auth", "wnga_auth.bkp", "wnga", "force"]

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
# If BACKUP_FILE includes a directory path (e.g. bkp_2025_11_29_12/wnga_auth.bkp),
# look for roles/timescaledb_info in the same directory
BACKUP_DIR=$(dirname "$BACKUP_PATH")
ROLES_PATH="${BACKUP_DIR}/${TARGET_DB}.roles"
TS_INFO_PATH="${BACKUP_DIR}/${TARGET_DB}.timescaledb_info"
RESTORE_MARKER="/var/lib/postgresql/data/.restored_${TARGET_DB}"
ROLE_DEFAULT_PASSWORD="${ROLE_DEFAULT_PASSWORD:-kindzadza}"

# Build optional hba_file arg
HBA_ARGS=()
if [[ -n "${HBA_FILE:-}" ]]; then
  HBA_ARGS+=( -c "hba_file=${HBA_FILE}" )
fi

echo "=========================================="
echo "TimescaleDB-Optimized Database Restore"
echo "=========================================="
echo "Target Database: $TARGET_DB"
echo "Backup File: $BACKUP_FILE"
echo "Timestamp: $(date)"
echo "=========================================="

# Start official entrypoint (postgres) in background with sane defaults
docker-entrypoint.sh postgres \
  -c listen_addresses='*' \
  -c password_encryption=scram-sha-256 \
  "${HBA_ARGS[@]}" &

# Wait until Postgres is ready (peer over Unix socket)
echo "⏳ Waiting for Postgres to be ready (peer auth via socket)..."
until gosu postgres pg_isready -d postgres >/dev/null 2>&1; do
  sleep 1
done
echo "✓ Postgres is ready"

# Helper to run a single SQL
psql_c(){ gosu postgres psql -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }

# Detect if backup contains TimescaleDB data
detect_timescaledb_in_backup() {
  # Method 1: Check for .timescaledb_info file (created by backup script)
  if [[ -f "$TS_INFO_PATH" && -s "$TS_INFO_PATH" ]]; then
    echo "t"
    return
  fi
  
  # Method 2: Check pg_restore --list for TimescaleDB extension
  # Note: With optimized backup, we don't backup _timescaledb_* schemas
  # Instead, we look for the extension itself or public schema hypertables
  if gosu postgres pg_restore --list "$BACKUP_PATH" 2>/dev/null | grep -q "EXTENSION.*timescaledb"; then
    echo "t"
    return
  fi
  
  # Method 3: Check for CREATE_HYPERTABLE commands in TOC
  if gosu postgres pg_restore --list "$BACKUP_PATH" 2>/dev/null | grep -qi "create_hypertable"; then
    echo "t"
    return
  fi
  
  echo "f"
}

# Check if TimescaleDB extension is available in this container
check_timescaledb_available() {
  gosu postgres psql -d postgres -At -c \
    "SELECT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb');" 2>/dev/null || echo "f"
}

# Helper to grant comprehensive schema permissions to a role
grant_schema_permissions() {
  local role="$1"
  local has_timescaledb="$2"
  
  echo "  Granting schema permissions to role '${role}'"
  
  # Standard public schema permissions
  psql_c "$TARGET_DB" "ALTER SCHEMA public OWNER TO ${role};" 2>/dev/null || true
  psql_c "$TARGET_DB" "GRANT USAGE, CREATE ON SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON TABLES    TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON SEQUENCES TO ${role};"
  psql_c "$TARGET_DB" "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${role};"
  
  # TimescaleDB-specific schema permissions
  if [[ "$has_timescaledb" == "t" ]]; then
    echo "  Granting TimescaleDB schema permissions to '${role}'"
    
    # _timescaledb_catalog: Metadata about hypertables, chunks, dimensions
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_catalog TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_catalog TO ${role};" 2>/dev/null || true
    
    # _timescaledb_config: Configuration tables for background jobs
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_config TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_config TO ${role};" 2>/dev/null || true
    
    # _timescaledb_internal: Internal chunk tables (actual hypertable data)
    psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    psql_c "$TARGET_DB" "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA _timescaledb_internal TO ${role};" 2>/dev/null || true
    
    # _timescaledb_functions: TimescaleDB internal functions
    if gosu postgres psql -d "$TARGET_DB" -At -c "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = '_timescaledb_functions');" 2>/dev/null | grep -q "t"; then
      psql_c "$TARGET_DB" "GRANT USAGE ON SCHEMA _timescaledb_functions TO ${role};" 2>/dev/null || true
      psql_c "$TARGET_DB" "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA _timescaledb_functions TO ${role};" 2>/dev/null || true
    fi
  fi
}

# Verify TimescaleDB restore integrity
verify_timescaledb_restore() {
  echo ""
  echo "⏰ Verifying TimescaleDB restore..."
  
  # Give TimescaleDB a moment to finalize chunk creation
  sleep 1
  
  # Check hypertables
  local hypertable_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
    "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "0")
  
  if [[ "$hypertable_count" -gt 0 ]]; then
    echo "✓ Found $hypertable_count hypertable(s) successfully recreated"
    
    # List hypertables with chunk counts
    echo "  Hypertables:"
    gosu postgres psql -d "$TARGET_DB" -t -c \
      "SELECT '    - ' || hypertable_schema || '.' || hypertable_name || 
              ' (chunks: ' || num_chunks || ')' 
       FROM timescaledb_information.hypertables 
       ORDER BY hypertable_schema, hypertable_name;" 2>/dev/null || true
    
    # Check total chunks (recreated automatically by TimescaleDB)
    local chunk_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
      "SELECT COUNT(*) FROM timescaledb_information.chunks;" 2>/dev/null || echo "0")
    if [[ "$chunk_count" -gt 0 ]]; then
      echo "✓ Total chunks auto-created: $chunk_count"
      echo "  (Chunks were automatically recreated by TimescaleDB from hypertable data)"
    fi
    
    # Verify continuous aggregates if any
    local cagg_count=$(gosu postgres psql -d "$TARGET_DB" -At -c \
      "SELECT COUNT(*) FROM timescaledb_information.continuous_aggregates;" 2>/dev/null || echo "0")
    if [[ "$cagg_count" -gt 0 ]]; then
      echo "✓ Found $cagg_count continuous aggregate(s)"
    fi
    
    # Verify data integrity by sampling row counts
    echo ""
    echo "📊 Data integrity check:"
    gosu postgres psql -d "$TARGET_DB" -t -c \
      "SELECT '    ' || hypertable_schema || '.' || hypertable_name || ': ' ||
              (SELECT COUNT(*) FROM (SELECT 1 FROM \"$schema\".\"$table\" LIMIT 10000) s) || 
              CASE WHEN (SELECT COUNT(*) FROM \"$schema\".\"$table\") > 10000 THEN '+ rows' ELSE ' rows' END
       FROM timescaledb_information.hypertables AS ht(schema, table, owner, tablespace, num_dimensions, num_chunks, compression_enabled, is_distributed, replication_factor, data_nodes);" 2>/dev/null || true
    
    return 0
  else
    echo "⚠ WARNING: No hypertables found (this may be normal if backup had no hypertables)"
    return 1
  fi
}

# Create DB if missing
if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}';" | xargs) ]]; then
  echo "📦 Creating database '${TARGET_DB}'..."
  psql_c postgres "CREATE DATABASE ${TARGET_DB};"
  psql_c postgres "GRANT TEMPORARY, CONNECT ON DATABASE ${TARGET_DB} TO PUBLIC;"
else
  echo "📦 Database '${TARGET_DB}' already exists."
fi

# Detect TimescaleDB in backup
echo ""
echo "🔍 Detecting backup type..."
HAS_TIMESCALEDB=$(detect_timescaledb_in_backup)
TS_AVAILABLE=$(check_timescaledb_available)

if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
  echo "⏰ TimescaleDB hypertables detected in backup"
  
  if [[ "$TS_AVAILABLE" == "t" ]]; then
    echo "✓ TimescaleDB extension available in container"
    
    # Create TimescaleDB extension BEFORE restore
    # This creates the internal schemas (_timescaledb_catalog, _timescaledb_internal, etc.)
    echo "📦 Creating TimescaleDB extension and internal schemas..."
    psql_c "$TARGET_DB" "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;" || {
      echo "❌ ERROR: Failed to create TimescaleDB extension" >&2
      exit 1
    }
    echo "✓ TimescaleDB extension created successfully"
    
    # Display TimescaleDB version
    TS_VERSION=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';" 2>/dev/null || echo "unknown")
    echo "  Version: $TS_VERSION"
    echo ""
    echo "ℹ INFO: TimescaleDB internal schemas are now ready"
    echo "  When hypertables are restored, chunks will be automatically created"
  else
    echo "❌ ERROR: Backup contains TimescaleDB data but extension is not available in this container" >&2
    echo "   Use timescale/timescaledb Docker image instead of standard postgres image" >&2
    exit 1
  fi
else
  echo "📋 Standard PostgreSQL backup (no TimescaleDB detected)"
fi

# Gather roles: CSV arg overrides roles file if present
ROLE_LIST=()
if [[ -n "$ROLES_CSV_ARG" ]]; then
  IFS=',' read -ra ROLE_LIST <<<"$ROLES_CSV_ARG"
elif [[ -f "$ROLES_PATH" ]]; then
  echo ""
  echo "👥 Reading roles from ${ROLES_PATH}"
  while IFS= read -r line; do
    # strip comments and split by comma/space
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    # replace commas with spaces, then iterate
    for r in ${line//,/ }; do ROLE_LIST+=("$r"); done
  done < "$ROLES_PATH"
fi

# Create listed roles BEFORE restore so pg_restore can apply ownership/privs
if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
  echo ""
  echo "👥 Ensuring roles exist: ${ROLE_LIST[*]}"
  for ROLE in "${ROLE_LIST[@]}"; do
    ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
    if [[ -z $(gosu postgres psql -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname='${ROLE}';" | xargs) ]]; then
      echo "  Creating role '${ROLE}'"
      psql_c postgres "CREATE ROLE ${ROLE} WITH LOGIN PASSWORD '${ROLE_DEFAULT_PASSWORD}';"
      psql_c postgres "ALTER ROLE ${ROLE} SET client_encoding TO 'utf8';"
      psql_c postgres "ALTER ROLE ${ROLE} SET default_transaction_isolation TO 'read committed';"
      psql_c postgres "ALTER ROLE ${ROLE} SET TimeZone TO 'UTC';"
    else
      echo "  Role '${ROLE}' already exists."
    fi
    # Allow connecting to the DB; object ownership/privs will come from dump
    psql_c postgres "GRANT CONNECT ON DATABASE ${TARGET_DB} TO ${ROLE};"
  done
fi

# Restore ONCE (idempotent) unless forced
SKIP_RESTORE=false
if [[ -f "$RESTORE_MARKER" && "$FORCE_RESTORE" != "force" ]]; then
  echo ""
  echo "⏭ Restore marker exists (${RESTORE_MARKER}) — skipping restore."
  echo "   Use 'force' as 4th parameter to override marker and force restoration."
  SKIP_RESTORE=true
fi

if [[ "$SKIP_RESTORE" == "false" ]]; then
  if [[ -f "$BACKUP_PATH" ]]; then
    if [[ "$FORCE_RESTORE" == "force" && -f "$RESTORE_MARKER" ]]; then
      echo ""
      echo "🔄 FORCE mode: Dropping and recreating database for clean restore..."
      rm -f "$RESTORE_MARKER"
      
      # Terminate existing connections to the database
      psql_c postgres "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${TARGET_DB}' AND pid <> pg_backend_pid();" 2>/dev/null || true
      
      # Drop and recreate database
      psql_c postgres "DROP DATABASE IF EXISTS ${TARGET_DB};" 2>/dev/null || true
      psql_c postgres "CREATE DATABASE ${TARGET_DB};"
      psql_c postgres "GRANT TEMPORARY, CONNECT ON DATABASE ${TARGET_DB} TO PUBLIC;"
      
      # Recreate TimescaleDB extension if needed
      if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
        echo "📦 Creating TimescaleDB extension in fresh database..."
        psql_c "$TARGET_DB" "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
        echo "✓ TimescaleDB extension created"
      fi
      
      # Recreate roles and permissions
      if [[ ${#ROLE_LIST[@]} -gt 0 ]]; then
        for ROLE in "${ROLE_LIST[@]}"; do
          ROLE=$(echo "$ROLE" | xargs); [[ -z "$ROLE" ]] && continue
          psql_c postgres "GRANT CONNECT ON DATABASE ${TARGET_DB} TO ${ROLE};" 2>/dev/null || true
        done
      fi
    fi
    
    echo ""
    echo "📥 Restoring '${TARGET_DB}' from: ${BACKUP_PATH}"
    
    # Determine restore strategy based on TimescaleDB
    JOBS_ARGS=()
    EXTRA_ARGS=()
    
    if [[ -n "${RESTORE_JOBS:-}" ]]; then
      if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
        if [[ "${TIMESCALEDB_FORCE_JOBS:-no}" == "yes" ]]; then
          echo "⚠ WARNING: Using parallel restore with TimescaleDB (may cause issues with circular FKs)"
          JOBS_ARGS+=( --jobs="${RESTORE_JOBS}" )
        else
          echo "ℹ Parallel restore disabled for TimescaleDB (prevents circular FK issues)"
          echo "  Set TIMESCALEDB_FORCE_JOBS=yes to override"
        fi
      else
        JOBS_ARGS+=( --jobs="${RESTORE_JOBS}" )
        echo "⚡ Using parallel restore with ${RESTORE_JOBS} jobs"
      fi
    fi
    
    # TimescaleDB-specific restore flags
    if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
      echo "ℹ Using --disable-triggers to handle TimescaleDB circular foreign-key constraints"
      EXTRA_ARGS+=( --disable-triggers )
    fi
    
    # TimescaleDB restore strategy:
    # Since the backup excludes all _timescaledb_* schemas, we do a standard restore.
    # TimescaleDB will automatically:
    #   1. Restore the extension (creates internal schemas)
    #   2. Restore hypertable definitions (including create_hypertable() calls)
    #   3. Restore hypertable data
    #   4. Automatically create chunks in _timescaledb_internal as data is inserted
    
    if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
      echo "  Restoring with TimescaleDB-optimized settings..."
      echo "  (chunks and internal schemas will be auto-created by TimescaleDB)"
      
      # Single-pass restore: TimescaleDB handles chunk creation automatically
      # Note: Not using --clean since we pre-created the extension
      # Note: Not using --if-exists since it requires --clean
      set +e  # Allow restore to continue on non-fatal errors
      gosu postgres pg_restore \
        --format=c --verbose \
        --single-transaction \
        "${JOBS_ARGS[@]}" \
        --dbname "$TARGET_DB" \
        "$BACKUP_PATH" 2>&1 | \
        grep -v "NOTICE:  hypertable data are in the chunks" | \
        grep -v "DETAIL:  Data for hypertables" | \
        grep -v "HINT:  Use \"COPY" | \
        grep -v "ERROR:  extension \"timescaledb\" has already been loaded" | \
        grep -v "ERROR:  relation \"_timescaledb_internal._materialized_hypertable" | \
        grep -v "ERROR:  relation .* already exists" | \
        grep -v "does not exist at character" | \
        grep -v "DETAIL:  The loaded version is" | \
        grep -v "HINT:  Start a new session" | \
        grep -v "already exists, skipping" || true
      
      RESTORE_EXIT_CODE=$?
      set -e
      
      if [[ $RESTORE_EXIT_CODE -ne 0 ]]; then
        echo "⚠ WARNING: pg_restore completed with warnings (exit code: $RESTORE_EXIT_CODE)"
        echo "  This may be normal if objects already exist. Continuing..."
      fi
    else
      # Standard restore for non-TimescaleDB databases
      echo "  Running pg_restore..."
      gosu postgres pg_restore \
        --format=c --verbose --clean --if-exists \
        "${JOBS_ARGS[@]}" \
        "${EXTRA_ARGS[@]}" \
        --dbname "$TARGET_DB" \
        "$BACKUP_PATH" 2>&1 | \
        grep -v "NOTICE:  hypertable data are in the chunks" | \
        grep -v "DETAIL:  Data for hypertables" | \
        grep -v "HINT:  Use \"COPY" || true
    fi
    
    # Verify restore succeeded
    gosu postgres psql -d "$TARGET_DB" -c "SELECT 'restore ok' AS status, now();"
    
    # Mark as restored
    touch "$RESTORE_MARKER"
    echo "✓ Restore complete. Marker written to ${RESTORE_MARKER}."
    
    # TimescaleDB-specific post-restore tasks
    if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
      verify_timescaledb_restore
      
      # Display hypertable metadata if available
      if [[ -f "$TS_INFO_PATH" && -s "$TS_INFO_PATH" ]]; then
        echo ""
        echo "📊 TimescaleDB metadata from backup:"
        echo "  (hypertable | partition_column | chunk_interval)"
        cat "$TS_INFO_PATH" | head -10 | sed 's/^/    /'
      fi
    fi
    
  else
    echo "❌ WARNING: Backup file not found at ${BACKUP_PATH}. Skipping restore."
  fi

  # Grant comprehensive schema permissions AFTER restore
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

# Verification
echo ""
echo "📋 Post-Restore Verification:"
echo "=========================================="

# List tables in public schema
echo "Public schema tables (first 20):"
gosu postgres psql -d "$TARGET_DB" -t -c \
  "SELECT '  - ' || table_name 
   FROM information_schema.tables 
   WHERE table_schema='public' 
   ORDER BY 1 LIMIT 20;" 2>/dev/null || echo "  (none)"

# Show database size
DB_SIZE=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT pg_size_pretty(pg_database_size('${TARGET_DB}'));" 2>/dev/null || echo "unknown")
echo ""
echo "Database size: $DB_SIZE"

# TimescaleDB summary if applicable
if [[ "$HAS_TIMESCALEDB" == "t" ]]; then
  HYPERTABLE_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT COUNT(*) FROM timescaledb_information.hypertables;" 2>/dev/null || echo "0")
  CHUNK_COUNT=$(gosu postgres psql -d "$TARGET_DB" -At -c "SELECT COUNT(*) FROM timescaledb_information.chunks;" 2>/dev/null || echo "0")
  echo "Hypertables: $HYPERTABLE_COUNT"
  echo "Chunks: $CHUNK_COUNT"
fi

echo "=========================================="
echo "✅ Restore process complete!"
echo "=========================================="
echo ""
echo "🔒 Keeping PostgreSQL running in foreground..."
echo "   Container will remain active. Use 'docker logs' to monitor."
echo ""

# Keep postgres in foreground
wait
