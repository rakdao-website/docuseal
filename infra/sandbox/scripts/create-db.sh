#!/usr/bin/env bash
set -euo pipefail
export PYTHONWARNINGS=ignore
export AWS_CA_BUNDLE="${AWS_CA_BUNDLE:-$(python -c "import certifi; print(certifi.where())")}"
REGION=eu-north-1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${DOCUSEAL_DB_PASSWORD:-}" ]; then
  DOCUSEAL_DB_PASSWORD=$(openssl rand -hex 24)
  export DOCUSEAL_DB_PASSWORD
fi

CREDS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id inc-sandbox/rds-proxy-credentials \
  --query SecretString --output text)
PGPASSWORD=$(echo "$CREDS" | python -c "import sys,json; print(json.load(sys.stdin)['password'])")
export PGPASSWORD
HOST=$(echo "$CREDS" | python -c "import sys,json; print(json.load(sys.stdin)['host'])")

cat > "$SCRIPT_DIR/../docuseal-init.sql" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'docuseal') THEN
    CREATE ROLE docuseal LOGIN PASSWORD '${DOCUSEAL_DB_PASSWORD}';
  ELSE
    ALTER ROLE docuseal WITH PASSWORD '${DOCUSEAL_DB_PASSWORD}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE docuseal OWNER docuseal'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'docuseal') \\gexec
GRANT ALL PRIVILEGES ON DATABASE docuseal TO docuseal;
SQL

docker run --rm -e PGPASSWORD \
  -v "$SCRIPT_DIR/../docuseal-init.sql:/init.sql:ro" \
  postgres:16-alpine psql -h "$HOST" -U dbadmin -d inc_sandbox_db -p 5432 -f /init.sql

echo "$DOCUSEAL_DB_PASSWORD" > "$SCRIPT_DIR/../.docuseal-db-password"
chmod 600 "$SCRIPT_DIR/../.docuseal-db-password"
echo "Database docuseal ready. Password saved to infra/sandbox/.docuseal-db-password (gitignored)"
