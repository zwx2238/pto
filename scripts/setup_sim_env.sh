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
    local start_ts end_ts duration rc
    _setup_sim_log "$*"
    start_ts="$(date +%s)"
    if "$@"; then
        rc=0
    else
        rc=$?
    fi
    end_ts="$(date +%s)"
    duration=$(( end_ts - start_ts ))
    if (( rc == 0 )); then
        _setup_sim_log "completed in ${duration}s"
    else
        _setup_sim_err "command failed after ${duration}s: $*"
    fi
    return "${rc}"
}

_setup_sim_require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        _setup_sim_err "missing required command: $cmd"
        return 1
    }
}

_setup_sim_have_repo_sources() {
    local -a required_paths=(
        "frameworks/pypto/pyproject.toml"
        "frameworks/simpler/python/runtime_builder.py"
        "models/pypto-lib/examples/beginner/hello_world.py"
        "upstream/pto-isa/pyproject.toml"
    )
    local rel_path=""

    for rel_path in "${required_paths[@]}"; do
        [[ -e "${SETUP_SIM_REPO_ROOT}/${rel_path}" ]] || return 1
    done

    return 0
}

_setup_sim_warn_optional_cmd() {
    local cmd="$1"
    local hint="${2:-optional command not found: $cmd}"
    command -v "$cmd" >/dev/null 2>&1 || _setup_sim_log "$hint"
}

_setup_sim_git_available() {
    command -v git >/dev/null 2>&1
}

_setup_sim_url_host() {
    local url="$1"
    local host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    printf '%s\n' "${host}"
}

_setup_sim_should_bypass_proxy_for_host() {
    local host="$1"
    local direct_host=""

    for direct_host in ${SETUP_SIM_DIRECT_HOSTS//,/ }; do
        [[ -n "${direct_host}" ]] || continue
        if [[ "${host}" == "${direct_host}" ]]; then
            return 0
        fi
    done

    return 1
}

_setup_sim_run_without_proxy() {
    _setup_sim_run env \
        -u HTTP_PROXY \
        -u HTTPS_PROXY \
        -u ALL_PROXY \
        -u http_proxy \
        -u https_proxy \
        -u all_proxy \
        -u NO_PROXY \
        -u no_proxy \
        "$@"
}

_setup_sim_run_for_url() {
    local url="$1"
    shift
    local host=""

    host="$(_setup_sim_url_host "${url}")"
    if _setup_sim_should_bypass_proxy_for_host "${host}"; then
        _setup_sim_log "bypass proxy for ${host}"
        _setup_sim_run_without_proxy "$@"
        return $?
    fi

    _setup_sim_run "$@"
}

_setup_sim_prepend_path() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) export PATH="${dir}:${PATH}" ;;
    esac
}

_setup_sim_prepend_ld_library_path() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    case ":${LD_LIBRARY_PATH:-}:" in
        *":${dir}:"*) ;;
        *) export LD_LIBRARY_PATH="${dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
    esac
}

_setup_sim_prepend_path_force() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0

    local path_value=":${PATH}:"
    path_value="${path_value//:${dir}:/\:}"
    path_value="${path_value#:}"
    path_value="${path_value%:}"
    export PATH="${dir}${path_value:+:${path_value}}"
}

_setup_sim_refresh_shell_hash() {
    hash -r 2>/dev/null || true
}

_setup_sim_prepare_local_toolchain_env() {
    _setup_sim_prepend_path "${SETUP_SIM_TOOLS_BIN_DIR}"
    _setup_sim_prepend_path "${SETUP_SIM_MINICONDA_DIR}/bin"
    _setup_sim_prepend_ld_library_path "${SETUP_SIM_MINICONDA_DIR}/lib"
}

_setup_sim_local_cc() {
    printf '%s\n' "${SETUP_SIM_TOOLS_BIN_DIR}/gcc"
}

_setup_sim_local_cxx() {
    printf '%s\n' "${SETUP_SIM_TOOLS_BIN_DIR}/g++"
}

