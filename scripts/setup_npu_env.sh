#!/usr/bin/env bash

# Bootstrap and/or activate the local PyPTO NPU environment.
#
# Usage:
#   source scripts/setup_npu_env.sh
#       Bootstrap if needed, activate the venv, and export NPU env vars.
#
#   bash scripts/setup_npu_env.sh
#       Bootstrap if needed, then print the next source command.
#
#   source scripts/setup_npu_env.sh --env-only
#       Only activate the venv and export env vars. Assumes bootstrap is done.

_setup_npu_is_sourced() {
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

_setup_npu_log() {
    printf '[setup-npu] %s\n' "$*"
}

_setup_npu_err() {
    printf '[setup-npu] ERROR: %s\n' "$*" >&2
}

_setup_npu_require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        _setup_npu_err "missing required command: $cmd"
        return 1
    }
}

_setup_npu_require_file() {
    local path="$1"
    [[ -f "${path}" ]] || {
        _setup_npu_err "missing required file: ${path}"
        return 1
    }
}

_setup_npu_choose_device() {
    local requested="${SETUP_NPU_DEVICE_ID:-${ASCEND_DEVICE_ID:-${NPU_DEVICE_ID:-}}}"
    if [[ -n "${requested}" ]]; then
        printf '%s\n' "${requested}"
        return 0
    fi

    if ! command -v npu-smi >/dev/null 2>&1; then
        printf '0\n'
        return 0
    fi

    python - <<'PY'
import os
import re
import subprocess

try:
    output = subprocess.check_output(["npu-smi", "info"], text=True, timeout=5)
except Exception:
    print(0)
    raise SystemExit(0)

rows = []
current_dev = None
for line in output.splitlines():
    dev_match = re.match(r"\|\s*(\d+)\s+910B\d*\s+\|", line)
    if dev_match:
        current_dev = int(dev_match.group(1))
        continue
    if current_dev is None:
        continue
    usage_pairs = re.findall(r"(\d+)\s*/\s*(\d+)", line)
    if not usage_pairs:
        continue
    hbm_used, hbm_total = map(int, usage_pairs[-1])
    rows.append((current_dev, hbm_total - hbm_used))
    current_dev = None

if not rows:
    print(0)
else:
    preferred = []
    preferred_raw = os.environ.get("SETUP_NPU_PREFERRED_DEVICES", "4")
    for part in preferred_raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            preferred.append(int(part))
        except ValueError:
            pass

    try:
        min_free = int(os.environ.get("SETUP_NPU_MIN_FREE_HBM_MB", "2048"))
    except ValueError:
        min_free = 2048

    row_map = {device_id: free_hbm for device_id, free_hbm in rows}
    for device_id in preferred:
        if row_map.get(device_id, -1) >= min_free:
            print(device_id)
            raise SystemExit(0)

    print(max(rows, key=lambda item: item[1])[0])
PY
}

_setup_npu_export_env() {
    export PTO2_RING_TASK_WINDOW="${PTO2_RING_TASK_WINDOW:-128}"
    export PTO2_RING_HEAP="${PTO2_RING_HEAP:-8388608}"
    export PTO2_RING_DEP_POOL="${PTO2_RING_DEP_POOL:-256}"

    if [[ -z "${ASCEND_DEVICE_ID:-}" ]]; then
        export ASCEND_DEVICE_ID="$(_setup_npu_choose_device)"
    fi
    export NPU_DEVICE_ID="${NPU_DEVICE_ID:-${ASCEND_DEVICE_ID}}"
}

_setup_npu_validate_env() {
    _setup_npu_require_cmd python || return 1
    _setup_npu_require_cmd npu-smi || return 1

    if [[ -z "${ASCEND_HOME_PATH:-}" ]]; then
        _setup_npu_err "ASCEND_HOME_PATH is not set"
        return 1
    fi

    _setup_npu_require_file "${ASCEND_HOME_PATH}/compiler/ccec_compiler/bin/bisheng" || return 1
    _setup_npu_require_file "${ASCEND_HOME_PATH}/compiler/ccec_compiler/bin/ld.lld" || return 1
    _setup_npu_require_file "${ASCEND_HOME_PATH}/toolkit/toolchain/hcc/bin/aarch64-target-linux-gnu-gcc" || return 1
    _setup_npu_require_file "${ASCEND_HOME_PATH}/toolkit/toolchain/hcc/bin/aarch64-target-linux-gnu-g++" || return 1

    npu-smi info >/dev/null 2>&1 || {
        _setup_npu_err "npu-smi info failed"
        return 1
    }
}

_setup_npu_print_next() {
    local device_id="$1"
    cat <<EOF
[setup-npu] bootstrap complete
[setup-npu] next:
  source "${SETUP_NPU_REPO_ROOT}/scripts/setup_npu_env.sh" --env-only
  python "${SETUP_NPU_REPO_ROOT}/models/pypto-lib/examples/beginner/hello_world.py" -d ${device_id}
EOF
}

_setup_npu_source_base_env() {
    local mode="$1"

    # shellcheck disable=SC1090
    source "${SETUP_NPU_REPO_ROOT}/scripts/setup_sim_env.sh" "${mode}" || return 1
}

_setup_npu_main() {
    local mode="${1:-}"
    local device_id=""

    if [[ "$(uname -s)" != "Linux" ]]; then
        _setup_npu_err "this script currently supports Linux only"
        return 1
    fi

    if _setup_npu_is_sourced; then
        case "${mode}" in
            ""|"--env-only")
                _setup_npu_source_base_env "${mode}" || return 1
                _setup_npu_export_env
                _setup_npu_validate_env || return 1
                _setup_npu_log "environment ready in current shell"
                _setup_npu_log "device: ${ASCEND_DEVICE_ID}"
                _setup_npu_log "run: python ${SETUP_NPU_REPO_ROOT}/models/pypto-lib/examples/beginner/hello_world.py -d ${ASCEND_DEVICE_ID}"
                ;;
            *)
                _setup_npu_err "unknown option: ${mode}"
                _setup_npu_err "usage: source scripts/setup_npu_env.sh [--env-only]"
                return 1
                ;;
        esac
        return 0
    fi

    case "${mode}" in
        "")
            bash "${SETUP_NPU_REPO_ROOT}/scripts/setup_sim_env.sh" || return 1
            device_id="$(_setup_npu_choose_device)"
            _setup_npu_print_next "${device_id}"
            ;;
        "--env-only")
            _setup_npu_err "--env-only must be used with: source scripts/setup_npu_env.sh --env-only"
            return 1
            ;;
        *)
            _setup_npu_err "unknown option: ${mode}"
            _setup_npu_err "usage: source scripts/setup_npu_env.sh [--env-only]"
            return 1
            ;;
    esac
}

SETUP_NPU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_NPU_REPO_ROOT="$(cd "${SETUP_NPU_SCRIPT_DIR}/.." && pwd)"

if [[ "${SETUP_NPU_LIBRARY_ONLY:-0}" == "1" ]]; then
    if _setup_npu_is_sourced; then
        return 0
    fi
    exit 0
fi

_setup_npu_main "$@"
