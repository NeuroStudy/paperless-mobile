# Alpha 2 consolidation

## Development baseline

The only maintained development branch is `codex/scan-enhancement-alpha2`, in
`D:\DEV\paperless-mobile`. Consolidation started from `b1cf03e2`, which includes
the October 21-22 scanner improvements and the two deferred-improvement notes.
The Flutter submodule remains pinned at `44a626f4f0027bc38a46dc68aed5964b05a83c18`.

Keep the standalone scanner and its compact controls, spirit level, 1080p
capture, luminance-only analysis, four-point tracking and proportion correction.
Do not merge the later upstream scanner UI/settings/storage reorganization.

## Recovery copies

Private backup directory:
`D:\DEV\paperless-mobile-archives\2026-10-25-alpha2-consolidation`.

`repository.bundle` contains the original branch histories. Source tar snapshots
include local edits/configuration, generated sources, APKs and available capture
diagnostics. `manifest.json` records file/artifact checksums and original
revisions; `RESTORE.md` describes recovery into a separate directory. Bundle
verification and tar member checksums passed before the checkout was changed.
The Flutter revision and its uncommitted patch were saved separately. This
directory contains private material and must not be published.

Archive tags preserve the committed histories:

- `archive/2026-10-25/scan-enhancement-v5`: `5c477514`
- `archive/2026-10-25/scan-enhancement-v4`: `4e2f3cd9`
- `archive/2026-10-25/scan-enhancement-v5-pre-alpha2`: `ee7e030f`
- `archive/2026-10-25/alpha2-before-consolidation`: `b1cf03e2`

## Port ledger

Each implemented row receives an independent commit with a `Ported-from` trailer.
Final target revisions and validation are recorded here after implementation.

| Source | Change | Status |
| --- | --- | --- |
| `3df8ee1b` | Saved-view query commas | Pending |
| `e16ff893` | Color protection/background cleanup | Pending; adapt package imports |
| `fc5bee5b` | Native document chat | Pending; retain Alpha 2 scanner/PDF integration |
| `5c295079` | Exact rectangular crops | Pending; retain perspective ratio recovery |
| `312c79ba` | Android build hardening | Pending |
| `271aa5fa` | Detection/camera recovery | Deferred; do not port |
| `5c477514` | Folded-corner repair | Pending; still-image adaptation only |
| Original uncommitted changes | Release signing opt-in and validation | Pending; separate commit |
| Compatibility addition | Copy-based recovery of newer saved scan pages | Pending; preserve originals and account ownership |
| Build provenance | Canonical build guard, revision display and APK manifest | Pending |

The old Flutter checkout modification, incidental dependency lock drift and
obsolete edge-detection package caches are archived rather than ported.
Maximum-resolution capture remains deferred. See `../improvements-plan.md` for
both deferred investigations and their acceptance criteria.

## Completion gates

Run the pinned-SDK baseline, per-port regressions, analysis, Android integration
checks and debug/release builds. Record actual results without equating emulator
checks with physical-phone validation. Before retiring branches, refresh and
verify the backup, publish archive tags and the maintained branch, set the GitHub
default, and remove only the three explicitly retired scanner branches and the
secondary checkout. Do not publish an app release as part of consolidation.

## Saved scan compatibility

Alpha 2 accepts both version-2 and version-3 persisted state, retaining the loaded
version, account selection, settings and raw `document_scans` metadata. Recovery
reads only the logged-in account's referenced edited pages under the app-owned
`document_scans` directory; stored absolute directory paths are not trusted.
Finished files are copied byte-for-byte into durable account-specific
`recovered_scans` directories. Originals and metadata remain intact.

Stable page identities and a persisted import ledger prevent duplicate imports
and keep intentionally deleted recovery copies from reappearing. Interrupted
copies use `.part` files and retry safely. Missing/corrupt pages are logged and
remain eligible for retry; uncropped originals are never substituted. The Alpha 2
flat scan interface is retained, including its existing legacy temporary files;
the newer grouping and persistent re-edit UI are not imported.
