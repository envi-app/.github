#!/usr/bin/env bash
# Bring up the local Postgres cluster and ensure the shared dev database, role,
# the `core` fixture schema and the WMS migrations are present. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DB_NAME=envi
DB_USER=envi_user
DB_PASS=envi_dev_pw

command -v pg_ctlcluster >/dev/null 2>&1 || { echo "postgres not installed yet"; exit 0; }

# Start the cluster (no systemd in the VM). Ignore "already running".
if ! pg_lsclusters -h 2>/dev/null | awk '{print $4}' | grep -q online; then
  echo "==> starting postgres cluster"
  sudo pg_ctlcluster 16 main start || true
fi
# Wait for the socket to accept connections.
for _ in $(seq 1 20); do
  sudo -u postgres pg_isready -q && break
  sleep 1
done

# Role + database.
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" >/dev/null

export PGPASSWORD="${DB_PASS}"
# `core` fixture: minimal replica of the backend-owned schema so WMS FKs resolve.
if ! psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "SELECT 1 FROM information_schema.schemata WHERE schema_name='core'" | grep -q 1; then
  FIXTURE="${REPOS_ROOT}/envi-wms/scripts/core-fixture.sql"
  [ -f "${FIXTURE}" ] && psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -f "${FIXTURE}" >/dev/null
fi

# WMS migrations (drizzle migrator is idempotent).
if [ -d "${REPOS_ROOT}/envi-wms/node_modules" ]; then
  echo "==> applying WMS migrations"
  ( cd "${REPOS_ROOT}/envi-wms"
    export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}"
    npm run db:migrate )
fi

echo "==> db bootstrap complete"
