#!/usr/bin/env bash
# Per-boot reconciliation.
#
# When an agent boots from a prebuilt snapshot the platform re-checks-out every
# repo working tree, which discards gitignored, install-produced artifacts
# (node_modules, backend target/*.jar, .venv, dev .env files). Only out-of-tree
# state survives (the ~/.m2 Maven cache, the npm cache and the Postgres data
# dir). So on every boot we:
#   1. Re-run install if those in-tree artifacts are missing. With the caches
#      warm from the snapshot this is fast; it is a no-op when they are present.
#   2. Bring Postgres online and ensure the dev DB/schema exist.
# Dev servers themselves run as `terminals`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Sentinels that only exist once `install` has populated the working trees.
NEEDS_INSTALL=0
for sentinel in \
  "${REPOS_ROOT}/envi-frontend-marketplace/node_modules" \
  "${REPOS_ROOT}/envi-wms/node_modules" \
  "${REPOS_ROOT}/envi-wms/.env"; do
  [ -e "${sentinel}" ] || { echo "==> missing ${sentinel} — running install"; NEEDS_INSTALL=1; break; }
done

if [ "${NEEDS_INSTALL}" -eq 1 ]; then
  # install.sh finishes by running db-bootstrap, so Postgres/schema come up too.
  bash "${SCRIPT_DIR}/install.sh"
else
  bash "${SCRIPT_DIR}/db-bootstrap.sh"
fi

echo "==> start complete"
