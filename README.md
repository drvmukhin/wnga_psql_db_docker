# WNGA Posgress DB Docker Compose

_This is a Developer branch_

## How to use

1. Put these in `initdb/` next to your compose:

```
initdb/
  wnga_auth_full_08092025.bkp
  wnga_auth.roles      # e.g. "wnga,reporter"
```

2. In `docker-compose.yml`:

```yaml
command: ["/scripts/psql_restore_db_with_roles_compose.sh", "wnga_auth", "wnga_auth_full_08092025.bkp"]
environment:
  POSTGRES_USER: postgres
  POSTGRES_PASSWORD_FILE: /run/secrets/pg_password
  HBA_FILE: /etc/postgresql/pg_hba_custom.conf
  ROLE_DEFAULT_PASSWORD: kindzadza   # change me
  RESTORE_JOBS: "4"                  # optional
volumes:
  - ./pg_hba.conf:/etc/postgresql/pg_hba_custom.conf:ro
  - ./initdb:/docker-entrypoint-initdb.d:ro
  - ./scripts/psql_restore_db_with_roles_compose.sh:/scripts/psql_restore_db_with_roles_compose.sh:ro
```

3. Bring it up / down:

```bash
docker compose down
docker compose down -v  # ATTENTION: Stop and unmount docker volume. Cleans up persistent storage
docker compose up -d
docker logs -f pg17
```

You’ll see: roles created (from file), restore run once, then a quick table listing.

4. In case if you are facing issue with migration try to assign permissions to the schema 'public' manually.
- Connect to psql console (psql_console.sh)
- # \c <your_db_name>
- Execute:
```sql
ALTER SCHEMA public OWNER TO wnga;
GRANT USAGE, CREATE ON SCHEMA public TO wnga;

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO wnga;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO wnga;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO wnga;

ALTER DEFAULT PRIVILEGES FOR ROLE wnga IN SCHEMA public
  GRANT ALL ON TABLES    TO wnga;
ALTER DEFAULT PRIVILEGES FOR ROLE wnga IN SCHEMA public
  GRANT ALL ON SEQUENCES TO wnga;
ALTER DEFAULT PRIVILEGES FOR ROLE wnga IN SCHEMA public
  GRANT ALL ON FUNCTIONS TO wnga;
```
