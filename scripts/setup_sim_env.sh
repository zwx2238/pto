#!/usr/bin/env bash

# Bootstrap and/or activate the local PyPTO simulation environment.
#
# Usage:
#   source scripts/setup_sim_env.sh
#       Bootstrap if needed, activate the venv, and export SIM env vars.
#
#   bash scripts/setup_sim_env.sh
#       Bootstrap if needed, then print the next source command.
#
#   source scripts/setup_sim_env.sh --env-only
#       Only activate the venv and export env vars. Assumes bootstrap is done.

_setup_sim_is_sourced() {
    [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

_setup_sim_log() {
    printf '[setup-sim] %s\n' "$*"
}

_setup_sim_err() {
    printf '[setup-sim] ERROR: %s\n' "$*" >&2
}

_setup_sim_run() {
    _setup_sim_log "$*"
    "$@"
}

_setup_sim_require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        _setup_sim_err "missing required command: $cmd"
        return 1
    }
}

_setup_sim_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'x86_64\n'
            ;;
        aarch64|arm64)
            printf 'aarch64\n'
            ;;
        *)
            _setup_sim_err "unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
}

_setup_sim_download() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        _setup_sim_run curl -L --fail --retry 3 -o "$output" "$url" || return 1
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        _setup_sim_run wget -O "$output" "$url" || return 1
        return 0
    fi

    _setup_sim_err "need curl or wget to download ptoas"
    return 1
}

_setup_sim_choose_ptoas_bin() {
    if [[ -x "${SETUP_SIM_PTOAS_DIR}/bin/ptoas" ]]; then
        printf '%s\n' "${SETUP_SIM_PTOAS_DIR}/bin/ptoas"
        return 0
    fi

    if [[ -x "${SETUP_SIM_PTOAS_DIR}/ptoas" ]]; then
        printf '%s\n' "${SETUP_SIM_PTOAS_DIR}/ptoas"
        return 0
    fi

    return 1
}

_setup_sim_bootstrap_venv() {
    if [[ ! -x "${SETUP_SIM_VENV_DIR}/bin/python" ]]; then
        _setup_sim_run python3 -m venv "${SETUP_SIM_VENV_DIR}" || return 1
    fi

    _setup_sim_run "${SETUP_SIM_VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel || return 1
}

_setup_sim_install_python_deps() {
    if ! "${SETUP_SIM_VENV_DIR}/bin/python" -c "import torch" >/dev/null 2>&1; then
        _setup_sim_run \
            "${SETUP_SIM_VENV_DIR}/bin/python" -m pip install torch --index-url https://download.pytorch.org/whl/cpu \
            || return 1
    else
        _setup_sim_log "torch already available in ${SETUP_SIM_VENV_DIR}"
    fi

    if ! "${SETUP_SIM_VENV_DIR}/bin/python" -c "import pypto" >/dev/null 2>&1; then
        _setup_sim_run "${SETUP_SIM_VENV_DIR}/bin/python" -m pip install -e "${SETUP_SIM_REPO_ROOT}/frameworks/pypto" \
            || return 1
    else
        _setup_sim_log "pypto already available in ${SETUP_SIM_VENV_DIR}"
    fi
}

_setup_sim_ensure_ptoas() {
    local existing_bin=""
    local arch=""
    local archive_url=""
    local tmp_dir=""
    local archive_path=""

    if [[ -n "${PTOAS_ROOT:-}" && -x "${PTOAS_ROOT}/ptoas" ]]; then
        SETUP_SIM_PTOAS_BIN="${PTOAS_ROOT}/ptoas"
        return 0
    fi

    if command -v ptoas >/dev/null 2>&1; then
        SETUP_SIM_PTOAS_BIN="$(command -v ptoas)"
        return 0
    fi

    if existing_bin="$(_setup_sim_choose_ptoas_bin 2>/dev/null)"; then
        SETUP_SIM_PTOAS_BIN="${existing_bin}"
        return 0
    fi

    arch="$(_setup_sim_detect_arch)" || return 1
    archive_url="https://github.com/zhangstevenunity/PTOAS/releases/download/v${SETUP_SIM_PTOAS_VERSION}/ptoas-bin-${arch}.tar.gz"

    tmp_dir="$(mktemp -d)"
    archive_path="${tmp_dir}/ptoas-bin-${arch}.tar.gz"

    _setup_sim_log "downloading ptoas ${SETUP_SIM_PTOAS_VERSION} for ${arch}"
    _setup_sim_download "${archive_url}" "${archive_path}" || {
        rm -rf "${tmp_dir}"
        return 1
    }

    rm -rf "${SETUP_SIM_PTOAS_DIR}"
    mkdir -p "${SETUP_SIM_PTOAS_DIR}"
    _setup_sim_run tar -xzf "${archive_path}" -C "${SETUP_SIM_PTOAS_DIR}" || {
        rm -rf "${tmp_dir}"
        return 1
    }
    rm -rf "${tmp_dir}"

    if existing_bin="$(_setup_sim_choose_ptoas_bin 2>/dev/null)"; then
        chmod +x "${existing_bin}" || return 1
        SETUP_SIM_PTOAS_BIN="${existing_bin}"
        return 0
    fi

    _setup_sim_err "ptoas extracted, but no executable was found under ${SETUP_SIM_PTOAS_DIR}"
    return 1
}

_setup_sim_export_env() {
    if [[ ! -f "${SETUP_SIM_VENV_DIR}/bin/activate" ]]; then
        _setup_sim_err "venv not found: ${SETUP_SIM_VENV_DIR}"
        return 1
    fi

    if [[ -z "${SETUP_SIM_PTOAS_BIN:-}" ]]; then
        if ! SETUP_SIM_PTOAS_BIN="$(_setup_sim_choose_ptoas_bin 2>/dev/null)"; then
            _setup_sim_err "ptoas executable not found under ${SETUP_SIM_PTOAS_DIR}"
            return 1
        fi
    fi

    # shellcheck disable=SC1090
    source "${SETUP_SIM_VENV_DIR}/bin/activate"
    export SIMPLER_ROOT="${SETUP_SIM_REPO_ROOT}/frameworks/simpler"
    export PTOAS_ROOT="$(cd "$(dirname "${SETUP_SIM_PTOAS_BIN}")" && pwd)"
    export PTO_ISA_ROOT="${SETUP_SIM_REPO_ROOT}/upstream/pto-isa"
}

_setup_sim_validate_env() {
    "${SETUP_SIM_VENV_DIR}/bin/python" -c "import torch, pypto" >/dev/null 2>&1 || {
        _setup_sim_err "python environment is incomplete; torch or pypto import failed"
        return 1
    }

    "${SETUP_SIM_PTOAS_BIN}" --version >/dev/null 2>&1 || {
        _setup_sim_err "ptoas executable is not working: ${SETUP_SIM_PTOAS_BIN}"
        return 1
    }
}

_setup_sim_print_next() {
    cat <<EOF
[setup-sim] bootstrap complete
[setup-sim] next:
  source "${SETUP_SIM_REPO_ROOT}/scripts/setup_sim_env.sh" --env-only
  python "${SETUP_SIM_REPO_ROOT}/models/pypto-lib/examples/beginner/hello_world.py" --sim
EOF
}

_setup_sim_main() {
    local mode="${1:-}"

    if [[ "$(uname -s)" != "Linux" ]]; then
        _setup_sim_err "this script currently supports Linux only"
        return 1
    fi

    _setup_sim_require_cmd python3 || return 1
    _setup_sim_require_cmd tar || return 1
    _setup_sim_require_cmd cmake || return 1
    _setup_sim_require_cmd ninja || return 1
    _setup_sim_require_cmd gcc || return 1
    _setup_sim_require_cmd g++ || return 1
    _setup_sim_require_cmd g++-15 || return 1
    _setup_sim_require_cmd make || return 1

    case "${mode}" in
        "" )
            _setup_sim_bootstrap_venv || return 1
            _setup_sim_install_python_deps || return 1
            _setup_sim_ensure_ptoas || return 1
            _setup_sim_validate_env || return 1

            if _setup_sim_is_sourced; then
                _setup_sim_export_env || return 1
                _setup_sim_log "environment ready in current shell"
                _setup_sim_log "run: python ${SETUP_SIM_REPO_ROOT}/models/pypto-lib/examples/beginner/hello_world.py --sim"
            else
                _setup_sim_print_next
            fi
            ;;
        "--env-only" )
            if ! _setup_sim_is_sourced; then
                _setup_sim_err "--env-only must be used with: source scripts/setup_sim_env.sh --env-only"
                return 1
            fi
            _setup_sim_ensure_ptoas || return 1
            _setup_sim_export_env || return 1
            _setup_sim_validate_env || return 1
            _setup_sim_log "environment ready in current shell"
            ;;
        * )
            _setup_sim_err "unknown option: ${mode}"
            _setup_sim_err "usage: source scripts/setup_sim_env.sh [--env-only]"
            return 1
            ;;
    esac
}

SETUP_SIM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SIM_REPO_ROOT="$(cd "${SETUP_SIM_SCRIPT_DIR}/.." && pwd)"
SETUP_SIM_VENV_DIR="${SETUP_SIM_VENV_DIR:-${SETUP_SIM_REPO_ROOT}/.venv-pto-sim}"
SETUP_SIM_PTOAS_DIR="${SETUP_SIM_PTOAS_DIR:-${SETUP_SIM_REPO_ROOT}/.tools/ptoas-bin}"
SETUP_SIM_PTOAS_VERSION="${SETUP_SIM_PTOAS_VERSION:-0.17}"

if _setup_sim_is_sourced; then
    _setup_sim_main "$@" || return $?
else
    _setup_sim_main "$@"
    exit $?
fi
