#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def _load_module(module_name: str, path: Path):
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _load_kernel_binaries(cache_dir: Path, meta: dict) -> list[tuple[int, bytes]]:
    func_ids = meta["kernel_func_ids"]
    kernel_files = meta["kernel_files"]
    if len(func_ids) != len(kernel_files):
        raise ValueError(
            "meta.json is inconsistent: kernel_func_ids and kernel_files length mismatch"
        )

    return [
        (func_id, (cache_dir / kernel_file).read_bytes())
        for func_id, kernel_file in zip(func_ids, kernel_files)
    ]


def _prepare_simpler_imports(repo_root: Path) -> None:
    for rel_path in ("frameworks/simpler/python", "frameworks/simpler/examples/scripts"):
        full_path = str((repo_root / rel_path).resolve())
        if full_path not in sys.path:
            sys.path.insert(0, full_path)


def _resolve_pto_isa_root(repo_root: Path) -> Path:
    env_value = os.environ.get("PTO_ISA_ROOT")
    if env_value:
        candidate = Path(env_value).resolve()
        if (candidate / "include").is_dir():
            return candidate

    candidate = (repo_root / "upstream/pto-isa").resolve()
    if (candidate / "include").is_dir():
        return candidate

    raise RuntimeError(
        "PTO_ISA_ROOT is unavailable. Run with initialized submodules or export PTO_ISA_ROOT."
    )


def _cache_is_ready(cache_dir: Path) -> bool:
    required_files = ("host.bin", "aicpu.bin", "aicore.bin", "orch.bin", "meta.json")
    if not cache_dir.is_dir():
        return False
    if any(not (cache_dir / name).is_file() for name in required_files):
        return False

    try:
        meta = json.loads((cache_dir / "meta.json").read_text())
    except Exception:
        return False

    kernel_files = meta.get("kernel_files")
    kernel_func_ids = meta.get("kernel_func_ids")
    work_dir_value = meta.get("work_dir")
    golden_value = meta.get("golden")

    if not isinstance(kernel_files, list) or not kernel_files:
        return False
    if not isinstance(kernel_func_ids, list) or len(kernel_func_ids) != len(kernel_files):
        return False
    if any(not (cache_dir / kernel_file).is_file() for kernel_file in kernel_files):
        return False
    if not isinstance(work_dir_value, str) or not work_dir_value:
        return False
    if not isinstance(golden_value, str) or not golden_value:
        return False

    work_dir = Path(work_dir_value)
    golden_path = Path(golden_value)
    if not work_dir.is_dir() or not golden_path.is_file():
        return False
    if not (work_dir / "kernel_config.py").is_file():
        return False

    return True