_setup_sim_run_with_local_build_env() {
    local cc_path=""
    local cxx_path=""

    _setup_sim_prepare_local_toolchain_env
    cc_path="$(_setup_sim_local_cc)"
    cxx_path="$(_setup_sim_local_cxx)"
    _setup_sim_require_cmd "${cc_path}" || return 1
    _setup_sim_require_cmd "${cxx_path}" || return 1

    _setup_sim_run env \
        -u AR \
        -u AS \
        -u CPP \
        -u CPPFLAGS \
        -u CFLAGS \
        -u CXXFLAGS \
        -u LDFLAGS \
        -u LD \
        -u NM \
        -u RANLIB \
        -u STRIP \
        -u CC \
        -u CXX \
        -u CC_FOR_BUILD \
        -u CXX_FOR_BUILD \
        -u CMAKE_ARGS \
        -u CMAKE_PREFIX_PATH \
        -u CONDA_BUILD_SYSROOT \
        -u CONDA_TOOLCHAIN_BUILD \
        -u CONDA_TOOLCHAIN_HOST \
        CC="${cc_path}" \
        CXX="${cxx_path}" \
        "$@"
}

_setup_sim_run_with_local_build_env_for_url() {
    local url="$1"
    shift

    local cc_path=""
    local cxx_path=""

    _setup_sim_prepare_local_toolchain_env
    cc_path="$(_setup_sim_local_cc)"
    cxx_path="$(_setup_sim_local_cxx)"
    _setup_sim_require_cmd "${cc_path}" || return 1
    _setup_sim_require_cmd "${cxx_path}" || return 1

    _setup_sim_run_for_url "${url}" env \
        -u AR \
        -u AS \
        -u CPP \
        -u CPPFLAGS \
        -u CFLAGS \
        -u CXXFLAGS \
        -u LDFLAGS \
        -u LD \
        -u NM \
        -u RANLIB \
        -u STRIP \
        -u CC \
        -u CXX \
        -u CC_FOR_BUILD \
        -u CXX_FOR_BUILD \
        -u CMAKE_ARGS \
        -u CMAKE_PREFIX_PATH \
        -u CONDA_BUILD_SYSROOT \
        -u CONDA_TOOLCHAIN_BUILD \
        -u CONDA_TOOLCHAIN_HOST \
        CC="${cc_path}" \
        CXX="${cxx_path}" \
        "$@"
}

