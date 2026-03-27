#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_steps_log() {
    printf '[bootstrap-test] %s\n' "$*"
}

_steps_err() {
    printf '[bootstrap-test] ERROR: %s\n' "$*" >&2
}

_steps_run() {
    local step="$1"
    shift
    local start_ts end_ts duration rc
    _steps_log "START ${step}"
    start_ts="$(date +%s)"
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    end_ts="$(date +%s)"
    duration=$(( end_ts - start_ts ))
    if (( rc == 0 )); then
        _steps_log "DONE  ${step} (${duration}s)"
    else
        _steps_log "FAIL  ${step} (${duration}s)"
    fi
    return "${rc}"
}

_steps_require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        _steps_err "missing required command: $cmd"
        return 1
    }
}

_steps_require_file() {
    local path="$1"
    [[ -f "${path}" ]] || {
        _steps_err "missing required file: ${path}"
        return 1
    }
}

_choose_probe_python() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi
    printf '[bootstrap-test] ERROR: python3 or python is required for source probing\n' >&2
    return 1
}

_steps_preflight() {
    _steps_require_cmd git || return 1
    _steps_require_cmd npu-smi || return 1

    if [[ -z "${ASCEND_HOME_PATH:-}" ]]; then
        _steps_err "ASCEND_HOME_PATH is not set"
        return 1
    fi

    if [[ ! -d "${ASCEND_HOME_PATH}" ]]; then
        _steps_err "ASCEND_HOME_PATH does not exist: ${ASCEND_HOME_PATH}"
        return 1
    fi

    _steps_require_file "${ASCEND_HOME_PATH}/bin/ccec" || return 1
    _steps_require_file "${ASCEND_HOME_PATH}/tools/hcc/bin/aarch64-target-linux-gnu-g++" || return 1

    npu-smi info >/dev/null 2>&1 || {
        _steps_err "npu-smi info failed"
        return 1
    }
}

PROBE_PY="$(_choose_probe_python)"

_steps_run "preflight" _steps_preflight
_steps_run "probe-report" "${PROBE_PY}" "${REPO_ROOT}/scripts/probe_bootstrap_sources.py"
eval "$("${PROBE_PY}" "${REPO_ROOT}/scripts/probe_bootstrap_sources.py" --format shell)"

export SETUP_SIM_LIBRARY_ONLY=1
# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/setup_sim_env.sh"
unset SETUP_SIM_LIBRARY_ONLY

export SETUP_NPU_LIBRARY_ONLY=1
# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/setup_npu_env.sh"
unset SETUP_NPU_LIBRARY_ONLY

_steps_run "bootstrap-miniconda" _setup_sim_ensure_miniconda
_steps_run "install-build-tools" _setup_sim_ensure_local_build_tools
_steps_run "prepare-tool-env" _setup_sim_prepare_local_toolchain_env
_steps_run "bootstrap-sources" _setup_sim_ensure_repo_sources

SETUP_SIM_PYTHON_BIN="$(_setup_sim_choose_python)"
export SETUP_SIM_PYTHON_BIN
_steps_log "python: ${SETUP_SIM_PYTHON_BIN}"

_steps_run "bootstrap-venv" _setup_sim_bootstrap_venv
_steps_run "install-torch" _setup_sim_install_torch_dep
_steps_run "install-pypto" _setup_sim_install_pypto_dep
_steps_run "download-ptoas" _setup_sim_ensure_ptoas
_steps_run "export-env" _setup_sim_export_env
_steps_run "validate-env" _setup_sim_validate_env
_steps_run "select-device" _setup_npu_export_env
_steps_run "validate-npu-env" _setup_npu_validate_env

_steps_run "prepare-runtime-cache" python "${REPO_ROOT}/scripts/measure_hello_world_runtime_only.py" \
    --prepare-cache-only --rebuild-cache "$@"

exec python "${REPO_ROOT}/scripts/measure_hello_world_runtime_only.py" --enable-profiling "$@"
