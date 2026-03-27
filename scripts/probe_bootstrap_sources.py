#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import tarfile
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path


SAMPLE_BYTES = 128 * 1024
TOTAL_BUDGET_SECONDS = 10.0
PER_PROBE_TIMEOUT_SECONDS = 2.0
DEFAULT_MINICONDA_URL_BASE = "https://repo.anaconda.com/miniconda"
DEFAULT_CONDA_CHANNEL = "conda-forge"
DEFAULT_DIRECT_HOSTS = "mirrors.ustc.edu.cn mirrors.tuna.tsinghua.edu.cn pypi.tuna.tsinghua.edu.cn"
DEFAULT_PTOAS_ARCHIVE = ""
DEFAULT_PIP_INDEX_URL = ""
DEFAULT_TORCH_INDEX_URL = "https://download.pytorch.org/whl/cpu"


@dataclass
class ProbeResult:
    category: str
    url: str
    proxy_mode: str
    ok: bool
    bytes_read: int
    duration_s: float
    throughput_bps: float | None
    content_length: int | None
    estimated_total_s: float | None
    error: str | None


def _detect_arch() -> str:
    machine = os.uname().machine
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    if machine in {"aarch64", "arm64"}:
        return "aarch64"
    return machine


def _format_bytes(num_bytes: int | None) -> str:
    if num_bytes is None:
        return "n/a"
    value = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024.0 or unit == "GiB":
            return f"{value:.2f} {unit}"
        value /= 1024.0
    return f"{value:.2f} GiB"


def _format_speed(bps: float | None) -> str:
    if bps is None:
        return "n/a"
    value = float(bps)
    for unit in ("B/s", "KiB/s", "MiB/s", "GiB/s"):
        if value < 1024.0 or unit == "GiB/s":
            return f"{value:.2f} {unit}"
        value /= 1024.0
    return f"{value:.2f} GiB/s"


def _format_seconds(seconds: float | None) -> str:
    if seconds is None:
        return "n/a"
    return f"{seconds:.1f}s"


def _split_hosts(raw: str) -> set[str]:
    return {item for item in re.split(r"[\s,]+", raw.strip()) if item}


def _configured_exports() -> dict[str, str]:
    exports = {
        "SETUP_SIM_MINICONDA_URL_BASE": os.environ.get(
            "SETUP_SIM_MINICONDA_URL_BASE", DEFAULT_MINICONDA_URL_BASE
        ),
        "SETUP_SIM_CONDA_CHANNEL": os.environ.get(
            "SETUP_SIM_CONDA_CHANNEL", DEFAULT_CONDA_CHANNEL
        ),
        "SETUP_SIM_PTOAS_ARCHIVE": os.environ.get(
            "SETUP_SIM_PTOAS_ARCHIVE", DEFAULT_PTOAS_ARCHIVE
        ),
        "SETUP_SIM_PIP_INDEX_URL": os.environ.get(
            "SETUP_SIM_PIP_INDEX_URL", DEFAULT_PIP_INDEX_URL
        ),
        "SETUP_SIM_TORCH_INDEX_URL": os.environ.get(
            "SETUP_SIM_TORCH_INDEX_URL", DEFAULT_TORCH_INDEX_URL
        ),
    }
    if "SETUP_SIM_DIRECT_HOSTS" in os.environ:
        exports["SETUP_SIM_DIRECT_HOSTS"] = os.environ["SETUP_SIM_DIRECT_HOSTS"]
    return exports


def _configured_direct_hosts() -> set[str]:
    raw = os.environ.get("SETUP_SIM_DIRECT_HOSTS", DEFAULT_DIRECT_HOSTS)
    return _split_hosts(raw)


def _proxy_mode_for_url(url: str, direct_hosts: set[str]) -> str:
    host = urllib.parse.urlparse(url).hostname or ""
    if host in direct_hosts:
        return "direct"
    return "env"


def _build_opener(proxy_mode: str) -> urllib.request.OpenerDirector:
    https_handler = urllib.request.HTTPSHandler(context=ssl._create_unverified_context())
    if proxy_mode == "direct":
        return urllib.request.build_opener(urllib.request.ProxyHandler({}), https_handler)
    return urllib.request.build_opener(https_handler)


def _remaining_timeout(deadline: float) -> float:
    remaining = deadline - time.perf_counter()
    if remaining <= 0:
        return 0.0
    return min(PER_PROBE_TIMEOUT_SECONDS, remaining)


def _parse_content_length(response: urllib.response.addinfourl) -> int | None:
    content_range = response.headers.get("Content-Range")
    if content_range:
        match = re.search(r"/(\d+)$", content_range)
        if match:
            return int(match.group(1))

    value = response.headers.get("Content-Length")
    if value and value.isdigit():
        return int(value)
    return None


