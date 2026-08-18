#!/usr/bin/env bash
# Per-boot reconciliation: bring the local Postgres online and make sure the
# dev database + schema exist. Dev servers themselves run as `terminals`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/db-bootstrap.sh"
echo "==> start complete"
