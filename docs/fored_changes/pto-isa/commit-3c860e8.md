# `pto-isa` forked change: `3c860e8`

Commit: `3c860e84c4591d4227ed08832d2a8d51e8458244`  
Title: `Improve cpu sim compatibility for pypto examples`

## Why this exists

The CPU sim stubs in upstream `pto-isa` are missing pieces required by the
generated PyPTO examples in this monorepo. Reverting this patch causes sim
kernel compilation to fail.

## Files touched

- `include/pto/common/cpu_stub.hpp`
- `include/pto/cpu/TMatmul.hpp`

## What changed

- Extend the CPU stub layer with missing vector-mask helpers used by generated
  sim kernels.
- Relax the `TMatmul` CPU-side check enough for the generated example path.

## Why we keep it

This is required for `--sim` to compile and run. When this patch was reverted,
sim compilation failed with missing `set_mask_norm` / `set_vector_mask`
symbols.

## Verification

- `python models/pypto-lib/examples/beginner/hello_world.py --sim`
- `bash test.sh`

Sim and NPU paths both pass with this patch restored.

