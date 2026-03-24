ARG POSTGRES_VERSION=18.3
FROM postgres:${POSTGRES_VERSION}-bookworm

ARG POSTGRES_MAJOR=18
ARG PGVECTOR_VERSION=0.8.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cron \
        gettext-base \
        git \
        postgresql-server-dev-${POSTGRES_MAJOR} \
        tzdata \
    && git clone --branch "v${PGVECTOR_VERSION}" --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && make -C /tmp/pgvector \
    && make -C /tmp/pgvector install \
    && rm -rf /tmp/pgvector \
    && apt-get purge -y --auto-remove \
        build-essential \
        git \
        postgresql-server-dev-${POSTGRES_MAJOR} \
    && rm -rf /var/lib/apt/lists/*

COPY docker/db/entrypoint.sh /usr/local/bin/custom-postgres-entrypoint.sh
COPY docker/db/postgresql.conf.template /etc/postgresql/templates/postgresql.conf.template
COPY docker/db/pg_hba.conf.template /etc/postgresql/templates/pg_hba.conf.template
COPY docker/initdb/01-enable-pgvector.sh /docker-entrypoint-initdb.d/01-enable-pgvector.sh
COPY docker/scripts/common.sh /usr/local/bin/common.sh
COPY docker/scripts/run-backup.sh /usr/local/bin/run-backup.sh
COPY docker/scripts/backup-cron-entrypoint.sh /usr/local/bin/backup-cron-entrypoint.sh
COPY docker/scripts/run-post-start-maintenance.sh /usr/local/bin/run-post-start-maintenance.sh
COPY docker/scripts/restore-backup.sh /usr/local/bin/restore-backup.sh

RUN sed -i 's/\r$//' \
        /usr/local/bin/custom-postgres-entrypoint.sh \
        /etc/postgresql/templates/postgresql.conf.template \
        /etc/postgresql/templates/pg_hba.conf.template \
        /docker-entrypoint-initdb.d/01-enable-pgvector.sh \
        /usr/local/bin/common.sh \
        /usr/local/bin/run-backup.sh \
        /usr/local/bin/backup-cron-entrypoint.sh \
        /usr/local/bin/run-post-start-maintenance.sh \
        /usr/local/bin/restore-backup.sh \
    && chmod 755 \
        /usr/local/bin/custom-postgres-entrypoint.sh \
        /docker-entrypoint-initdb.d/01-enable-pgvector.sh \
        /usr/local/bin/common.sh \
        /usr/local/bin/run-backup.sh \
        /usr/local/bin/backup-cron-entrypoint.sh \
        /usr/local/bin/run-post-start-maintenance.sh \
        /usr/local/bin/restore-backup.sh \
    && mkdir -p /etc/postgresql/custom /backups

ENTRYPOINT ["/usr/local/bin/custom-postgres-entrypoint.sh"]
CMD ["postgres"]
