#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${CONDA_PREFIX:-}" ]]; then
    printf '[install-build-tools] ERROR: please run inside an activated conda env\n' >&2
    exit 1
fi

_ibt_log() {
    printf '[install-build-tools] %s\n' "$*"
}

_ibt_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'x86_64\n'
            ;;
        aarch64|arm64)
            printf 'aarch64\n'
            ;;
        *)
            printf '[install-build-tools] ERROR: unsupported architecture: %s\n' "$(uname -m)" >&2
            exit 1
            ;;
    esac
}

_ibt_compiler_packages() {
    case "$(_ibt_detect_arch)" in
        x86_64)
            printf 'gcc_linux-64 gxx_linux-64\n'
            ;;
        aarch64)
            printf 'gcc_linux-aarch64 gxx_linux-aarch64\n'
            ;;
    esac
}

read -r GCC_PKG GXX_PKG <<<"$(_ibt_compiler_packages)"

_ibt_log "repo root: ${REPO_ROOT}"
_ibt_log "conda env: ${CONDA_PREFIX}"
_ibt_log "installing: cmake ninja make ${GCC_PKG} ${GXX_PKG}"

conda install -y -p "${CONDA_PREFIX}" -c conda-forge \
    cmake ninja make "${GCC_PKG}" "${GXX_PKG}"

_ibt_log "done"
