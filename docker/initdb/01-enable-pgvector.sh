#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${ENABLE_PGVECTOR:-true}" != "true" ]]; then
  exit 0
fi

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL
