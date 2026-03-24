#!/usr/bin/env bash
set -Eeuo pipefail

write_env_file() {
  cat > /usr/local/bin/backup-cron.env <<EOF
export TZ=$(printf '%q' "${TZ:-UTC}")
export POSTGRES_HOST=$(printf '%q' "${POSTGRES_HOST:-db}")
export POSTGRES_PORT=$(printf '%q' "${POSTGRES_PORT:-5432}")
export POSTGRES_DB=$(printf '%q' "${POSTGRES_DB}")
export POSTGRES_USER=$(printf '%q' "${POSTGRES_USER}")
export POSTGRES_PASSWORD=$(printf '%q' "${POSTGRES_PASSWORD:-}")
export DB_PASSWORD_FILE=$(printf '%q' "${DB_PASSWORD_FILE:-}")
export BACKUP_CONTAINER_DIR=$(printf '%q' "${BACKUP_CONTAINER_DIR:-/backups}")
export BACKUP_RETENTION_DAYS=$(printf '%q' "${BACKUP_RETENTION_DAYS:-14}")
EOF
  chmod 600 /usr/local/bin/backup-cron.env
}

write_cron_file() {
  cat > /etc/cron.d/db-backup <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=${TZ:-UTC}
${BACKUP_CRON:-0 2 * * *} root . /usr/local/bin/backup-cron.env && /usr/local/bin/run-backup.sh >> /proc/1/fd/1 2>> /proc/1/fd/2
EOF
  chmod 0644 /etc/cron.d/db-backup
}

mkdir -p "${BACKUP_CONTAINER_DIR:-/backups}"

write_env_file
write_cron_file

if [[ "${AUTO_UPGRADE_EXTENSIONS:-true}" == "true" || "${AUTO_CREATE_PG_STAT_STATEMENTS:-true}" == "true" ]]; then
  /usr/local/bin/run-post-start-maintenance.sh
fi

if [[ "${BACKUP_RUN_ON_START:-false}" == "true" ]]; then
  /usr/local/bin/run-backup.sh
fi

exec cron -f
