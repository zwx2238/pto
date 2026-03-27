#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


SAMPLE_BYTES = 1024 * 1024
TIMEOUT_SECONDS = 15.0


@dataclass
class ProbeResult:
    category: str
    name: str
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


def _build_opener(proxy_mode: str) -> urllib.request.OpenerDirector:
    if proxy_mode == "direct":
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener()


def _head_content_length(opener: urllib.request.OpenerDirector, url: str) -> int | None:
    try:
        request = urllib.request.Request(url, method="HEAD")
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            value = response.headers.get("Content-Length")
            return int(value) if value else None
    except Exception:
        return None


def _probe_url(category: str, name: str, url: str, proxy_mode: str) -> ProbeResult:
    opener = _build_opener(proxy_mode)
    content_length = _head_content_length(opener, url)
    request = urllib.request.Request(url, headers={"Range": f"bytes=0-{SAMPLE_BYTES - 1}"})
    start = time.perf_counter()
    bytes_read = 0

    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
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
            name=name,
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
            name=name,
            url=url,
            proxy_mode=proxy_mode,
            ok=False,
            bytes_read=bytes_read,
            duration_s=duration_s,
            throughput_bps=None,
            content_length=content_length,
            estimated_total_s=None,
            error=str(exc),
        )


def _probe_conda_package(channel_base: str, arch: str, proxy_mode: str) -> ProbeResult:
    if channel_base == "conda-forge":
        url = f"https://conda.anaconda.org/conda-forge/linux-{arch}/cmake-4.3.0-hc9d863e_0.conda"
        return _probe_url("conda_package", "origin_pkg", url, proxy_mode)

    parsed = urllib.parse.urlparse(channel_base)
    if "/anaconda/cloud/conda-forge" in channel_base:
        url = f"{parsed.scheme}://{parsed.netloc}/anaconda/cloud/conda-forge/linux-{arch}/cmake-4.3.0-hc9d863e_0.conda"
    else:
        url = f"{parsed.scheme}://{parsed.netloc}/conda-forge/linux-{arch}/cmake-4.3.0-hc9d863e_0.conda"
    return _probe_url("conda_package", parsed.netloc, url, proxy_mode)


def _measure_git_ls_remote(url: str) -> dict:
    start = time.perf_counter()
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--heads", url, "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        duration_s = time.perf_counter() - start
        return {
            "url": url,
            "ok": result.returncode == 0,
            "duration_s": duration_s,
            "error": None if result.returncode == 0 else (result.stderr.strip() or result.stdout.strip()),
        }
    except Exception as exc:
        return {
            "url": url,
            "ok": False,
            "duration_s": time.perf_counter() - start,
            "error": str(exc),
        }


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


def _choose_best(results: Iterable[ProbeResult]) -> ProbeResult | None:
    ok_results = [result for result in results if result.ok and result.throughput_bps]
    if not ok_results:
        return None
    return max(ok_results, key=lambda item: item.throughput_bps or 0.0)


def _discover_torch_wheel_url() -> str | None:
    py_tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    arch = _detect_arch()
    arch_tag = "aarch64" if arch == "aarch64" else "x86_64"
    index_url = "https://download.pytorch.org/whl/cpu/torch/"

    try:
        with urllib.request.urlopen(index_url, timeout=TIMEOUT_SECONDS) as response:
            html = response.read().decode("utf-8", errors="replace")
    except Exception:
        return None

    pattern = re.compile(
        rf'href=[\'"](?P<href>[^\'"]*torch-(?P<version>[0-9][^\'"/]*)(?:\+|%2B)cpu-{py_tag}-{py_tag}-(?:manylinux[^\'"]*|linux_{arch_tag})\.whl)[\'"]'
    )
    matches = list(pattern.finditer(html))
    if not matches:
        return None

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
    return urllib.parse.urljoin(index_url, best.group("href"))


