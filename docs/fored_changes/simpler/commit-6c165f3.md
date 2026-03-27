# `simpler` forked change: `6c165f3`

Commit: `6c165f3dfba2d1345ed50a2db90eb18f75f2e65c`  
Title: `Fix orchestration runtime init and shutdown`

## Why this exists

This commit carries the runtime-side fixes needed for both NPU and sim
execution:

- initialization API must pass orchestration thread configuration through
- device and sim `init_runtime(...)` signatures must match the shared header
- AICPU executor exit/completion logic must not hang the host
- host/device orchestration mode must be initialized consistently

## Files touched

- `examples/scripts/code_runner.py`
- `python/bindings.py`
- `src/a2a3/platform/include/host/pto_runtime_c_api.h`
- `src/a2a3/platform/onboard/host/device_runner.cpp`
- `src/a2a3/platform/onboard/host/host_regs.cpp`
- `src/a2a3/platform/onboard/host/pto_runtime_c_api.cpp`
- `src/a2a3/platform/sim/host/pto_runtime_c_api.cpp`
- `src/a2a3/runtime/aicpu_build_graph/aicpu/aicpu_executor.cpp`
- `src/a2a3/runtime/tensormap_and_ringbuffer/aicpu/aicpu_executor.cpp`
- `src/a2a3/runtime/tensormap_and_ringbuffer/host/runtime_maker.cpp`

## What changed

- Thread `orch_thread_num` through Python bindings and runtime init.
- Make sim/onboard C API signatures consistent with the header.
- Fix executor/orchestrator ABI calls.
- Fix scheduler completion and shutdown behavior so the host does not hang in
  `rtStreamSynchronize`.
- Improve register-address initialization failure handling.

## Why we keep it

This is the core functional fork delta for runtime correctness. It is not a
temporary environment tweak.

## Verification

- `python models/pypto-lib/examples/beginner/hello_world.py --sim`
- `bash test.sh`
- Hardware path verified on fixed `-d 2`

These continue to pass after history rewrite.

