# production-db

Single-node, production-oriented PostgreSQL stack with:

- pinned PostgreSQL and pgvector versions
- named data volume for safer upgrades
- env-driven runtime configuration
- optional file-based secret support
- automatic post-start extension maintenance across databases
- built-in `pg_stat_statements` support
- automatic scheduled backups to a host folder
- one-command restore from a dated backup
- health checks and operational documentation

## Current pinned versions

- PostgreSQL `18.3`
- pgvector `0.8.2`

PostgreSQL `18.3` is the latest official PostgreSQL release as of February 26, 2026, based on the PostgreSQL release announcement. pgvector `0.8.2` is the current version referenced by the upstream pgvector installation documentation.

## Quick start

1. Review and update `.env`.
2. Start the stack:

```powershell
docker compose up -d --build
```

3. Confirm health:

```powershell
docker compose ps
docker compose logs db --tail 100
```

4. Connect:

```powershell
docker compose exec db psql -U production_admin -d production_app
```

## Services

- `db`: PostgreSQL 18.3 with pgvector and env-rendered configuration
- `backup`: scheduled logical backups written to `BACKUP_HOST_DIR` and post-start maintenance
- `restore`: one-off restore service for replaying a selected backup

## Backup flow

Automatic backups are scheduled with `BACKUP_CRON` and stored under:

```text
BACKUP_HOST_DIR/YYYY-MM-DD/HHMMSS/
```

Each backup folder contains:

- `<database>.dump`
- `globals.sql`
- `metadata.env`

Run a backup immediately:

```powershell
docker compose exec backup /usr/local/bin/run-backup.sh
```

List local backup folders:

```powershell
Get-ChildItem -Recurse .\backups
```

## Restore flow

Restore the latest backup:

```powershell
docker compose run --rm restore latest --yes
```

Restore a specific backup:

```powershell
docker compose run --rm restore 2026-03-23/020000 --yes
```

The restore command:

- waits for the database to be healthy
- should be run while application writes are stopped
- terminates active sessions on the target database
- drops and recreates the target database
- reapplies `globals.sql` on a best-effort basis
- restores the selected `.dump`

## Production notes

- Do not expose the published database port publicly unless you intend to.
- Keep `.env` out of version control.
- Change `POSTGRES_PASSWORD` before using this outside local testing.
- Or set `DB_PASSWORD_FILE=/run/secrets/postgres_password.txt` and place the secret in `SECRETS_HOST_DIR`.
- Restrict `PG_ALLOWED_CIDR` to the exact network(s) that need database access.
- The current local configuration publishes PostgreSQL on all host interfaces and restricts PostgreSQL clients to the detected LAN subnet `192.168.10.0/24`.
- The host firewall must also allow inbound TCP `5432` from `192.168.10.0/24`.
- Logical backups let you restore to backup timestamps. If you need point-in-time recovery between backups, add WAL archiving and PITR.
- Major PostgreSQL upgrades must use a new data volume and a controlled cutover. Do not just change the image version and reuse the old volume.

## Users and roles

There are two different `postgres` concepts:

- the container operating-system user `postgres`, which still runs the PostgreSQL server process
- the PostgreSQL database role created at initialization, which is controlled by `POSTGRES_USER`

This stack currently sets:

```env
POSTGRES_USER=production_admin
```

That means:

- the database superuser is `production_admin`
- the server process still runs as the OS user `postgres`
- a database role literally named `postgres` may not exist unless you create it yourself

For production use:

- keep one admin superuser for operations, upgrades, maintenance, backup, restore, and extension management
- create a separate application role with only the privileges the app needs
- do not run the application as the superuser

### Example role patterns

Ready-to-run examples for the three common user types.

Placeholder mapping used below:

- replace `TARGET_USERNAME` with the login role you want to create
- replace `TARGET_PASSWORD` with that user's password
- replace `TARGET_DATABASE` with the database this user should access

Superadmin:

```sql
CREATE ROLE TARGET_USERNAME LOGIN PASSWORD 'TARGET_PASSWORD' SUPERUSER;
```

App user with broad access inside one database:

```sql
CREATE ROLE TARGET_USERNAME LOGIN PASSWORD 'TARGET_PASSWORD';
GRANT CONNECT, TEMP ON DATABASE TARGET_DATABASE TO TARGET_USERNAME;

\c TARGET_DATABASE

DO $$
DECLARE
  schema_name text;
BEGIN
  FOR schema_name IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog', 'information_schema')
      AND nspname NOT LIKE 'pg_toast%'
  LOOP
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I', schema_name, 'TARGET_USERNAME');
  END LOOP;
END $$;
```

Read-only user across one database:

```sql
CREATE ROLE TARGET_USERNAME LOGIN PASSWORD 'TARGET_PASSWORD';
GRANT CONNECT ON DATABASE TARGET_DATABASE TO TARGET_USERNAME;

\c TARGET_DATABASE

DO $$
DECLARE
  schema_name text;
BEGIN
  FOR schema_name IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog', 'information_schema')
      AND nspname NOT LIKE 'pg_toast%'
  LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', schema_name, 'TARGET_USERNAME');
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', schema_name, 'TARGET_USERNAME');
  END LOOP;
END $$;
```

Notes:

- These examples exclude PostgreSQL system schemas such as `pg_catalog`, `information_schema`, and `pg_toast`.
- The app and read-only examples grant access across all existing non-system schemas in `TARGET_DATABASE`.
- The default-privilege statements apply to future objects created by the role running the script.
- If another role later creates a new schema or new objects, rerun the grant block or add matching default privileges for that creator.
- If you need true ownership-level DDL control over existing objects owned by other roles, transfer ownership separately.
- A role can still connect to another database if that database grants `CONNECT` to `PUBLIC`; enforce one-database-only access by reviewing and tightening database-level `CONNECT` grants.
- Use the admin superuser only for cluster administration, extension management, backup and restore, and version upgrades.

## Automatic extension maintenance

On every stack start, the backup service runs a maintenance pass after the database becomes healthy. That pass can:

- create `pg_stat_statements` in every non-template database when enabled
- upgrade installed extensions to their default version when an update path exists

This is controlled by:

- `ENABLE_PG_STAT_STATEMENTS`
- `AUTO_CREATE_PG_STAT_STATEMENTS`
- `AUTO_UPGRADE_EXTENSIONS`

## Upgrade runbook

1. Trigger a fresh backup.
2. Keep the old data volume unchanged.
3. Update `POSTGRES_VERSION`, `POSTGRES_MAJOR`, and `POSTGRES_VOLUME_NAME`.
4. Start the new stack on a fresh volume.
5. Restore the latest validated backup.
6. If `PGVECTOR_VERSION` changed, run `ALTER EXTENSION vector UPDATE;` in each database that uses pgvector.
7. Validate application behavior before removing the old volume.

## Files

- `docker-compose.yml`: stack definition
- `Dockerfile`: pinned PostgreSQL image with pgvector
- `docker/db/*`: runtime entrypoint and configuration templates
- `docker/initdb/*`: first-boot initialization scripts
- `docker/scripts/*`: backup and restore scripts
- `scripts/validate-stack.ps1`: isolated validation run for build, startup, maintenance, backup, and restore
- `docs/OPERATIONS.md`: operational runbook
