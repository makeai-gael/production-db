#!/usr/bin/env bash
set -Eeuo pipefail

source /usr/local/bin/common.sh

require_env POSTGRES_HOST
require_env POSTGRES_PORT
require_env POSTGRES_DB
require_env POSTGRES_USER
require_env BACKUP_CONTAINER_DIR
require_env BACKUP_RETENTION_DAYS

export_pgpassword
wait_for_db

backup_id="$(date +%F)/$(date +%H%M%S)"
backup_dir="${BACKUP_CONTAINER_DIR}/${backup_id}"

mkdir -p "${backup_dir}"

server_version="$(
  psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -Atqc "SHOW server_version;"
)"

pg_dump \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  --format=custom \
  --compress=9 \
  --file "${backup_dir}/${POSTGRES_DB}.dump"

pg_dumpall \
  -h "${POSTGRES_HOST}" \
  -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" \
  --globals-only > "${backup_dir}/globals.sql"

cat > "${backup_dir}/metadata.env" <<EOF
BACKUP_ID=${backup_id}
BACKUP_CREATED_AT=$(date --iso-8601=seconds)
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_SERVER_VERSION=${server_version}
DUMP_FORMAT=custom
EOF

find "${BACKUP_CONTAINER_DIR}" -mindepth 2 -maxdepth 2 -type d -mtime +"${BACKUP_RETENTION_DAYS}" -exec rm -rf {} +
find "${BACKUP_CONTAINER_DIR}" -mindepth 1 -maxdepth 1 -type d -empty -delete

echo "Backup complete: ${backup_id}"