def _probe_url(category: str, url: str, proxy_mode: str, deadline: float) -> ProbeResult:
    timeout = _remaining_timeout(deadline)
    if timeout <= 0:
        return ProbeResult(
            category=category,
            url=url,
            proxy_mode=proxy_mode,
            ok=False,
            bytes_read=0,
            duration_s=0.0,
            throughput_bps=None,
            content_length=None,
            estimated_total_s=None,
            error=f"probe budget exceeded ({TOTAL_BUDGET_SECONDS:.0f}s)",
        )

    opener = _build_opener(proxy_mode)
    request = urllib.request.Request(url, headers={"Range": f"bytes=0-{SAMPLE_BYTES - 1}"})
    start = time.perf_counter()
    bytes_read = 0

    try:
        with opener.open(request, timeout=timeout) as response:
            content_length = _parse_content_length(response)
            while bytes_read < SAMPLE_BYTES:
                chunk = response.read(min(65536, SAMPLE_BYTES - bytes_read))
                if not chunk:
                    break
                bytes_read += len(chunk)

        duration_s = max(time.perf_counter() - start, 1e-6)
        throughput_bps = bytes_read / duration_s if bytes_read else None
        estimated_total_s = None
        if content_length and throughput_bps:
            estimated_total_s = content_length / throughput_bps
        return ProbeResult(
            category=category,
            url=url,
            proxy_mode=proxy_mode,
            ok=True,
            bytes_read=bytes_read,
            duration_s=duration_s,
            throughput_bps=throughput_bps,
            content_length=content_length,
            estimated_total_s=estimated_total_s,
            error=None,
        )
    except Exception as exc:
        duration_s = max(time.perf_counter() - start, 1e-6)
        return ProbeResult(
            category=category,
            url=url,
            proxy_mode=proxy_mode,
            ok=False,
            bytes_read=bytes_read,
            duration_s=duration_s,
            throughput_bps=None,
            content_length=None,
            estimated_total_s=None,
            error=str(exc),
        )


def _resolve_miniconda_url(base_url: str, arch: str) -> str:
    installer = f"Miniconda3-latest-Linux-{arch}.sh"
    return f"{base_url.rstrip('/')}/{installer}"


def _resolve_conda_package_url(channel_base: str, arch: str) -> str:
    package_name = "cmake-4.3.0-hc9d863e_0.conda"
    if channel_base == "conda-forge":
        return f"https://conda.anaconda.org/conda-forge/linux-{arch}/{package_name}"
    return f"{channel_base.rstrip('/')}/linux-{arch}/{package_name}"


def _resolve_pip_probe_url(index_url: str) -> str:
    base = index_url.rstrip("/")
    if base.endswith("/simple"):
        return f"{base}/pip/"
    return base


def _probe_local_archive(category: str, archive_path: str) -> ProbeResult:
    if not archive_path:
        return ProbeResult(
            category=category,
            url="",
            proxy_mode="local",
            ok=False,
            bytes_read=0,
            duration_s=0.0,
            throughput_bps=None,
            content_length=None,
            estimated_total_s=None,
            error="SETUP_SIM_PTOAS_ARCHIVE is not set",
        )

    path = Path(archive_path).expanduser()
    start = time.perf_counter()
    if not path.is_file():
        return ProbeResult(
            category=category,
            url=str(path),
            proxy_mode="local",
            ok=False,
            bytes_read=0,
            duration_s=max(time.perf_counter() - start, 1e-6),
            throughput_bps=None,
            content_length=None,
            estimated_total_s=None,
            error=f"archive not found: {path}",
        )

    try:
        with tarfile.open(path, "r:gz") as tar:
            names = tar.getnames()
        if not any(name == "ptoas" or name.endswith("/ptoas") for name in names):
            raise RuntimeError("ptoas executable not found in archive")
    except Exception as exc:
        return ProbeResult(
            category=category,
            url=str(path),
            proxy_mode="local",
            ok=False,
            bytes_read=0,
            duration_s=max(time.perf_counter() - start, 1e-6),
            throughput_bps=None,
            content_length=path.stat().st_size if path.exists() else None,
            estimated_total_s=None,
            error=str(exc),
        )

    duration_s = max(time.perf_counter() - start, 1e-6)
    file_size = path.stat().st_size
    return ProbeResult(
        category=category,
        url=str(path),
        proxy_mode="local",
        ok=True,
        bytes_read=file_size,
        duration_s=duration_s,
        throughput_bps=None,
        content_length=file_size,
        estimated_total_s=None,
        error=None,
    )


