# `pypto` forked change: `0fc4e9d`

Commit: `0fc4e9dafc42079a9f47ae6369c605daaecd24a6`  
Title: `Align orchestration codegen with TaskArg runtime API`

## Why this exists

`pypto` code generation must match the current `simpler` orchestration entry
ABI. Without this change, generated orchestration code uses the wrong runtime
argument type/layout and cannot interoperate cleanly with the runtime we keep in
the fork.

## Files touched

- `src/codegen/orchestration/orchestration_codegen.cpp`

## What changed

- Align generated orchestration entry code with the `TaskArg`-based runtime API.
- Keep the generated external tensor materialization in sync with the runtime
  side expected by `simpler`.

## Why we keep it

This is not a bring-up tweak. It is an ABI/codegen compatibility fix between
the generated orchestration code and the runtime currently used by the monorepo.

## Verification

- `python models/pypto-lib/examples/beginner/hello_world.py --sim`
- `bash test.sh`

Both pass with the rewritten fork history in place.