_setup_sim_detect_ascend_home() {
    local candidate=""
    local atc_bin=""

    if [[ -n "${ASCEND_HOME_PATH:-}" && -d "${ASCEND_HOME_PATH}" ]]; then
        printf '%s\n' "${ASCEND_HOME_PATH}"
        return 0
    fi

    if [[ -n "${ASCEND_TOOLKIT_HOME:-}" && -d "${ASCEND_TOOLKIT_HOME}" ]]; then
        printf '%s\n' "${ASCEND_TOOLKIT_HOME}"
        return 0
    fi

    if atc_bin="$(command -v atc 2>/dev/null)"; then
        candidate="$(cd "$(dirname "${atc_bin}")/.." && pwd)"
        if [[ -d "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    fi

    for candidate in \
        "/usr/local/Ascend/ascend-toolkit/latest" \
        "/usr/local/Ascend/ascend-toolkit/latest/aarch64-linux"
    do
        if [[ -d "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

_setup_sim_prepare_ascend_env() {
    if [[ -z "${ASCEND_HOME_PATH:-}" ]]; then
        _setup_sim_err "ASCEND_HOME_PATH is not set"
        return 1
    fi

    if [[ ! -d "${ASCEND_HOME_PATH}" ]]; then
        _setup_sim_err "ASCEND_HOME_PATH does not exist: ${ASCEND_HOME_PATH}"
        return 1
    fi

    export ASCEND_TOOLKIT_HOME="${ASCEND_TOOLKIT_HOME:-${ASCEND_HOME_PATH}}"

    _setup_sim_prepend_path "${ASCEND_HOME_PATH}/bin"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/lib64"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/lib64/plugin/opskernel"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/lib64/plugin/nnengine"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/aarch64"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/tools/aml/lib64"
    _setup_sim_prepend_ld_library_path "${ASCEND_HOME_PATH}/tools/aml/lib64/plugin"
    _setup_sim_prepend_ld_library_path "/usr/local/Ascend/driver/lib64"
    _setup_sim_prepend_ld_library_path "/usr/local/Ascend/driver/lib64/common"
    _setup_sim_prepend_ld_library_path "/usr/local/Ascend/driver/lib64/driver"
}

_setup_sim_runtime_ld_library_path() {
    local lib_path="${LD_LIBRARY_PATH:-}"

    if [[ -d "${SETUP_SIM_MINICONDA_DIR}/lib" ]]; then
        if [[ -n "${lib_path}" ]]; then
            lib_path="${SETUP_SIM_MINICONDA_DIR}/lib:${lib_path}"
        else
            lib_path="${SETUP_SIM_MINICONDA_DIR}/lib"
        fi
    fi

    printf '%s\n' "${lib_path}"
}

_setup_sim_choose_python() {
    if [[ -n "${SETUP_SIM_PYTHON_BIN:-}" ]]; then
        [[ -x "${SETUP_SIM_PYTHON_BIN}" ]] || {
            _setup_sim_err "configured python is not executable: ${SETUP_SIM_PYTHON_BIN}"
            return 1
        }
        printf '%s\n' "${SETUP_SIM_PYTHON_BIN}"
        return 0
    fi

    if [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/python3" ]]; then
        printf '%s\n' "${SETUP_SIM_MINICONDA_DIR}/bin/python3"
        return 0
    fi

    if [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/python" ]]; then
        printf '%s\n' "${SETUP_SIM_MINICONDA_DIR}/bin/python"
        return 0
    fi

    command -v python3 >/dev/null 2>&1 || {
        _setup_sim_err "missing required command: python3"
        return 1
    }
    command -v python3
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

_setup_sim_format_bytes_per_sec() {
    local bytes="$1"
    local seconds="$2"

    if (( seconds <= 0 )); then
        printf 'n/a\n'
        return 0
    fi

    python3 - "$bytes" "$seconds" <<'PY'
import sys

size = int(sys.argv[1])
seconds = int(sys.argv[2])
rate = size / seconds
units = ["B/s", "KiB/s", "MiB/s", "GiB/s"]
unit = units[0]
for candidate in units:
    unit = candidate
    if rate < 1024 or candidate == units[-1]:
        break
    rate /= 1024
print(f"{rate:.2f} {unit}")
PY
}

_setup_sim_choose_conda_triplet() {
    case "$(_setup_sim_detect_arch)" in
        x86_64)
            printf 'x86_64-conda-linux-gnu\n'
            ;;
        aarch64)
            printf 'aarch64-conda-linux-gnu\n'
            ;;
        *)
            return 1
            ;;
    esac
}

_setup_sim_conda_compiler_packages() {
    case "$(_setup_sim_detect_arch)" in
        x86_64)
            printf 'gcc_linux-64 gxx_linux-64\n'
            ;;
        aarch64)
            printf 'gcc_linux-aarch64 gxx_linux-aarch64\n'
            ;;
        *)
            return 1
            ;;
    esac
}

_setup_sim_download() {
    local url="$1"
    local output="$2"
    local start_ts=""
    local end_ts=""
    local duration=0
    local file_size=0

    if command -v curl >/dev/null 2>&1; then
        start_ts="$(date +%s)"
        _setup_sim_run_for_url "$url" curl -L --fail --retry 3 -o "$output" "$url" || return 1
        end_ts="$(date +%s)"
        duration=$(( end_ts - start_ts ))
        if [[ -f "${output}" ]]; then
            file_size="$(stat -c%s "${output}")"
            _setup_sim_log "downloaded ${file_size} bytes from ${url} in ${duration}s ($( _setup_sim_format_bytes_per_sec "${file_size}" "${duration}" ))"
        fi
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        start_ts="$(date +%s)"
        _setup_sim_run_for_url "$url" wget -O "$output" "$url" || return 1
        end_ts="$(date +%s)"
        duration=$(( end_ts - start_ts ))
        if [[ -f "${output}" ]]; then
            file_size="$(stat -c%s "${output}")"
            _setup_sim_log "downloaded ${file_size} bytes from ${url} in ${duration}s ($( _setup_sim_format_bytes_per_sec "${file_size}" "${duration}" ))"
        fi
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        start_ts="$(date +%s)"
        _setup_sim_run_for_url "$url" python3 - "$url" "$output" <<'PY' || return 1
import pathlib
import sys
import urllib.request

url = sys.argv[1]
output = pathlib.Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(url) as response:
    output.write_bytes(response.read())
PY
        end_ts="$(date +%s)"
        duration=$(( end_ts - start_ts ))
        if [[ -f "${output}" ]]; then
            file_size="$(stat -c%s "${output}")"
            _setup_sim_log "downloaded ${file_size} bytes from ${url} in ${duration}s ($( _setup_sim_format_bytes_per_sec "${file_size}" "${duration}" ))"
        fi
        return 0
    fi

    if command -v python >/dev/null 2>&1; then
        start_ts="$(date +%s)"
        _setup_sim_run_for_url "$url" python - "$url" "$output" <<'PY' || return 1
import pathlib
import sys
import urllib.request

url = sys.argv[1]
output = pathlib.Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(url) as response:
    output.write_bytes(response.read())
PY
        end_ts="$(date +%s)"
        duration=$(( end_ts - start_ts ))
        if [[ -f "${output}" ]]; then
            file_size="$(stat -c%s "${output}")"
            _setup_sim_log "downloaded ${file_size} bytes from ${url} in ${duration}s ($( _setup_sim_format_bytes_per_sec "${file_size}" "${duration}" ))"
        fi
        return 0
    fi

    _setup_sim_err "need curl, wget, python3, or python to download bootstrap assets"
    return 1
}

_setup_sim_ensure_miniconda() {
    local arch=""
    local installer_name=""
    local installer_path=""
    local installer_url=""

    if [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/python3" ]]; then
        return 0
    fi

    arch="$(_setup_sim_detect_arch)" || return 1
    installer_name="Miniconda3-latest-Linux-${arch}.sh"
    installer_path="${SETUP_SIM_TOOLS_DIR}/${installer_name}"
    installer_url="${SETUP_SIM_MINICONDA_URL_BASE}/${installer_name}"

    mkdir -p "${SETUP_SIM_TOOLS_DIR}"

    if [[ ! -f "${installer_path}" ]]; then
        _setup_sim_log "downloading ${installer_name}"
        _setup_sim_download "${installer_url}" "${installer_path}" || return 1
        chmod +x "${installer_path}" || return 1
    fi

    if [[ -d "${SETUP_SIM_MINICONDA_DIR}" && ! -x "${SETUP_SIM_MINICONDA_DIR}/bin/python3" ]]; then
        rm -rf "${SETUP_SIM_MINICONDA_DIR}"
    fi

    _setup_sim_run bash "${installer_path}" -b -p "${SETUP_SIM_MINICONDA_DIR}" || return 1
}

_setup_sim_conda_install() {
    local conda_bin="${SETUP_SIM_MINICONDA_DIR}/bin/conda"
    local channel="${SETUP_SIM_CONDA_CHANNEL:-conda-forge}"
    local fallback_channel="${SETUP_SIM_CONDA_FALLBACK_CHANNEL:-conda-forge}"

    [[ -x "${conda_bin}" ]] || {
        _setup_sim_err "conda not found after Miniconda bootstrap: ${conda_bin}"
        return 1
    }

    if [[ "${channel}" == http://* || "${channel}" == https://* ]]; then
        if _setup_sim_run_for_url "${channel}" env PYTHONPATH= "${conda_bin}" install -y --override-channels \
            --prefix "${SETUP_SIM_MINICONDA_DIR}" -c "${channel}" "$@"; then
            return 0
        fi

        if [[ -n "${fallback_channel}" && "${fallback_channel}" != "${channel}" ]]; then
            _setup_sim_log "retrying conda install with fallback channel: ${fallback_channel}"
            _setup_sim_run env PYTHONPATH= "${conda_bin}" install -y --override-channels \
                --prefix "${SETUP_SIM_MINICONDA_DIR}" -c "${fallback_channel}" "$@" || return 1
            return 0
        fi

        return 1
    fi

    _setup_sim_run env PYTHONPATH= "${conda_bin}" install -y --override-channels \
        --prefix "${SETUP_SIM_MINICONDA_DIR}" -c "${channel}" "$@" || return 1
}

_setup_sim_ensure_local_build_tools() {
    local compiler_triplet=""
    local compiler_packages=""
    local gcc_pkg=""
    local gxx_pkg=""
    local -a missing_packages=()

    _setup_sim_ensure_miniconda || return 1
    _setup_sim_prepare_local_toolchain_env

    compiler_triplet="$(_setup_sim_choose_conda_triplet)" || return 1
    compiler_packages="$(_setup_sim_conda_compiler_packages)" || return 1
    read -r gcc_pkg gxx_pkg <<<"${compiler_packages}"

    command -v git >/dev/null 2>&1 || missing_packages+=("git")
    [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/cmake" ]] || missing_packages+=("cmake")
    [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/ninja" ]] || missing_packages+=("ninja")
    [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/make" ]] || missing_packages+=("make")
    [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/${compiler_triplet}-gcc" ]] || missing_packages+=("${gcc_pkg}")
    [[ -x "${SETUP_SIM_MINICONDA_DIR}/bin/${compiler_triplet}-g++" ]] || missing_packages+=("${gxx_pkg}")

    if (( ${#missing_packages[@]} == 0 )); then
        return 0
    fi

    _setup_sim_log "installing local build tools: ${missing_packages[*]}"
    _setup_sim_conda_install "${missing_packages[@]}" || return 1
    _setup_sim_prepare_local_toolchain_env
}

_setup_sim_manual_clone_submodules() {
    local gitmodules_path="${SETUP_SIM_REPO_ROOT}/.gitmodules"
    local key=""
    local submodule_path=""
    local submodule_name=""
    local submodule_url=""
    local submodule_branch=""
    local submodule_dir=""
    local -a clone_cmd=()

    [[ -f "${gitmodules_path}" ]] || {
        _setup_sim_err "missing .gitmodules and required sources are absent"
        return 1
    }

    while read -r key submodule_path; do
        [[ -n "${submodule_path:-}" ]] || continue
        submodule_name="${key#submodule.}"
        submodule_name="${submodule_name%.path}"
        submodule_url="$(git config -f "${gitmodules_path}" --get "submodule.${submodule_name}.url" || true)"
        submodule_branch="$(git config -f "${gitmodules_path}" --get "submodule.${submodule_name}.branch" || true)"
        submodule_dir="${SETUP_SIM_REPO_ROOT}/${submodule_path}"

        if [[ -d "${submodule_dir}" ]] && [[ -n "$(ls -A "${submodule_dir}" 2>/dev/null)" ]]; then
            continue
        fi

        [[ -n "${submodule_url}" ]] || {
            _setup_sim_err "missing URL for submodule ${submodule_name} in .gitmodules"
            return 1
        }

        rm -rf "${submodule_dir}"
        mkdir -p "$(dirname "${submodule_dir}")"

        clone_cmd=(git clone --recursive --depth 1 --shallow-submodules)
        if [[ -n "${submodule_branch}" ]]; then
            clone_cmd+=(--branch "${submodule_branch}")
        fi
        clone_cmd+=("${submodule_url}" "${submodule_dir}")

        _setup_sim_run "${clone_cmd[@]}" || return 1
    done < <(git config -f "${gitmodules_path}" --get-regexp '^submodule\..*\.path$')
}

_setup_sim_repair_submodule_worktrees() {
    local gitmodules_path="${SETUP_SIM_REPO_ROOT}/.gitmodules"
    local key=""
    local submodule_path=""
    local submodule_dir=""

    [[ -f "${gitmodules_path}" ]] || return 0

    while read -r key submodule_path; do
        [[ -n "${submodule_path:-}" ]] || continue
        submodule_dir="${SETUP_SIM_REPO_ROOT}/${submodule_path}"
        [[ -d "${submodule_dir}" ]] || continue
        [[ -e "${submodule_dir}/.git" ]] || continue
        _setup_sim_run git -C "${submodule_dir}" checkout -f HEAD || return 1
    done < <(git config -f "${gitmodules_path}" --get-regexp '^submodule\..*\.path$')
}

_setup_sim_ensure_repo_sources() {
    if _setup_sim_have_repo_sources; then
        return 0
    fi

    _setup_sim_git_available || {
        _setup_sim_err "git is required to bootstrap missing repository sources"
        return 1
    }

    if [[ -d "${SETUP_SIM_REPO_ROOT}/.git" || -f "${SETUP_SIM_REPO_ROOT}/.git" ]]; then
        _setup_sim_log "bootstrapping submodules from current git checkout"
        if _setup_sim_run git -C "${SETUP_SIM_REPO_ROOT}" submodule update --init --recursive --depth 1; then
            :
        else
            _setup_sim_log "shallow submodule bootstrap failed; retrying full history"
            _setup_sim_run git -C "${SETUP_SIM_REPO_ROOT}" submodule update --init --recursive || return 1
        fi
    else
        _setup_sim_log "bootstrapping sources from .gitmodules"
        _setup_sim_manual_clone_submodules || return 1
    fi

    _setup_sim_repair_submodule_worktrees || return 1

    _setup_sim_have_repo_sources || {
        _setup_sim_err "required repository sources are still missing after bootstrap"
        return 1
    }
}

_setup_sim_choose_ptoas_bin() {
    if [[ -x "${SETUP_SIM_PTOAS_DIR}/ptoas" ]]; then
        printf '%s\n' "${SETUP_SIM_PTOAS_DIR}/ptoas"
        return 0
    fi

    if [[ -x "${SETUP_SIM_PTOAS_DIR}/bin/ptoas" ]]; then
        printf '%s\n' "${SETUP_SIM_PTOAS_DIR}/bin/ptoas"
        return 0
    fi

    return 1
}

_setup_sim_extract_tar_gz() {
    local archive_path="$1"
    local dest_dir="$2"

    _setup_sim_run env PYTHONPATH= "${SETUP_SIM_PYTHON_BIN}" - "$archive_path" "$dest_dir" <<'PY' || return 1
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1]).resolve()
dest = pathlib.Path(sys.argv[2]).resolve()
dest.mkdir(parents=True, exist_ok=True)

with tarfile.open(archive, "r:gz") as tar:
    tar.extractall(dest)
PY
}

_setup_sim_bootstrap_venv() {
    if [[ ! -x "${SETUP_SIM_VENV_DIR}/bin/python" ]]; then
        _setup_sim_run env PYTHONPATH= "${SETUP_SIM_PYTHON_BIN}" -m venv "${SETUP_SIM_VENV_DIR}" || return 1
    fi

    "${SETUP_SIM_VENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1 || {
        _setup_sim_run env PYTHONPATH= "${SETUP_SIM_VENV_DIR}/bin/python" -m ensurepip --upgrade || return 1
    }
}

_setup_sim_pip() {
    local python_bin="$1"
    shift

    if [[ -n "${SETUP_SIM_PIP_INDEX_URL:-}" ]]; then
        if [[ "${SETUP_SIM_PIP_INDEX_URL}" == http://* || "${SETUP_SIM_PIP_INDEX_URL}" == https://* ]]; then
            _setup_sim_run_with_local_build_env_for_url "${SETUP_SIM_PIP_INDEX_URL}" \
                PYTHONPATH= \
                PIP_INDEX_URL="${SETUP_SIM_PIP_INDEX_URL}" \
                "${python_bin}" -m pip "$@" || return 1
            return 0
        fi

        _setup_sim_run_with_local_build_env \
            PYTHONPATH= \
            PIP_INDEX_URL="${SETUP_SIM_PIP_INDEX_URL}" \
            "${python_bin}" -m pip "$@" || return 1
        return 0
    fi

    _setup_sim_run_with_local_build_env PYTHONPATH= "${python_bin}" -m pip "$@" || return 1
}

_setup_sim_pip_torch() {
    local python_bin="$1"
    shift

    if [[ -n "${SETUP_SIM_TORCH_INDEX_URL:-}" ]]; then
        if [[ -n "${SETUP_SIM_PIP_INDEX_URL:-}" ]]; then
            _setup_sim_run_with_local_build_env PYTHONPATH= \
                PIP_INDEX_URL="${SETUP_SIM_TORCH_INDEX_URL}" \
                PIP_EXTRA_INDEX_URL="${SETUP_SIM_PIP_INDEX_URL}" \
                "${python_bin}" -m pip "$@" || return 1
            return 0
        fi

        _setup_sim_run_with_local_build_env PYTHONPATH= PIP_INDEX_URL="${SETUP_SIM_TORCH_INDEX_URL}" \
            "${python_bin}" -m pip "$@" || return 1
        return 0
    fi

    _setup_sim_pip "${python_bin}" "$@" || return 1
}

_setup_sim_install_python_deps() {
    _setup_sim_install_torch_dep || return 1
    _setup_sim_install_pypto_dep || return 1
}

_setup_sim_install_torch_dep() {
    if ! "${SETUP_SIM_VENV_DIR}/bin/python" -c "import torch" >/dev/null 2>&1; then
        _setup_sim_pip_torch "${SETUP_SIM_VENV_DIR}/bin/python" install torch || return 1
    else
        _setup_sim_log "torch already available in ${SETUP_SIM_VENV_DIR}"
    fi
}

_setup_sim_install_pypto_build_deps() {
    if ! "${SETUP_SIM_VENV_DIR}/bin/python" -c "import nanobind, scikit_build_core" >/dev/null 2>&1; then
        _setup_sim_pip "${SETUP_SIM_VENV_DIR}/bin/python" install \
            "nanobind>=2.0.0" \
            "scikit-build-core>=0.10.0" || return 1
    fi
}

_setup_sim_install_pypto_dep() {
    if ! "${SETUP_SIM_VENV_DIR}/bin/python" -c "import pypto" >/dev/null 2>&1; then
        _setup_sim_install_pypto_build_deps || return 1
        _setup_sim_pip "${SETUP_SIM_VENV_DIR}/bin/python" install --no-build-isolation -e \
            "${SETUP_SIM_REPO_ROOT}/frameworks/pypto" || return 1
    else
        _setup_sim_log "pypto already available in ${SETUP_SIM_VENV_DIR}"
    fi
}

_setup_sim_ensure_ptoas() {
    local existing_bin=""
    local arch=""
    local archive_url=""
    local archive_fallback_url=""
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
    archive_fallback_url="https://github.com/zhangstevenunity/PTOAS/releases/download/v${SETUP_SIM_PTOAS_VERSION}/ptoas-bin-${arch}.tar.gz"
    archive_url="${SETUP_SIM_PTOAS_PRIMARY_PREFIX}${archive_fallback_url}"

    tmp_dir="$(mktemp -d)"
    archive_path="${tmp_dir}/ptoas-bin-${arch}.tar.gz"

    _setup_sim_log "downloading ptoas ${SETUP_SIM_PTOAS_VERSION} for ${arch}"
    _setup_sim_download "${archive_url}" "${archive_path}" || {
        _setup_sim_log "primary ptoas download failed; retrying via GitHub release URL"
        _setup_sim_download "${archive_fallback_url}" "${archive_path}"
    } || {
        rm -rf "${tmp_dir}"
        return 1
    }

    rm -rf "${SETUP_SIM_PTOAS_DIR}"
    mkdir -p "${SETUP_SIM_PTOAS_DIR}"
    _setup_sim_extract_tar_gz "${archive_path}" "${SETUP_SIM_PTOAS_DIR}" || {
        rm -rf "${tmp_dir}"
        return 1
    }
    rm -rf "${tmp_dir}"

    [[ -f "${SETUP_SIM_PTOAS_DIR}/bin/ptoas" ]] && chmod +x "${SETUP_SIM_PTOAS_DIR}/bin/ptoas"
    [[ -f "${SETUP_SIM_PTOAS_DIR}/ptoas" ]] && chmod +x "${SETUP_SIM_PTOAS_DIR}/ptoas"

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
    _setup_sim_prepare_local_toolchain_env
    _setup_sim_prepare_ascend_env || return 1
    _setup_sim_prepend_path_force "${SETUP_SIM_VENV_DIR}/bin"
    export SIMPLER_ROOT="${SETUP_SIM_REPO_ROOT}/frameworks/simpler"
    export PTOAS_ROOT="$(cd "$(dirname "${SETUP_SIM_PTOAS_BIN}")" && pwd)"
    export PTO_ISA_ROOT="${SETUP_SIM_REPO_ROOT}/upstream/pto-isa"
    export LD_LIBRARY_PATH="$(_setup_sim_runtime_ld_library_path)"
    unset AR AS CPP CPPFLAGS CFLAGS CXXFLAGS LDFLAGS LD NM RANLIB STRIP
    unset CC_FOR_BUILD CXX_FOR_BUILD CMAKE_ARGS CMAKE_PREFIX_PATH
    unset CONDA_BUILD_SYSROOT CONDA_TOOLCHAIN_BUILD CONDA_TOOLCHAIN_HOST
    export CC="$(_setup_sim_local_cc)"
    export CXX="$(_setup_sim_local_cxx)"
    export PTO2_RING_TASK_WINDOW="${PTO2_RING_TASK_WINDOW:-128}"
    export PTO2_RING_HEAP="${PTO2_RING_HEAP:-8388608}"
    export PTO2_RING_DEP_POOL="${PTO2_RING_DEP_POOL:-256}"
    _setup_sim_refresh_shell_hash
    _setup_sim_log "active python: $(command -v python)"
}

_setup_sim_validate_env() {
    "${SETUP_SIM_VENV_DIR}/bin/python" -c "import torch, pypto" >/dev/null 2>&1 || {
        _setup_sim_err "python environment is incomplete; torch or pypto import failed"
        return 1
    }

    env LD_LIBRARY_PATH="$(_setup_sim_runtime_ld_library_path)" \
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

    _setup_sim_ensure_local_build_tools || return 1
    _setup_sim_prepare_local_toolchain_env
    _setup_sim_ensure_repo_sources || return 1
    SETUP_SIM_PYTHON_BIN="$(_setup_sim_choose_python)" || return 1
    _setup_sim_log "using python: ${SETUP_SIM_PYTHON_BIN}"
    _setup_sim_require_cmd cmake || return 1
    _setup_sim_require_cmd ninja || return 1
    _setup_sim_require_cmd gcc || return 1
    _setup_sim_require_cmd g++ || return 1
    _setup_sim_warn_optional_cmd \
        g++-15 \
        "g++-15 not found; bootstrap will continue, but sim kernel compilation may fail later"
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
SETUP_SIM_TOOLS_DIR="${SETUP_SIM_TOOLS_DIR:-${SETUP_SIM_REPO_ROOT}/.tools}"
SETUP_SIM_TOOLS_BIN_DIR="${SETUP_SIM_TOOLS_BIN_DIR:-${SETUP_SIM_TOOLS_DIR}/bin}"
SETUP_SIM_MINICONDA_DIR="${SETUP_SIM_MINICONDA_DIR:-${SETUP_SIM_TOOLS_DIR}/miniconda3}"
SETUP_SIM_MINICONDA_URL_BASE="${SETUP_SIM_MINICONDA_URL_BASE:-https://repo.anaconda.com/miniconda}"
SETUP_SIM_CONDA_CHANNEL="${SETUP_SIM_CONDA_CHANNEL:-conda-forge}"
SETUP_SIM_CONDA_FALLBACK_CHANNEL="${SETUP_SIM_CONDA_FALLBACK_CHANNEL:-conda-forge}"
SETUP_SIM_DIRECT_HOSTS="${SETUP_SIM_DIRECT_HOSTS:-mirrors.ustc.edu.cn mirrors.tuna.tsinghua.edu.cn pypi.tuna.tsinghua.edu.cn}"
SETUP_SIM_VENV_DIR="${SETUP_SIM_VENV_DIR:-${SETUP_SIM_REPO_ROOT}/.venv-pto-sim}"
SETUP_SIM_PTOAS_DIR="${SETUP_SIM_PTOAS_DIR:-${SETUP_SIM_REPO_ROOT}/.tools/ptoas-bin}"
SETUP_SIM_PTOAS_VERSION="${SETUP_SIM_PTOAS_VERSION:-0.17}"
SETUP_SIM_PTOAS_PRIMARY_PREFIX="${SETUP_SIM_PTOAS_PRIMARY_PREFIX:-https://ghpull.com/}"
SETUP_SIM_PIP_INDEX_URL="${SETUP_SIM_PIP_INDEX_URL:-}"
SETUP_SIM_TORCH_INDEX_URL="${SETUP_SIM_TORCH_INDEX_URL:-https://download.pytorch.org/whl/cpu}"

if [[ "${SETUP_SIM_LIBRARY_ONLY:-0}" == "1" ]]; then
    if _setup_sim_is_sourced; then
        return 0
    fi
    exit 0
fi

if _setup_sim_is_sourced; then
    _setup_sim_main "$@" || return $?
else
    _setup_sim_main "$@"
    exit $?
fi
