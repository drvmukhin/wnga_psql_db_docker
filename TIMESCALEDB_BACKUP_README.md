# TimescaleDB Backup Script - Documentation

## Overview

The new script `psql_bkp_with_roles_docker_timescale.sh` is an enhanced version of the original backup script, specifically optimized for PostgreSQL databases that contain TimescaleDB hypertables.

## Key Improvements

### 1. **TimescaleDB Detection**
- Automatically detects if a database has the TimescaleDB extension installed
- Applies appropriate backup strategy based on database type

### 2. **Metadata Export**
- Exports TimescaleDB hypertable configuration to `.timescaledb_info` file
- Includes hypertable names, partition columns, and chunk intervals
- Useful for verification and restore planning

### 3. **Output Filtering**
The script handles two types of TimescaleDB-specific messages:

#### Notices (informational, not errors):
```
NOTICE: hypertable data are in the chunks, no data will be copied
DETAIL: Data for hypertables are stored in the chunks...
HINT: Use "COPY (SELECT * FROM <hypertable>) TO ..."
```
These are filtered out in verbose mode as they're expected behavior.

#### Warnings (expected for TimescaleDB):
```
warning: there are circular foreign-key constraints on this table:
detail: hypertable / chunk / continuous_agg
hint: You might not be able to restore the dump without using --disable-triggers...
```
These warnings are **expected** for TimescaleDB's catalog tables and don't indicate a problem. The circular FKs are part of TimescaleDB's internal structure.

### 4. **Backup Verification**
- After backup, verifies that TimescaleDB chunk tables are included
- Reports the number of chunks backed up
- Displays backup file sizes

### 5. **Quiet Mode**
- New `-q` flag for quiet operation
- Suppresses verbose pg_dump output while preserving errors/warnings
- Useful for automated/scheduled backups

## Usage

### Basic Usage (same as original)
```bash
./scripts/psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups
```

### Quiet Mode (recommended for production)
```bash
./scripts/psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups -q
```

### With Role Filtering
```bash
./scripts/psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -db wnga_auth -d ./backups -r "wnga,reporter"
```

### All Databases
```bash
./scripts/psql_bkp_with_roles_docker_timescale.sh -c pg17-ts -d ./backups
```

## Output Files

For each backed up database, the script creates:

1. **`<database>.bkp`** - PostgreSQL custom format dump
   - Contains all data including TimescaleDB chunks
   - Can be restored with `pg_restore`

2. **`<database>.roles`** - Role definitions
   - Comma-separated list of database roles
   - Used during restore to recreate role permissions

3. **`<database>.timescaledb_info`** (only for TimescaleDB databases)
   - Hypertable metadata
   - Partition configuration
   - Useful for verification

## What's Different from Original Script?

| Feature | Original Script | TimescaleDB Script |
|---------|----------------|-------------------|
| TimescaleDB detection | No | Yes, automatic |
| Metadata export | No | Yes, hypertable info |
| Output filtering | No | Yes, filters notices/expected warnings |
| Backup verification | No | Yes, verifies chunk count |
| Quiet mode | No | Yes, `-q` flag |
| Progress summary | Basic | Enhanced with sizes and TS markers |

## Understanding the Log Output

### Expected Warnings (Safe to Ignore)

These are **normal** for TimescaleDB databases:

```
pg_dump: warning: there are circular foreign-key constraints on this table:
pg_dump: detail: hypertable
pg_dump: hint: You might not be able to restore the dump without using --disable-triggers...
```

**Why?** TimescaleDB's internal catalog tables (`_timescaledb_catalog.hypertable`, `_timescaledb_catalog.chunk`, `_timescaledb_catalog.continuous_agg`) have circular foreign keys by design. This is part of their metadata structure.

**Impact on backup?** None. The data is backed up correctly.

**Impact on restore?** pg_restore handles this automatically with the custom format (`-F c`).

### Expected Notices (Safe to Ignore)

```
pg_dump: NOTICE: hypertable data are in the chunks, no data will be copied
DETAIL: Data for hypertables are stored in the chunks of a hypertable...
```

**Why?** When pg_dump encounters a hypertable (the parent table), it reminds you that the actual data is in chunk tables, not the parent.

**Impact?** None. The script dumps the chunks, which contain all the data. This is just pg_dump being informative.

## Backup Integrity

The script ensures backup integrity by:

1. **Using custom format** (`-F c`): Best for PostgreSQL backups
   - Compressed automatically
   - Allows selective restore
   - Handles large objects
   - Proper dependency ordering

2. **Including large objects** (`-b` flag)

3. **Verifying chunk backup**: Counts chunk tables in the backup file

4. **Exit on error**: `set -Eeuo pipefail` ensures script fails fast on any error

## Restore Considerations

When restoring a TimescaleDB backup:

1. **TimescaleDB must be installed** in the target database first
2. **Use the appropriate restore script** (check `psql_restore_db_with_roles_compose.sh`)
3. **Restore will handle**:
   - Extension recreation
   - Hypertable structure
   - Chunk data
   - Constraints and triggers

Example restore command:
```bash
pg_restore -d target_database -F c -v database.bkp
```

## Troubleshooting

### "Container not running"
```
❌ Container 'pg17-ts' is not running
```
**Solution**: Start your Docker container first
```bash
docker start pg17-ts
```

### "Permission denied"
**Solution**: Make script executable
```bash
chmod +x scripts/psql_bkp_with_roles_docker_timescale.sh
```

### Actual Errors to Watch For

**Real problems** that need attention:
- `ERROR: permission denied` - Database permission issues
- `FATAL: database does not exist` - Wrong database name
- `ERROR: could not connect` - Container networking issues
- Disk space errors

## Performance Tips

1. **Use quiet mode** (`-q`) for regular/scheduled backups to reduce output
2. **Backup to fast storage** - pg_dump is I/O intensive
3. **Consider parallel dumps** for very large databases (requires modifications)
4. **Regular backup testing** - periodically verify backups can be restored

## Migration from Original Script

You can continue using the original script. This new script is fully backward compatible but optimized for TimescaleDB. Benefits of switching:

- ✓ Better output clarity
- ✓ Verification of TimescaleDB data
- ✓ Metadata export for documentation
- ✓ Quiet mode for automation
- ✓ Better progress reporting

## Support for Mixed Databases

The script automatically handles:
- Pure PostgreSQL databases (no TimescaleDB)
- TimescaleDB databases with hypertables
- Databases with both regular tables and hypertables
- Multiple databases in one backup run

Each database is analyzed independently and backed up with the appropriate strategy.
