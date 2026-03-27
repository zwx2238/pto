#!/usr/bin/env python3
"""Map logical `torch_npu` device ids to runtime physical device ids.

This script uses `torch_npu` to initialize each logical device and then reads the
newly-created Ascend runtime plog entry to extract:

    Setup device succeeded. (logical_devid=X; devid=Y; ...)

`torch_npu` itself exposes device count/name/memory, but not the runtime
physical `devid`, so the plog is the authoritative source for the mapping.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from pathlib import Path


PLOG_PATTERN = re.compile(r"Setup device succeeded\. \(logical_devid=(\d+); devid=(\d+);")


def run_probe(device_id: int, python_exe: str, plog_dir: Path) -> dict[str, object]:
    before = set(plog_dir.glob("plog-*.log"))
    code = (
        "import json, torch, torch_npu; "
        f"d={device_id}; "
        "torch.npu.set_device(d); "
        "x = torch.randn((2, 2), device=f'npu:{d}'); "
        "props = torch.npu.get_device_properties(d); "
        "print(json.dumps({"
        "'logical_d': d, "
        "'tensor_device': str(x.device), "
        "'device_name': torch.npu.get_device_name(d), "
        "'props_name': getattr(props, 'name', None), "
        "'total_memory': getattr(props, 'total_memory', None)"
        "}, ensure_ascii=False))"
    )
    proc = subprocess.run(
        [python_exe, "-c", code],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
    after = set(plog_dir.glob("plog-*.log"))
    new_logs = sorted(after - before, key=lambda p: p.stat().st_mtime, reverse=True)
    chosen = new_logs[0] if new_logs else None

    torch_info: dict[str, object] | None = None
    stdout = proc.stdout.strip()
    if stdout:
        for line in reversed(stdout.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    torch_info = json.loads(line)
                    break
                except json.JSONDecodeError:
                    pass

    logical = None
    real = None
    if chosen and chosen.exists():
        text = chosen.read_text(errors="ignore")
        match = PLOG_PATTERN.search(text)
        if match:
            logical = int(match.group(1))
            real = int(match.group(2))

    row = {
        "logical_d": device_id,
        "real_devid": real,
        "torch_device_name": torch_info.get("device_name") if torch_info else None,
        "torch_total_memory": torch_info.get("total_memory") if torch_info else None,
        "source_plog": str(chosen) if chosen else None,
        "returncode": proc.returncode,
    }
    return row


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", default=sys.executable, help="Python executable to use")
    parser.add_argument(
        "--plog-dir",
        default=str(Path.home() / "ascend" / "log" / "run" / "plog"),
        help="Ascend runtime plog directory",
    )
    parser.add_argument(
        "--output",
        default="device_mapping_torch_npu.csv",
        help="Output CSV path",
    )
    args = parser.parse_args()

    plog_dir = Path(args.plog_dir).expanduser().resolve()
    rows = [run_probe(d, args.python, plog_dir) for d in range(8)]

    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "logical_d",
                "real_devid",
                "torch_device_name",
                "torch_total_memory",
                "source_plog",
                "returncode",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(output)
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