def _repo_size_hints(repo_root: Path) -> dict[str, int | None]:
    hints = {}
    targets = {
        "frameworks/pypto": repo_root / "frameworks/pypto",
        "frameworks/simpler": repo_root / "frameworks/simpler",
        "models/pypto-lib": repo_root / "models/pypto-lib",
        "upstream/pto-isa": repo_root / "upstream/pto-isa",
    }
    for key, path in targets.items():
        if path.exists():
            try:
                output = subprocess.check_output(["du", "-sb", str(path)], text=True)
                hints[key] = int(output.split()[0])
            except Exception:
                hints[key] = None
        else:
            hints[key] = None
    return hints


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "json", "shell"), default="text")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    arch = _detect_arch()
    proxy_env = {
        key: value
        for key, value in os.environ.items()
        if key in {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"}
    }

    miniconda_file = f"Miniconda3-latest-Linux-{arch}.sh"
    ptoas_file = f"ptoas-bin-{arch}.tar.gz"
    ptoas_release = f"https://github.com/zhangstevenunity/PTOAS/releases/download/v0.17/{ptoas_file}"
    torch_wheel_url = _discover_torch_wheel_url()

    candidates = {
        "miniconda": [
            ("anaconda", f"https://repo.anaconda.com/miniconda/{miniconda_file}", "env"),
            ("ustc", f"https://mirrors.ustc.edu.cn/anaconda/miniconda/{miniconda_file}", "direct"),
            ("tuna", f"https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/{miniconda_file}", "direct"),
        ],
        "conda_forge": [
            ("origin", f"https://conda.anaconda.org/conda-forge/linux-{arch}/repodata.json", "env"),
            ("ustc", f"https://mirrors.ustc.edu.cn/anaconda/cloud/conda-forge/linux-{arch}/repodata.json", "direct"),
            ("tuna", f"https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/linux-{arch}/repodata.json", "direct"),
        ],
        "pip_index": [
            ("ustc", "https://mirrors.ustc.edu.cn/pypi/simple/pip/", "direct"),
            ("tuna", "https://pypi.tuna.tsinghua.edu.cn/simple/pip/", "direct"),
            ("pypi", "https://pypi.org/simple/pip/", "env"),
        ],
        "ptoas_release": [
            ("ghpull", f"https://ghpull.com/{ptoas_release}", "env"),
            ("github", ptoas_release, "env"),
        ],
    }
    if torch_wheel_url:
        candidates["torch_wheel"] = [
            ("pytorch", torch_wheel_url, "env"),
        ]

    all_results: dict[str, list[ProbeResult]] = {}
    selected_exports: dict[str, str] = {}

    for category, entries in candidates.items():
        category_results = [_probe_url(category, name, url, proxy_mode) for name, url, proxy_mode in entries]
        all_results[category] = category_results

    best_miniconda = _choose_best(all_results["miniconda"])
    if best_miniconda is not None:
        parsed = urllib.parse.urlparse(best_miniconda.url)
        selected_exports["SETUP_SIM_MINICONDA_URL_BASE"] = f"{parsed.scheme}://{parsed.netloc}/anaconda/miniconda" if "/anaconda/miniconda/" in best_miniconda.url else f"{parsed.scheme}://{parsed.netloc}/miniconda"

    best_conda = _choose_best(all_results["conda_forge"])
    conda_channel_candidates = []
    if best_conda is not None:
        parsed = urllib.parse.urlparse(best_conda.url)
        if "/anaconda/cloud/conda-forge/" in best_conda.url:
            conda_channel_candidates.append((f"{parsed.scheme}://{parsed.netloc}/anaconda/cloud/conda-forge", best_conda.proxy_mode))
        else:
            conda_channel_candidates.append(("conda-forge", best_conda.proxy_mode))
    conda_channel_candidates.append(("conda-forge", "env"))

    conda_package_results = []
    seen_conda_channels = set()
    for channel_base, proxy_mode in conda_channel_candidates:
        if channel_base in seen_conda_channels:
            continue
        seen_conda_channels.add(channel_base)
        conda_package_results.append(_probe_conda_package(channel_base, arch, proxy_mode))
    all_results["conda_package"] = conda_package_results

    best_conda_package = _choose_best(conda_package_results)
    if best_conda_package is not None:
        parsed = urllib.parse.urlparse(best_conda_package.url)
        if "/anaconda/cloud/conda-forge/" in best_conda_package.url:
            selected_exports["SETUP_SIM_CONDA_CHANNEL"] = f"{parsed.scheme}://{parsed.netloc}/anaconda/cloud/conda-forge"
        else:
            selected_exports["SETUP_SIM_CONDA_CHANNEL"] = "conda-forge"

    best_pip = _choose_best(all_results["pip_index"])
    if best_pip is not None:
        parsed = urllib.parse.urlparse(best_pip.url)
        selected_exports["SETUP_SIM_PIP_INDEX_URL"] = f"{parsed.scheme}://{parsed.netloc}{parsed.path.removesuffix('/pip/')}"
        if selected_exports["SETUP_SIM_PIP_INDEX_URL"].endswith("/simple"):
            pass
        elif selected_exports["SETUP_SIM_PIP_INDEX_URL"].endswith("/simple/"):
            selected_exports["SETUP_SIM_PIP_INDEX_URL"] = selected_exports["SETUP_SIM_PIP_INDEX_URL"].rstrip("/")
        else:
            selected_exports["SETUP_SIM_PIP_INDEX_URL"] = selected_exports["SETUP_SIM_PIP_INDEX_URL"].rstrip("/")

    best_ptoas = _choose_best(all_results["ptoas_release"])
    if best_ptoas is not None:
        if best_ptoas.name == "github":
            selected_exports["SETUP_SIM_PTOAS_PRIMARY_PREFIX"] = ""
        else:
            selected_exports["SETUP_SIM_PTOAS_PRIMARY_PREFIX"] = "https://ghpull.com/"

    git_targets = [
        "https://github.com/hw-native-sys/pypto.git",
        "https://github.com/zwx2238/simpler.git",
        "https://github.com/hw-native-sys/pypto-lib.git",
        "https://github.com/zwx2238/pto-isa.git",
    ]
    git_probe = [_measure_git_ls_remote(url) for url in git_targets]

    report = {
        "arch": arch,
        "proxy_env": proxy_env,
        "sample_bytes": SAMPLE_BYTES,
        "url_probes": {
            category: [asdict(result) for result in results]
            for category, results in all_results.items()
        },
        "selected_exports": selected_exports,
        "git_probe": git_probe,
        "repo_size_hints": _repo_size_hints(repo_root),
    }

    if args.format == "json":
        print(json.dumps(report, indent=2))
        return 0

    if args.format == "shell":
        for key, value in selected_exports.items():
            print(f"export {key}={json.dumps(value)}")
        return 0

    print("Bootstrap Probe")
    print(f"arch: {arch}")
    if proxy_env:
        print("proxy:")
        for key, value in proxy_env.items():
            print(f"  {key}={value}")
    else:
        print("proxy: none")

    print("")
    for category, results in all_results.items():
        print(f"[{category}]")
        for result in results:
            status = "OK" if result.ok else "FAIL"
            print(
                f"  {result.name:8s} {status:4s} "
                f"proxy={result.proxy_mode:6s} "
                f"sample={_format_bytes(result.bytes_read):>10s} "
                f"time={_format_seconds(result.duration_s):>8s} "
                f"speed={_format_speed(result.throughput_bps):>12s} "
                f"size={_format_bytes(result.content_length):>10s} "
                f"eta={_format_seconds(result.estimated_total_s):>8s}"
            )
            if result.error:
                print(f"    error: {result.error}")
        best = _choose_best(results)
        if best is not None:
            print(f"  recommended: {best.name} -> {best.url}")
        print("")

    print("[git_probe]")
    for item in git_probe:
        status = "OK" if item["ok"] else "FAIL"
        print(f"  {status:4s} time={item['duration_s']:.2f}s url={item['url']}")
        if item["error"]:
            print(f"    error: {item['error']}")

    print("")
    print("[repo_size_hints]")
    for key, value in report["repo_size_hints"].items():
        print(f"  {key}: {_format_bytes(value)}")

    if selected_exports:
        print("")
        print("[recommended_env]")
        for key, value in selected_exports.items():
            print(f"  export {key}={json.dumps(value)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
