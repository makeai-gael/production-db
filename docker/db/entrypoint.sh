#!/usr/bin/env bash
set -Eeuo pipefail

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

build_pg_hba_allowed_rules() {
  local cidr_list
  local cidr

  cidr_list="${PG_ALLOWED_CIDRS:-${PG_ALLOWED_CIDR:-}}"

  if [[ -z "$(trim_whitespace "${cidr_list//,/}")" ]]; then
    echo "PG_ALLOWED_CIDRS (or legacy PG_ALLOWED_CIDR) is required." >&2
    exit 1
  fi

  export PG_HBA_ALLOWED_RULES=""

  while IFS= read -r cidr || [[ -n "${cidr}" ]]; do
    cidr="$(trim_whitespace "${cidr}")"

    if [[ -z "${cidr}" ]]; then
      continue
    fi

    PG_HBA_ALLOWED_RULES+="host    all             all             ${cidr}      scram-sha-256"$'\n'
    PG_HBA_ALLOWED_RULES+="host    replication     all             ${cidr}      scram-sha-256"$'\n'
  done < <(printf '%s' "${cidr_list}" | tr ',' '\n')

  if [[ -z "${PG_HBA_ALLOWED_RULES}" ]]; then
    echo "No valid CIDRs were found in PG_ALLOWED_CIDRS." >&2
    exit 1
  fi
}

render_runtime_config() {
  mkdir -p /etc/postgresql/custom
  build_pg_hba_allowed_rules
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
