# Operations Runbook

## Before production

- Change `POSTGRES_PASSWORD`.
- Or use `DB_PASSWORD_FILE` with a secret mounted from `SECRETS_HOST_DIR`.
- Restrict `PG_ALLOWED_CIDRS` to the minimum required network ranges.
- Move `BACKUP_HOST_DIR` to a persistent folder outside the repository.
- Decide whether TLS is required and, if so, mount certificate files and set `PG_SSL=on`.
- Validate backup and restore in a non-production environment before first deployment.
- Plan for separate roles: one admin superuser and one limited application role.

## LAN access

The current local host was detected on:

- IPv4 address: `192.168.10.247`
- LAN subnet: `192.168.10.0/24`

The current `.env` is configured to:

- publish PostgreSQL on all host interfaces with `DB_BIND_ADDRESS=0.0.0.0`
- allow PostgreSQL client authentication from `192.168.10.0/24`
- allow internal Docker service-to-service authentication from `172.16.0.0/12`
- require the host firewall to allow inbound TCP `5432` from `192.168.10.0/24`

Clients on the same LAN can connect with:

```text
host=192.168.10.247 port=5432
```

If the host IP changes later, update the client connection target. If the LAN subnet changes, update `PG_ALLOWED_CIDRS` and restart the stack. Keep the Docker bridge range in that list unless you also change how the backup and restore services connect.

Example Windows firewall command to run in an elevated PowerShell session:

```powershell
New-NetFirewallRule -DisplayName 'production-db Postgres 5432 LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5432 -RemoteAddress 192.168.10.0/24
```

## Role model

`POSTGRES_USER` controls the initial PostgreSQL superuser role created inside the cluster.

Example:

```env
POSTGRES_USER=production_admin
```

With that configuration:

- `production_admin` is the main PostgreSQL admin role
- the PostgreSQL server process still runs as the operating-system user `postgres`
- a database role named `postgres` is not required and may not exist

Recommended production pattern:

- admin superuser: used for maintenance, extension changes, backup/restore, upgrades, and operational access
- application role: used by the app, limited to only the schema/database permissions it actually needs

Do not give the application superuser access unless you intentionally want the app to control the entire server.

## Create a new database

If you are already connected to the `postgres` database in a GUI tool such as pgAdmin, run:

```sql
CREATE DATABASE TARGET_DATABASE OWNER TARGET_OWNER;
```

If the owner role does not exist yet, create it first, then run the database creation as a separate execution:

```sql
CREATE ROLE TARGET_OWNER LOGIN PASSWORD 'TARGET_PASSWORD';
```

```sql
CREATE DATABASE TARGET_DATABASE OWNER TARGET_OWNER;
```

In `psql`, connect to `postgres` first and then run the same `CREATE DATABASE` command:

```sql
\c postgres
CREATE DATABASE TARGET_DATABASE OWNER TARGET_OWNER;
```

Placeholder mapping:

- replace `TARGET_DATABASE` with the database name to create
- replace `TARGET_OWNER` with the role that should own that database

Notes:

- `CREATE DATABASE` cannot run inside a transaction block.
- In pgAdmin, keep auto-commit enabled or run `CREATE ROLE` and `CREATE DATABASE` separately.
- `\c postgres` is a `psql` meta-command, not SQL.

## Adding users with different permissions

Use `production_admin` or your configured admin role to create additional login roles.

Placeholder mapping used below:

- replace `TARGET_USERNAME` with the login role you want to create
- replace `TARGET_PASSWORD` with that user's password
- replace `TARGET_DATABASE` with the database this user should access

### Three common user types

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

Read-only user:

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

### Notes

- These examples exclude PostgreSQL system schemas such as `pg_catalog`, `information_schema`, and `pg_toast`.
- The app and read-only examples grant access across all existing non-system schemas in `TARGET_DATABASE`.
- The default-privilege statements apply to future objects created by the role running the script.
- If another role later creates a new schema or new objects, rerun the grant block or add matching default privileges for that creator.
- If you need true ownership-level DDL control over existing objects owned by other roles, transfer ownership separately.
- A role can still connect to another database if that database grants `CONNECT` to `PUBLIC`; enforce one-database-only access by reviewing and tightening database-level `CONNECT` grants.
- Do not use `SUPERUSER` for normal application traffic.

## Start and stop

Start:

```powershell
docker compose up -d --build
```

Stop:

```powershell
docker compose down
```

Stop and remove the data volume:

```powershell
docker compose down -v
```

## Health and inspection

```powershell
docker compose ps
docker compose logs db --tail 100
docker compose logs backup --tail 100
docker compose exec db pg_isready -U production_admin -d production_app
```

The backup service also performs post-start maintenance. If extension creation or auto-upgrade fails, the relevant details will be in the backup service logs.

## Manual backup

```powershell
docker compose exec backup /usr/local/bin/run-backup.sh
```

## Restore

Latest:

```powershell
docker compose run --rm restore latest --yes
```

Specific backup:

```powershell
docker compose run --rm restore 2026-03-23/020000 --yes
```

Before restore, stop application writes or put the application into maintenance mode.

## Major version upgrade

1. Trigger and verify a fresh backup.
2. Leave the old data volume untouched.
3. Change `POSTGRES_VERSION`, `POSTGRES_MAJOR`, and `POSTGRES_VOLUME_NAME`.
4. Rebuild and start the new stack.
5. Restore the latest validated backup.
6. Let the post-start maintenance job run and verify in the backup logs that extension upgrades completed successfully.
7. Run application and schema validation.
8. Remove the old volume only after cutover is confirmed.

## Backup model

This repository uses logical backups:

- database dump: `pg_dump -Fc`
- globals dump: `pg_dumpall --globals-only`

This supports restoring to the time of each backup. It is not point-in-time recovery between backups. If you need PITR, add WAL archiving and a tested recovery process.

## Validation

Run the isolated validation pass:

```powershell
.\scripts\validate-stack.ps1
```