def _discover_torch_wheel_url(index_url: str, deadline: float, proxy_mode: str) -> str | None:
    if index_url.endswith(".whl"):
        return index_url

    listing_url = f"{index_url.rstrip('/')}/torch/"
    timeout = _remaining_timeout(deadline)
    if timeout <= 0:
        return None

    opener = _build_opener(proxy_mode)
    py_tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    arch = _detect_arch()
    arch_tag = "aarch64" if arch == "aarch64" else "x86_64"

    try:
        with opener.open(listing_url, timeout=timeout) as response:
            html = response.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    pattern = re.compile(
        rf'href=[\'"](?P<href>[^\'"]*torch-(?P<version>[0-9][^\'"/]*)(?:\+|%2B)cpu-{py_tag}-{py_tag}-(?:manylinux[^\'"]*|linux_{arch_tag})\.whl)[\'"]'
    )
    matches = list(pattern.finditer(html))
    if not matches:
        return listing_url

    def _version_key(raw_version: str) -> tuple:
        parts = re.split(r"[.+-]", raw_version)
        key = []
        for part in parts:
            if part.isdigit():
                key.append((0, int(part)))
            else:
                key.append((1, part))
        return tuple(key)

    best = max(matches, key=lambda item: _version_key(item.group("version")))
    return urllib.parse.urljoin(listing_url, best.group("href"))


def _build_probe_plan(configured_exports: dict[str, str], arch: str, deadline: float) -> list[tuple[str, str, str]]:
    direct_hosts = _configured_direct_hosts()

    miniconda_url = _resolve_miniconda_url(configured_exports["SETUP_SIM_MINICONDA_URL_BASE"], arch)
    conda_url = _resolve_conda_package_url(configured_exports["SETUP_SIM_CONDA_CHANNEL"], arch)

    torch_index_url = configured_exports["SETUP_SIM_TORCH_INDEX_URL"]
    torch_proxy_mode = _proxy_mode_for_url(torch_index_url, direct_hosts)
    torch_url = _discover_torch_wheel_url(torch_index_url, deadline, torch_proxy_mode) or torch_index_url

    plan = [
        ("miniconda", miniconda_url, _proxy_mode_for_url(miniconda_url, direct_hosts)),
        ("conda_package", conda_url, _proxy_mode_for_url(conda_url, direct_hosts)),
    ]
    if configured_exports["SETUP_SIM_PIP_INDEX_URL"]:
        pip_url = _resolve_pip_probe_url(configured_exports["SETUP_SIM_PIP_INDEX_URL"])
        plan.append(("pip_index", pip_url, _proxy_mode_for_url(pip_url, direct_hosts)))
    plan.append(("torch", torch_url, _proxy_mode_for_url(torch_url, direct_hosts)))
    return plan


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "json", "shell"), default="text")
    args = parser.parse_args()

    configured_exports = _configured_exports()
    if args.format == "shell":
        for key, value in configured_exports.items():
            print(f"export {key}={json.dumps(value)}")
        return 0

    arch = _detect_arch()
    proxy_env = {
        key: value
        for key, value in os.environ.items()
        if key in {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"}
    }

    start = time.perf_counter()
    deadline = start + TOTAL_BUDGET_SECONDS
    probes = [
        _probe_url(category, url, proxy_mode, deadline)
        for category, url, proxy_mode in _build_probe_plan(configured_exports, arch, deadline)
    ]
    probes.append(_probe_local_archive("ptoas_archive", configured_exports["SETUP_SIM_PTOAS_ARCHIVE"]))
    elapsed = time.perf_counter() - start

    report = {
        "arch": arch,
        "budget_seconds": TOTAL_BUDGET_SECONDS,
        "sample_bytes": SAMPLE_BYTES,
        "total_duration_s": elapsed,
        "proxy_env": proxy_env,
        "configured_exports": configured_exports,
        "url_probes": [asdict(result) for result in probes],
    }

    if args.format == "json":
        print(json.dumps(report, indent=2))
        return 0

    print("Bootstrap Probe")
    print(f"arch: {arch}")
    print(f"budget: {TOTAL_BUDGET_SECONDS:.0f}s")
    print(f"sample_bytes: {SAMPLE_BYTES}")
    print(f"elapsed: {elapsed:.2f}s")
    if proxy_env:
        print("proxy:")
        for key, value in proxy_env.items():
            print(f"  {key}={value}")
    else:
        print("proxy: none")

    print("")
    print("[configured_env]")
    for key, value in configured_exports.items():
        print(f"  {key}={json.dumps(value)}")

    print("")
    print("[probe_results]")
    for result in probes:
        status = "OK" if result.ok else "FAIL"
        print(
            f"  {result.category:13s} {status:4s} "
            f"proxy={result.proxy_mode:6s} "
            f"sample={_format_bytes(result.bytes_read):>10s} "
            f"time={_format_seconds(result.duration_s):>8s} "
            f"speed={_format_speed(result.throughput_bps):>12s} "
            f"size={_format_bytes(result.content_length):>10s} "
            f"eta={_format_seconds(result.estimated_total_s):>8s}"
        )
        print(f"    url: {result.url}")
        if result.error:
            print(f"    error: {result.error}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
