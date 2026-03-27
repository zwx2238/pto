#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${CONDA_PREFIX:-}" ]]; then
    printf '[install-pypto] ERROR: please run inside an activated conda env\n' >&2
    exit 1
fi

if ! command -v python >/dev/null 2>&1; then
    printf '[install-pypto] ERROR: python not found in current shell\n' >&2
    exit 1
fi

if ! command -v tee >/dev/null 2>&1; then
    printf '[install-pypto] ERROR: tee not found in current shell\n' >&2
    exit 1
fi

_ipy_log() {
    printf '[install-pypto] %s\n' "$*"
}

_ipy_prepend_path() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) export PATH="${dir}:${PATH}" ;;
    esac
}

_ipy_prepend_ld_library_path() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    case ":${LD_LIBRARY_PATH:-}:" in
        *":${dir}:"*) ;;
        *) export LD_LIBRARY_PATH="${dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
    esac
}

_ipy_prepend_path "${CONDA_PREFIX}/bin"
_ipy_prepend_ld_library_path "${CONDA_PREFIX}/lib"

LOG_DIR="${REPO_ROOT}/.logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PIP_LOG_PATH="${LOG_DIR}/install-pypto-${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}"

_ipy_log "repo root: ${REPO_ROOT}"
_ipy_log "python: $(command -v python)"
_ipy_log "log file: ${PIP_LOG_PATH}"
_ipy_log "installing build deps"

PYTHONPATH= python -m pip install \
    "nanobind>=2.0.0" \
    "scikit-build-core>=0.10.0"

_ipy_log "installing editable package: frameworks/pypto"

set +e
PYTHONPATH= python -m pip install -v --no-build-isolation -e \
    "${REPO_ROOT}/frameworks/pypto" 2>&1 | tee "${PIP_LOG_PATH}"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
    _ipy_log "pip install failed; see log: ${PIP_LOG_PATH}"
    exit "${rc}"
fi

_ipy_log "done"
