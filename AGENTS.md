# Repository Rules

## Forked Changes Docs

- Any maintained fork-only change in a submodule fork must be documented under
  `docs/fored_changes/`.
- Use one file per rewritten fork commit:
  `docs/fored_changes/<repo>/commit-<short_sha>.md`
- Each file should record:
  - the commit id
  - why the change exists
  - which files are touched
  - why the change must be kept
  - how it was verified
- When a forked change is removed, rewritten, or replaced, update the matching
  file in `docs/fored_changes/` in the same change.

