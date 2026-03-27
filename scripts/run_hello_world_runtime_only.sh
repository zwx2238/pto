#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/setup_npu_env.sh" ""

exec python "${REPO_ROOT}/scripts/measure_hello_world_runtime_only.py" "$@"
