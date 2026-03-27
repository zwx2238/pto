# `simpler` forked change: `8b0f6ba`

Commit: `8b0f6ba535a2943c87ba7b3f9064ca85f0289149`  
Title: `Stabilize Ascend toolchain and sim build integration`

## Why this exists

The upstream code path is not sufficient for the current local environment:

- onboard builds need robust Ascend toolchain discovery
- sim builds must work even when `g++-15` is absent
- sim kernel compilation must preserve the requested core type

Without this change, one or more of the following happen:

- sim build fails at toolchain selection
- sim kernel compile uses the wrong macro set for `aic` vs `aiv`
- local Ascend toolchain resolution becomes brittle

## Files touched

- `python/kernel_compiler.py`
- `python/runtime_compiler.py`
- `python/toolchain.py`
- `src/a2a3/platform/onboard/aicpu/CMakeLists.txt`
- `src/a2a3/platform/onboard/host/CMakeLists.txt`
- `src/a5/platform/onboard/aicpu/CMakeLists.txt`
- `src/a5/platform/onboard/host/CMakeLists.txt`

## What changed

- Preserve `core_type` when compiling simulated kernels.
- Let sim use `g++-15` when available, but fall back to `g++`/configured `CXX`
  instead of hard-failing.
- Probe whether `-std=c++23` is supported and fall back to `-std=gnu++2a` when
  needed.
- Keep Ascend onboard CMake integration usable with the local toolchain layout.

## Why we keep it

This change set was tested by reverting pieces and re-running sim/NPU paths.
The toolchain and sim parts are required. Purely diagnostic-only changes were
separated out and removed earlier.

## Verification

- `python models/pypto-lib/examples/beginner/hello_world.py --sim`
- `bash test.sh`

Both pass after this consolidated commit.

