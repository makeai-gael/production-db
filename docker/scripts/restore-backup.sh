#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/bin/common.sh

require_env POSTGRES_HOST
require_env POSTGRES_PORT
require_env POSTGRES_DB
require_env POSTGRES_USER
require_env BACKUP_CONTAINER_DIR

backup_selector="${1:-latest}"
confirmation="${2:-}"

if [[ "${confirmation}" != "--yes" ]]; then
  echo "Restore requires explicit confirmation: restore <backup-id|latest> --yes" >&2
  exit 1
fi

export_pgpassword
wait_for_db

if [[ "${backup_selector}" == "latest" ]]; then
  backup_id="$(latest_backup_id)"
else
  backup_id="${backup_selector}"
fi

backup_dir="${BACKUP_CONTAINER_DIR}/${backup_id}"

if [[ ! -d "${backup_dir}" ]]; then
  echo "Backup directory not found: ${backup_dir}" >&2
  exit 1
fi

dump_file="$(find "${backup_dir}" -maxdepth 1 -type f -name '*.dump' | LC_ALL=C sort | head -n 1)"

if [[ -z "${dump_file}" ]]; then
  echo "No dump file found in ${backup_dir}" >&2
  exit 1
fi

if [[ -f "${backup_dir}/globals.sql" ]]; then
  echo "Applying globals.sql on a best-effort basis."
  psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" \
    -d postgres \
    -f "${backup_dir}/globals.sql" || true
fi

psql \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  -d postgres \
  -v ON_ERROR_STOP=1 \
  -v db_name="${POSTGRES_DB}" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'db_name'
  AND pid <> pg_backend_pid();
SQL

dropdb \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  --if-exists \
  "${POSTGRES_DB}"

createdb \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  -O "${POSTGRES_USER}" \
  "${POSTGRES_DB}"

pg_restore \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  "${dump_file}"

echo "Restore complete: ${backup_id}"
