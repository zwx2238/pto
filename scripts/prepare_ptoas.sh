#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v python >/dev/null 2>&1; then
    printf '[prepare-ptoas] ERROR: python not found in current shell\n' >&2
    exit 1
fi

if [[ -z "${SETUP_SIM_PTOAS_ARCHIVE:-}" ]]; then
    printf '[prepare-ptoas] ERROR: SETUP_SIM_PTOAS_ARCHIVE is not set\n' >&2
    exit 1
fi

PTOAS_ARCHIVE="${SETUP_SIM_PTOAS_ARCHIVE/#\~/${HOME}}"
PTOAS_DIR="${SETUP_SIM_PTOAS_DIR:-${REPO_ROOT}/.tools/ptoas-bin}"

_ptoas_log() {
    printf '[prepare-ptoas] %s\n' "$*"
}

_ptoas_log "archive: ${PTOAS_ARCHIVE}"
_ptoas_log "target dir: ${PTOAS_DIR}"

python - "${PTOAS_ARCHIVE}" "${PTOAS_DIR}" <<'PY'
import pathlib
import shutil
import sys
import tarfile

archive = pathlib.Path(sys.argv[1]).expanduser().resolve()
dest = pathlib.Path(sys.argv[2]).resolve()

if not archive.is_file():
    raise SystemExit(f"[prepare-ptoas] ERROR: archive not found: {archive}")

with tarfile.open(archive, "r:gz") as tar:
    names = tar.getnames()
    if not any(name == "ptoas" or name.endswith("/ptoas") for name in names):
        raise SystemExit(f"[prepare-ptoas] ERROR: ptoas executable not found in archive: {archive}")

if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True, exist_ok=True)

with tarfile.open(archive, "r:gz") as tar:
    tar.extractall(dest)

candidates = [dest / "ptoas", dest / "bin" / "ptoas"]
for candidate in candidates:
    if candidate.is_file():
        candidate.chmod(candidate.stat().st_mode | 0o111)
        print(candidate)
        break
else:
    raise SystemExit(f"[prepare-ptoas] ERROR: extracted archive but no ptoas executable under {dest}")
PY

_ptoas_log "done"
