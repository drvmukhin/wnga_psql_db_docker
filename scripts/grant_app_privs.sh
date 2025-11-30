#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   grant_app_privs.sh <container> <database> <role> [schemas]
# Examples:
#   grant_app_privs.sh pg17 wnga_auth wnga
#   grant_app_privs.sh pg17 wnga_auth wnga "public other_schema"
#
# Notes:
# - The role must already exist.

CONTAINER="${1:-}"; DB="${2:-}"; ROLE="${3:-}"; SCHEMAS="${4:-public}"
if [[ -z "$CONTAINER" || -z "$DB" || -z "$ROLE" ]]; then
  echo "Usage: $0 <container> <database> <role> [schemas]" >&2
  exit 1
fi

echo "Applying ownership & privileges on DB='$DB' for ROLE='$ROLE' in schemas: $SCHEMAS"
for S in $SCHEMAS; do
  echo "  -> Schema: $S"
  docker exec -i "$CONTAINER" gosu postgres psql -v ON_ERROR_STOP=1 -d "$DB" \
    -v schema="$S" -v role="$ROLE" -f - <<'SQL'
ALTER SCHEMA :"schema" OWNER TO :"role";
GRANT USAGE, CREATE ON SCHEMA :"schema" TO :"role";

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname = current_setting('psql.schema')
  LOOP EXECUTE format('ALTER TABLE %I.%I OWNER TO %I;', r.schemaname, r.tablename, current_setting('psql.role')); END LOOP;

  FOR r IN SELECT sequence_schema, sequence_name FROM information_schema.sequences WHERE sequence_schema = current_setting('psql.schema')
  LOOP EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I;', r.sequence_schema, r.sequence_name, current_setting('psql.role')); END LOOP;

  FOR r IN SELECT schemaname, viewname FROM pg_views WHERE schemaname = current_setting('psql.schema')
  LOOP EXECUTE format('ALTER VIEW %I.%I OWNER TO %I;', r.schemaname, r.viewname, current_setting('psql.role')); END LOOP;

  FOR r IN SELECT schemaname, matviewname FROM pg_matviews WHERE schemaname = current_setting('psql.schema')
  LOOP EXECUTE format('ALTER MATERIALIZED VIEW %I.%I OWNER TO %I;', r.schemaname, r.matviewname, current_setting('psql.role')); END LOOP;

  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = current_setting('psql.schema')
  LOOP EXECUTE format('ALTER FUNCTION %s OWNER TO %I;', r.sig, current_setting('psql.role')); END LOOP;

  FOR r IN SELECT n.nspname, t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = current_setting('psql.schema') AND t.typtype IN ('c','e','d')
  LOOP EXECUTE format('ALTER TYPE %I.%I OWNER TO %I;', r.nspname, r.typname, current_setting('psql.role')); END LOOP;
END$$ LANGUAGE plpgsql
SET psql.schema TO :'schema', psql.role TO :'role';

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA :"schema" TO :"role";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA :"schema" TO :"role";
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA :"schema" TO :"role";

ALTER DEFAULT PRIVILEGES FOR ROLE :"role" IN SCHEMA :"schema" GRANT ALL ON TABLES    TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role" IN SCHEMA :"schema" GRANT ALL ON SEQUENCES TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role" IN SCHEMA :"schema" GRANT ALL ON FUNCTIONS TO :"role";
SQL
done

echo "Verifying tables in '$DB'..."
docker exec -it "$CONTAINER" gosu postgres psql -d "$DB" -c "\\dt"
echo "Done."
