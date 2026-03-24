#!/usr/bin/env bash
set -Eeuo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

resolve_postgres_password() {
  if [[ -n "${DB_PASSWORD_FILE:-}" && -f "${DB_PASSWORD_FILE}" ]]; then
    cat "${DB_PASSWORD_FILE}"
    return
  fi

  if [[ -n "${POSTGRES_PASSWORD_FILE:-}" && -f "${POSTGRES_PASSWORD_FILE}" ]]; then
    cat "${POSTGRES_PASSWORD_FILE}"
    return
  fi

  printf '%s' "${POSTGRES_PASSWORD:-}"
}

export_pgpassword() {
  export PGPASSWORD
  PGPASSWORD="$(resolve_postgres_password)"

  if [[ -z "${PGPASSWORD}" ]]; then
    echo "POSTGRES_PASSWORD is required for backup and restore operations." >&2
    exit 1
  fi
}

wait_for_db() {
  local attempts="${1:-60}"
  local delay_seconds="${2:-2}"
  local attempt=1

  while (( attempt <= attempts )); do
    if pg_isready \
      -h "${POSTGRES_HOST}" \
      -p "${POSTGRES_PORT}" \
      -U "${POSTGRES_USER}" \
      -d "${POSTGRES_DB}" >/dev/null 2>&1; then
      return 0
    fi

    sleep "${delay_seconds}"
    ((attempt++))
  done

  echo "Database did not become ready in time." >&2
  exit 1
}

latest_backup_id() {
  local latest

  latest="$(find "${BACKUP_CONTAINER_DIR}" -mindepth 2 -maxdepth 2 -type d | LC_ALL=C sort | tail -n 1)"

  if [[ -z "${latest}" ]]; then
    echo "No backups found in ${BACKUP_CONTAINER_DIR}" >&2
    exit 1
  fi

  printf '%s' "${latest#${BACKUP_CONTAINER_DIR}/}"
}
