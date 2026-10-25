# Project development instructions

## One development line

- The canonical project folder is `D:\DEV\paperless-mobile`.
- Work on `codex/scan-enhancement-alpha2`. This is the maintained Alpha 2 app,
  including the standalone `packages/paperless_mobile_document_scanner` package.
- Do not create or switch development branches or worktrees unless the user
  explicitly requests it. If this checkout is on another branch, report the
  mismatch before implementing changes. Archived tags are recovery references.
- Keep changes and commits in this folder. Retired scanner folders must not be
  reused. Do not merge the old v5 scanner baseline into this branch.

## Scanner behavior

- Preserve Alpha 2's scanner controls, spirit level, luminance-only Android
  analysis, YUV420 input, four-point detector and tracking, 1080p default and
  perspective-proportion correction unless the user requests a change.
- Camera/detection recovery from `271aa5fa` and maximum-resolution capture are
  deferred in `improvements-plan.md`. Do not import them indirectly.
- Use the pinned Flutter submodule, not a separate installed SDK. Regenerate
  ignored sources/caches after SDK or checkout changes. Avoid broad dependency
  upgrades to resolve stale generated files.
- Implement and validate each independent improvement in a separate commit.
  Reference the original commit when porting. Stage only the intended files.

## Verification and delivery

- Run the relevant existing and new regression tests before committing code.
- Use the canonical build entrypoint once available; record source and SDK
  revisions with APKs. A release build configuration does not imply a published
  or physically validated release.
- Keep credentials, private captures and local diagnostics out of Git.
- Consolidation status, original commits and backups are documented in
  `docs/alpha2-consolidation.md`.
