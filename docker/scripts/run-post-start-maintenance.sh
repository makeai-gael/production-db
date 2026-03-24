#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/bin/common.sh

require_env POSTGRES_HOST
require_env POSTGRES_PORT
require_env POSTGRES_USER
require_env POSTGRES_DB

export_pgpassword
wait_for_db

mapfile -t databases < <(
  psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" \
    -d postgres \
    -Atqc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;"
)

for database_name in "${databases[@]}"; do
  echo "Running post-start maintenance for database: ${database_name}"

  if [[ "${ENABLE_PG_STAT_STATEMENTS:-true}" == "true" && "${AUTO_CREATE_PG_STAT_STATEMENTS:-true}" == "true" ]]; then
    psql \
      -h "${POSTGRES_HOST}" \
      -p "${POSTGRES_PORT}" \
      -U "${POSTGRES_USER}" \
      -d "${database_name}" \
      -v ON_ERROR_STOP=1 \
      -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
  fi

  if [[ "${AUTO_UPGRADE_EXTENSIONS:-true}" == "true" ]]; then
    upgrade_sql="$(
      psql \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${database_name}" \
        -Atqc "SELECT format('ALTER EXTENSION %I UPDATE;', e.extname) FROM pg_extension e JOIN pg_available_extensions a ON a.name = e.extname WHERE e.extname <> 'plpgsql' AND a.installed_version IS NOT NULL AND a.default_version IS DISTINCT FROM a.installed_version ORDER BY e.extname;"
    )"

    if [[ -n "${upgrade_sql}" ]]; then
      printf '%s\n' "${upgrade_sql}" | psql \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${database_name}" \
        -v ON_ERROR_STOP=1
    fi
  fi
done

echo "Post-start maintenance complete."