def _compile_runtime_cache(repo_root: Path, cache_dir: Path, device_id: int) -> None:
    print(f"[runtime-cache] building {cache_dir}", file=sys.stderr)

    _prepare_simpler_imports(repo_root)

    hello_world_module = _load_module(
        "hello_world_runtime_cache_builder",
        repo_root / "models/pypto-lib/examples/beginner/hello_world.py",
    )

    from elf_parser import extract_text_section
    from pypto.backend import BackendType
    from pypto.ir.pass_manager import OptimizationStrategy
    from pypto.runtime.golden_writer import write_golden
    from pypto.runtime.runner import compile_program
    from runtime_builder import RuntimeBuilder

    program = hello_world_module.build_hello_world_program()
    tensor_specs = hello_world_module.build_tensor_specs()
    work_dir = (repo_root / "build_output/hello_world_npu_bench").resolve()
    pto_isa_root = _resolve_pto_isa_root(repo_root)

    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    compile_program(
        program,
        work_dir,
        strategy=OptimizationStrategy.Default,
        backend_type=BackendType.Ascend910B_PTO,
        dump_passes=True,
    )

    golden_path = work_dir / "golden.py"
    write_golden(tensor_specs, hello_world_module.golden_hello_world, golden_path)
    kernel_config = _load_module("hello_world_runtime_kernel_config", work_dir / "kernel_config.py")

    builder = RuntimeBuilder(platform="a2a3")
    kernel_compiler = builder.get_kernel_compiler()
    runtime_name = getattr(kernel_config, "RUNTIME_CONFIG", {}).get("runtime", "host_build_graph")

    if runtime_name not in builder.list_runtimes():
        raise RuntimeError(
            f"runtime {runtime_name!r} is not available for platform 'a2a3'; "
            f"available runtimes: {builder.list_runtimes()}"
        )

    runtime_include_dirs = [
        str((repo_root / "frameworks/simpler/src/a2a3/runtime" / runtime_name / "runtime").resolve()),
        str((repo_root / "frameworks/simpler/src/common/task_interface").resolve()),
    ]

    cache_parent = cache_dir.parent
    cache_parent.mkdir(parents=True, exist_ok=True)
    staging_root = Path(tempfile.mkdtemp(prefix=".hello_world_runtime_cache.", dir=str(cache_parent)))
    staging_cache_dir = staging_root / cache_dir.name
    staging_cache_dir.mkdir(parents=True, exist_ok=True)

    runtime_build_dir = staging_root / "runtime_build"
    orchestration_build_dir = staging_root / "orchestration_build"
    kernel_build_dir = staging_root / "kernel_build"
    runtime_build_dir.mkdir(parents=True, exist_ok=True)
    orchestration_build_dir.mkdir(parents=True, exist_ok=True)
    kernel_build_dir.mkdir(parents=True, exist_ok=True)

    def _build_runtime():
        return builder.build(runtime_name, str(runtime_build_dir))

    def _compile_orchestration():
        return kernel_compiler.compile_orchestration(
            runtime_name,
            kernel_config.ORCHESTRATION["source"],
            build_dir=str(orchestration_build_dir),
        )

    def _compile_one_kernel(kernel: dict) -> tuple[int, bytes]:
        incore_binary = kernel_compiler.compile_incore(
            kernel["source"],
            core_type=kernel["core_type"],
            pto_isa_root=str(pto_isa_root),
            extra_include_dirs=runtime_include_dirs,
            build_dir=str(kernel_build_dir),
        )
        return kernel["func_id"], extract_text_section(incore_binary)

    with ThreadPoolExecutor(max_workers=2 + len(kernel_config.KERNELS)) as executor:
        fut_runtime = executor.submit(_build_runtime)
        fut_orchestration = executor.submit(_compile_orchestration)
        fut_kernels = [executor.submit(_compile_one_kernel, kernel) for kernel in kernel_config.KERNELS]

        host_binary, aicpu_binary, aicore_binary = fut_runtime.result()
        orch_binary = fut_orchestration.result()
        kernel_binaries = [future.result() for future in fut_kernels]

    (staging_cache_dir / "host.bin").write_bytes(host_binary)
    (staging_cache_dir / "aicpu.bin").write_bytes(aicpu_binary)
    (staging_cache_dir / "aicore.bin").write_bytes(aicore_binary)
    (staging_cache_dir / "orch.bin").write_bytes(orch_binary)

    kernel_files = []
    kernel_func_ids = []
    for kernel_index, (func_id, kernel_binary) in enumerate(kernel_binaries):
        kernel_file = f"kernel_{kernel_index}.bin"
        (staging_cache_dir / kernel_file).write_bytes(kernel_binary)
        kernel_files.append(kernel_file)
        kernel_func_ids.append(func_id)

    meta = {
        "device_id": device_id,
        "kernel_func_ids": kernel_func_ids,
        "kernel_files": kernel_files,
        "work_dir": str(work_dir),
        "golden": str(golden_path),
    }
    (staging_cache_dir / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

    if cache_dir.exists():
        shutil.rmtree(cache_dir)
    staging_cache_dir.replace(cache_dir)
    shutil.rmtree(staging_root, ignore_errors=True)


def _ensure_runtime_cache(repo_root: Path, cache_dir: Path, device_id: int, rebuild: bool) -> None:
    if rebuild or not _cache_is_ready(cache_dir):
        _compile_runtime_cache(repo_root, cache_dir, device_id)


def _find_profile_json(outputs_dir: Path, existing_files: set[Path]) -> Path | None:
    candidates = list(outputs_dir.glob("perf_swimlane_*.json"))
    if not candidates:
        return None

    new_files = [path for path in candidates if path not in existing_files]
    target_files = new_files if new_files else candidates
    return max(target_files, key=lambda path: path.stat().st_mtime)


def _summarize_profile_json(profile_json: Path) -> dict:
    data = json.loads(profile_json.read_text())
    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ValueError(f"{profile_json} does not contain any tasks")

    def _avg(values: list[float]) -> float:
        return sum(values) / len(values)

    valid_tasks = []
    invalid_tasks = []
    duration_only_tasks = []
    for task in tasks:
        dispatch = float(task["dispatch_time_us"])
        start = float(task["start_time_us"])
        end = float(task["end_time_us"])
        finish = float(task["finish_time_us"])
        duration = float(task["duration_us"])

        if duration >= 0.0:
            duration_only_tasks.append(task)

        is_valid = (
            dispatch > 0.0
            and start > 0.0
            and end > 0.0
            and finish > 0.0
            and duration >= 0.0
            and dispatch <= start <= end <= finish
            and abs((end - start) - duration) <= 5.0
        )

        if is_valid:
            valid_tasks.append(task)
        else:
            invalid_tasks.append(
                {
                    "task_id": task.get("task_id"),
                    "core_id": task.get("core_id"),
                    "dispatch_time_us": dispatch,
                    "start_time_us": start,
                    "end_time_us": end,
                    "finish_time_us": finish,
                    "duration_us": duration,
                }
            )

    if not valid_tasks:
        raise ValueError(f"{profile_json} contains no valid tasks after timestamp sanity checks")

    dispatch_times = [float(task["dispatch_time_us"]) for task in valid_tasks]
    start_times = [float(task["start_time_us"]) for task in valid_tasks]
    end_times = [float(task["end_time_us"]) for task in valid_tasks]
    finish_times = [float(task["finish_time_us"]) for task in valid_tasks]
    durations = [float(task["duration_us"]) for task in valid_tasks]

    latency = [finish - dispatch for dispatch, finish in zip(dispatch_times, finish_times)]
    head_overhead = [start - dispatch for dispatch, start in zip(dispatch_times, start_times)]
    tail_overhead = [finish - end for finish, end in zip(finish_times, end_times)]

    return {
        "profiling_json": str(profile_json),
        "profiling_version": data.get("version"),
        "profiling_task_count": len(tasks),
        "profiling_valid_task_count": len(valid_tasks),
        "profiling_invalid_task_count": len(invalid_tasks),
        "profiling_metric_basis": "device_* fields use valid tasks only",
        "profiling_invalid_tasks": invalid_tasks,
        "device_metric_task_count": len(valid_tasks),
        "device_exec_avg_us": _avg(durations),
        "device_exec_total_us": sum(durations),
        "device_exec_avg_us_all_duration_tasks": _avg(
            [float(task["duration_us"]) for task in duration_only_tasks]
        ),
        "device_exec_total_us_all_duration_tasks": sum(
            float(task["duration_us"]) for task in duration_only_tasks
        ),
        "device_latency_avg_us": _avg(latency),
        "device_head_overhead_avg_us": _avg(head_overhead),
        "device_tail_overhead_avg_us": _avg(tail_overhead),
        "device_total_time_us": max(finish_times) - min(dispatch_times),
    }


def _compact_result(result: dict) -> dict:
    compact = {
        "device_id": result["device_id"],
        "wall_time_avg_s": result["wall_time_avg_s"],
    }

    if result.get("enable_profiling"):
        if "profiling_json" in result:
            compact["profiling_json"] = result["profiling_json"]
        if "profiling_invalid_task_count" in result:
            compact["profiling_invalid_task_count"] = result["profiling_invalid_task_count"]
        if "device_total_time_us" in result:
            compact["device_total_time_us"] = result["device_total_time_us"]
        if "device_exec_avg_us" in result:
            compact["device_exec_avg_us"] = result["device_exec_avg_us"]
        if "profiling_error" in result:
            compact["profiling_error"] = result["profiling_error"]

    return compact


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cache-dir",
        default="build_output/hello_world_npu_runtime_cache",
        help="Precompiled runtime cache directory",
    )
    parser.add_argument(
        "--device",
        type=int,
        default=None,
        help="NPU device id; falls back to ASCEND_DEVICE_ID/NPU_DEVICE_ID or 0",
    )
    parser.add_argument(
        "--enable-profiling",
        action="store_true",
        help="Enable Simpler runtime profiling",
    )
    parser.add_argument(
        "--skip-golden",
        action="store_true",
        help="Skip golden comparison",
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=1,
        help="Number of runtime-only repeats",
    )
    parser.add_argument(
        "--verbose-json",
        action="store_true",
        help="Print full diagnostic JSON instead of the compact default output",
    )
    parser.add_argument(
        "--rebuild-cache",
        action="store_true",
        help="Force rebuilding the hello_world runtime cache before running",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    cache_dir = (repo_root / args.cache_dir).resolve()
    outputs_dir = (repo_root / "outputs").resolve()

    device_id = args.device
    if device_id is None:
        env_value = os.environ.get("ASCEND_DEVICE_ID") or os.environ.get("NPU_DEVICE_ID")
        device_id = int(env_value) if env_value else 0

    _ensure_runtime_cache(repo_root, cache_dir, device_id, args.rebuild_cache)

    meta = json.loads((cache_dir / "meta.json").read_text())
    work_dir = Path(meta["work_dir"]).resolve()
    golden_path = Path(meta["golden"]).resolve()

    _prepare_simpler_imports(repo_root)

    from bindings import bind_host_binary, launch_runtime, set_device
    from code_runner import CodeRunner

    runner = CodeRunner(
        kernels_dir=str(work_dir),
        golden_path=str(golden_path),
        device_id=device_id,
        platform="a2a3",
        enable_profiling=args.enable_profiling,
        skip_golden=args.skip_golden,
    )

    host_binary = (cache_dir / "host.bin").read_bytes()
    aicpu_binary = (cache_dir / "aicpu.bin").read_bytes()
    aicore_binary = (cache_dir / "aicore.bin").read_bytes()
    orch_so_binary = (cache_dir / "orch.bin").read_bytes()
    kernel_binaries = _load_kernel_binaries(cache_dir, meta)

    Runtime = bind_host_binary(host_binary)
    set_device(device_id)

    params = runner.params_list[0]
    generated = runner._golden_module.generate_inputs(params)
    if isinstance(generated, list):
        orch_args, arg_types, arg_sizes, args_map, inputs, outputs = runner._build_func_args_from_list(generated)
    else:
        tensors = generated
        orch_args, arg_types, arg_sizes = runner._build_func_args(tensors)
        inputs, outputs = runner._identify_outputs(tensors)
        args_map = tensors

    if not args.skip_golden:
        golden = {k: v.clone() for k, v in outputs.items()}
        golden_with_inputs = {**inputs, **golden}
        runner._golden_module.compute_golden(golden_with_inputs, params)
    else:
        golden = None

    initial_outputs = {k: v.clone() for k, v in outputs.items()}
    existing_profile_files = set(outputs_dir.glob("perf_swimlane_*.json"))

    wall_times = []
    for round_idx in range(args.repeats):
        for name, value in initial_outputs.items():
            outputs[name].copy_(value)

        runtime = Runtime()
        if args.enable_profiling and round_idx == 0:
            runtime.enable_profiling(True)

        t0 = time.time()
        runtime.initialize(
            orch_so_binary,
            runner.orchestration["function_name"],
            orch_args,
            arg_types=arg_types,
            arg_sizes=arg_sizes,
            kernel_binaries=kernel_binaries,
        )
        launch_runtime(
            runtime,
            aicpu_thread_num=runner.aicpu_thread_num,
            block_dim=runner.block_dim,
            device_id=device_id,
            aicpu_binary=aicpu_binary,
            aicore_binary=aicore_binary,
            orch_thread_num=runner.orch_thread_num,
        )
        runtime.finalize()
        t1 = time.time()
        wall_times.append(t1 - t0)

        if golden is not None:
            runner._compare_with_golden(outputs, golden)

    result = {
        "device_id": device_id,
        "repeats": args.repeats,
        "enable_profiling": args.enable_profiling,
        "wall_time_s": wall_times,
        "wall_time_avg_s": sum(wall_times) / len(wall_times),
        "cache_dir": str(cache_dir),
        "work_dir": str(work_dir),
        "golden": str(golden_path),
    }

    if args.enable_profiling:
        profile_json = _find_profile_json(outputs_dir, existing_profile_files)
        if profile_json is None:
            result["profiling_error"] = f"no perf_swimlane_*.json found under {outputs_dir}"
        else:
            try:
                result.update(_summarize_profile_json(profile_json))
            except Exception as exc:  # pragma: no cover - best effort reporting
                result["profiling_json"] = str(profile_json)
                result["profiling_error"] = str(exc)

    output = result if args.verbose_json else _compact_result(result)
    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
