#!/usr/bin/env bash
# Workspace-wide install for the envi platform (multi-repo Cloud Agent).
# Idempotent: safe to re-run. Prepares toolchains, dependencies, builds and the
# local Postgres schema so every repo in the workspace is ready to develop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# .cursor -> .github -> repos root (parent that holds every envi-* checkout).
REPOS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
echo "export ENVI_REPOS_ROOT=${REPOS_ROOT}" > "${HOME}/.envi-workspace-env"
echo "==> repos root: ${REPOS_ROOT}"

JS_REPOS=(envi-frontend-marketplace envi-frontend-landing-page envi-wms envi-delivery-zone-hub envi-frontend-mobile)
# mono is first: it installs lat.envi:core into ~/.m2, which the others resolve.
JAVA_REPOS=(envi-backend-mono envi-backend-analytics envi-backend-notifications envi-backend-products envi-backend-transactions)

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. System packages (Node 22 & Java 21 ship in the base image / snapshot).
# ---------------------------------------------------------------------------
NEED_APT=()
have mvn   || NEED_APT+=(maven)
have psql  || NEED_APT+=(postgresql postgresql-contrib)
python3 -c 'import venv' 2>/dev/null || NEED_APT+=(python3-venv python3-pip)
if [ "${#NEED_APT[@]}" -gt 0 ]; then
  echo "==> installing system packages: ${NEED_APT[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED_APT[@]}"
fi

# ---------------------------------------------------------------------------
# 2. Node dependencies for every JS repo.
# ---------------------------------------------------------------------------
for repo in "${JS_REPOS[@]}"; do
  dir="${REPOS_ROOT}/${repo}"
  [ -d "${dir}" ] || { echo "!! missing ${repo}, skipping"; continue; }
  echo "==> npm ci: ${repo}"
  (cd "${dir}" && npm ci)
done

# ---------------------------------------------------------------------------
# 3. Local dev env files (non-secret dev defaults; created only if absent).
# ---------------------------------------------------------------------------
MKT_ENV="${REPOS_ROOT}/envi-frontend-marketplace/.env.local"
if [ ! -f "${MKT_ENV}" ]; then
  echo "==> writing marketplace .env.local (points at public dev API)"
  cat > "${MKT_ENV}" <<'EOF'
API_BASE_URL=https://api.dev.envi.lat/api/v1
APP_VERSION=1.0.0
ENVI_DEPLOY=BETA
SITE_URL=http://localhost:3000
EOF
fi

WMS_ENV="${REPOS_ROOT}/envi-wms/.env"
if [ ! -f "${WMS_ENV}" ]; then
  echo "==> writing wms .env (local Postgres, dev secrets)"
  cat > "${WMS_ENV}" <<'EOF'
DATABASE_URL=postgresql://envi_user:envi_dev_pw@localhost:5432/envi
KAFKA_BROKERS=localhost:9092
KAFKA_GROUP_ID=wms-consumer
KAFKA_TOPIC_PACKAGE_UPDATE=order.update.package.begin
KAFKA_TOPIC_CONSOLIDADO=consolidado.packages.ready
JWT_SECRET=dev-jwt-secret-change-me
CARGOTRANS_BASE_URL=https://envec.cargotransnet.com
CARGOTRANS_ID_CLIENTE=4304
WMS_PUBLIC_BASE_URL=http://localhost:5173
EOF
fi

BO_ENV="${REPOS_ROOT}/envi-backoffice/.env"
if [ ! -f "${BO_ENV}" ] && [ -f "${REPOS_ROOT}/envi-backoffice/.env.example" ]; then
  echo "==> writing backoffice .env from example (fill secrets to run fully)"
  cp "${REPOS_ROOT}/envi-backoffice/.env.example" "${BO_ENV}"
  sed -i 's#^DB_USERNAME=.*#DB_USERNAME=envi_user#' "${BO_ENV}"
  sed -i 's#^DB_PASSWORD=.*#DB_PASSWORD=envi_dev_pw#' "${BO_ENV}"
  sed -i 's#^DB_DATABASE=.*#DB_DATABASE=envi#' "${BO_ENV}"
  sed -i 's#^KAFKA_ENABLED=.*#KAFKA_ENABLED=false#' "${BO_ENV}"
fi

# ---------------------------------------------------------------------------
# 4. Java builds. mono first (installs lat.envi:core:0.0.5 to ~/.m2).
# ---------------------------------------------------------------------------
if have mvn; then
  for repo in "${JAVA_REPOS[@]}"; do
    dir="${REPOS_ROOT}/${repo}"
    [ -d "${dir}" ] || { echo "!! missing ${repo}, skipping"; continue; }
    echo "==> mvn install (-DskipTests): ${repo}"
    (cd "${dir}" && mvn -q -B clean install -DskipTests)
  done
fi

# ---------------------------------------------------------------------------
# 5. Python venv for the FastAPI backoffice.
# ---------------------------------------------------------------------------
BO="${REPOS_ROOT}/envi-backoffice"
if [ -f "${BO}/requirements.txt" ]; then
  echo "==> python venv: envi-backoffice"
  python3 -m venv "${BO}/.venv"
  # shellcheck disable=SC1091
  . "${BO}/.venv/bin/activate"
  pip install --upgrade pip -q
  pip install -q -r "${BO}/requirements.txt"
  deactivate
fi

# ---------------------------------------------------------------------------
# 6. Local Postgres schema (durable; captured in the snapshot).
# ---------------------------------------------------------------------------
bash "${SCRIPT_DIR}/db-bootstrap.sh" || echo "!! db bootstrap skipped/failed (non-fatal for install)"

echo "==> install complete"
