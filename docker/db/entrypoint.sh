#!/usr/bin/env bash
set -Eeuo pipefail

render_runtime_config() {
  mkdir -p /etc/postgresql/custom
  envsubst < /etc/postgresql/templates/postgresql.conf.template > /etc/postgresql/custom/postgresql.conf
  envsubst < /etc/postgresql/templates/pg_hba.conf.template > /etc/postgresql/custom/pg_hba.conf
}

resolve_password_file() {
  if [[ -n "${DB_PASSWORD_FILE:-}" ]]; then
    if [[ ! -f "${DB_PASSWORD_FILE}" ]]; then
      echo "DB_PASSWORD_FILE does not exist: ${DB_PASSWORD_FILE}" >&2
      exit 1
    fi

    export POSTGRES_PASSWORD
    POSTGRES_PASSWORD="$(< "${DB_PASSWORD_FILE}")"
  fi
}

validate_ssl_files() {
  if [[ "${PG_SSL:-off}" != "on" ]]; then
    return 0
  fi

  if [[ ! -f "${PG_SSL_CERT_FILE}" ]]; then
    echo "Missing SSL certificate: ${PG_SSL_CERT_FILE}" >&2
    exit 1
  fi

  if [[ ! -f "${PG_SSL_KEY_FILE}" ]]; then
    echo "Missing SSL key: ${PG_SSL_KEY_FILE}" >&2
    exit 1
  fi

  chmod 600 "${PG_SSL_KEY_FILE}" || true
}

if [[ "${1:-}" == "postgres" ]]; then
  resolve_password_file
  render_runtime_config
  validate_ssl_files

  set -- postgres \
    -c config_file=/etc/postgresql/custom/postgresql.conf \
    -c hba_file=/etc/postgresql/custom/pg_hba.conf
fi

exec docker-entrypoint.sh "$@"
