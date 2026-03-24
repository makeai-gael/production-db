[CmdletBinding()]
param(
    [string]$ProjectName = "production-db-validation",
    [int]$DbPort = 55432
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ValidationBackups = Join-Path $RepoRoot "validation-backups"
$ValidationSecrets = Join-Path $RepoRoot "validation-secrets"
$ValidationPassword = "validation-password"
$ValidationVolume = "$ProjectName-pgdata-v18"

New-Item -ItemType Directory -Force -Path $ValidationBackups | Out-Null
New-Item -ItemType Directory -Force -Path $ValidationSecrets | Out-Null
Set-Content -Path (Join-Path $ValidationSecrets "postgres_password.txt") -Value $ValidationPassword -NoNewline

$overrides = @{
    DB_PORT = "$DbPort"
    BACKUP_HOST_DIR = "./validation-backups"
    SECRETS_HOST_DIR = "./validation-secrets"
    POSTGRES_VOLUME_NAME = $ValidationVolume
    POSTGRES_DB = "validation_app"
    POSTGRES_USER = "validation_admin"
    POSTGRES_PASSWORD = ""
    DB_PASSWORD_FILE = "/run/secrets/postgres_password.txt"
}

$savedEnv = @{}
foreach ($key in $overrides.Keys) {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
    [Environment]::SetEnvironmentVariable($key, $overrides[$key], "Process")
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComposeArgs
    )

    & docker compose -p $ProjectName @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose $($ComposeArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

try {
    Invoke-Compose @("down", "-v", "--remove-orphans")
    Invoke-Compose @("up", "-d", "--build")

    Invoke-Compose @(
        "exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db",
        "psql", "-U", "validation_admin", "-d", "validation_app", "-v", "ON_ERROR_STOP=1",
        "-c", "SHOW server_version;",
        "-c", "SHOW max_connections;",
        "-c", "SHOW shared_buffers;",
        "-c", "SHOW shared_preload_libraries;",
        "-c", "SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'pg_stat_statements') ORDER BY extname;"
    )

    Invoke-Compose @(
        "exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db",
        "psql", "-U", "validation_admin", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
        "-c", "CREATE DATABASE analytics_db;"
    )

    Invoke-Compose @("restart", "backup")
    Start-Sleep -Seconds 8

    Invoke-Compose @(
        "exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db",
        "psql", "-U", "validation_admin", "-d", "analytics_db", "-v", "ON_ERROR_STOP=1",
        "-c", "SELECT extname FROM pg_extension WHERE extname = 'pg_stat_statements';"
    )

    Invoke-Compose @("exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db", "bash", "-lc", @"
psql -U validation_admin -d validation_app -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE ROLE validation_reader LOGIN PASSWORD ''reader-password''' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'validation_reader') \gexec
CREATE TABLE IF NOT EXISTS backup_restore_test (id integer PRIMARY KEY, note text NOT NULL, embedding vector(3));
TRUNCATE backup_restore_test;
GRANT CONNECT ON DATABASE validation_app TO validation_reader;
GRANT USAGE ON SCHEMA public TO validation_reader;
GRANT SELECT ON TABLE backup_restore_test TO validation_reader;
INSERT INTO backup_restore_test (id, note, embedding) VALUES (1, 'validated-before-backup', '[1,2,3]');
SELECT has_table_privilege('validation_reader', 'public.backup_restore_test', 'SELECT') AS reader_can_select;
SELECT id, note, embedding::text FROM backup_restore_test;
SQL
"@)

    Invoke-Compose @("exec", "-T", "backup", "/usr/local/bin/run-backup.sh")

    Invoke-Compose @("exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db", "bash", "-lc", @"
psql -U validation_admin -d validation_app -v ON_ERROR_STOP=1 <<'SQL'
UPDATE backup_restore_test SET note = 'validated-after-backup', embedding = '[9,9,9]' WHERE id = 1;
REVOKE SELECT ON TABLE backup_restore_test FROM validation_reader;
SELECT has_table_privilege('validation_reader', 'public.backup_restore_test', 'SELECT') AS reader_can_select;
SELECT id, note, embedding::text FROM backup_restore_test;
SQL
"@)

    Invoke-Compose @("run", "--rm", "restore", "latest", "--yes")

    Invoke-Compose @("exec", "-T", "-e", "PGPASSWORD=$ValidationPassword", "db", "bash", "-lc", @"
psql -U validation_admin -d validation_app -v ON_ERROR_STOP=1 <<'SQL'
SELECT has_table_privilege('validation_reader', 'public.backup_restore_test', 'SELECT') AS reader_can_select;
SELECT id, note, embedding::text FROM backup_restore_test;
SQL
"@)

    Write-Host "Validation succeeded for project $ProjectName."
}
finally {
    Invoke-Compose @("down", "-v", "--remove-orphans")

    foreach ($key in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], "Process")
    }
}
