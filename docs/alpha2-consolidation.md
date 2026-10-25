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
| `3df8ee1b` | Saved-view query commas | `b409f473`; 75 query checks passed |
| `e16ff893` | Color protection/background cleanup | `28d70b0b`; six refinement checks and Python synthetic gates passed |
| `fc5bee5b` | Native document chat | `cf4812a9`; 43 API/cubit/navigation/view checks passed |
| `5c295079` | Exact rectangular crops | `2033ed79`; 31 crop/proportion/capture checks passed |
| `312c79ba` | Android build hardening | `5039f5bd`; Gradle configuration passed on JDK 21 |
| `271aa5fa` | Detection/camera recovery | Deferred; do not port |
| `5c477514` | Folded-corner repair | `d8e7329d`; 45 processing/reference/geometry checks passed |
| Original uncommitted changes | Release signing opt-in and validation | `544ceb26`; opt-in accepted and missing distribution keys rejected |
| Compatibility addition | Copy-based recovery of newer saved scan pages | `f604a8fe`; 12 state/recovery checks plus two navigation checks passed |
| Build provenance | Canonical build guard, revision display and APK manifest | `acb1d8d5`; dirty sources rejected and clean canonical sources accepted |

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

## Combined verification on 2026-10-26

- Pinned Flutter 3.41.0 / Dart 3.11.0: all 229 selected Windows tests passed
  across scanner, API, chat and the runnable app widget entrypoint.
- Android API 36 x86_64 emulator: all 96 integration checks passed, including
  processing/editor, folded pages, native recognition references, real camera
  input/capture, lifecycle and saved-scan compatibility cases.
- Whole-project analysis has no errors or warnings and 19 existing informational
  lints. Generated `build/` snapshots are excluded; maintained source remains analyzed.
- The Python synthetic refinement workbench passed its quantitative preservation
  and cleanup gates. The private image inputs from older investigations were not
  required or uploaded. Metrics are retained under `build/scanner-color-refinement`
  and verification logs in the private consolidation backup.

The Android runner exited successfully. Flutter's post-test cleanup attempted to
uninstall the unsuffixed app ID and logged `DELETE_FAILED_INTERNAL_ERROR`; the
test APK uses `.debug`. Decoder errors in the recovery suite are expected from
its deliberately corrupt image fixture. Neither log is a failed test. Normal
main-entrypoint verification APKs are built separately with source provenance.

Two development-only lock entries were aligned with the pinned SDK (`15a2d22b`):
matcher 0.12.18 and test_api 0.7.8. `7e6bd9d1` declares the already locked OpenCV
package as a direct test dependency and scopes analysis away from generated
build snapshots. No runtime dependency version was upgraded.

Source inspection corrected an assumption in older notes: Alpha 2's standalone
editor defaults `initialEnhanced` to true and the new-capture caller retains that
default. Consolidation preserves this actual Alpha 2 behavior; it does not import
the v5 editor's different default. Camera capture remains 1080p.

Emulator/synthetic checks do not establish real-phone capture accuracy, memory
behavior or performance. Test the resulting APK on the phone before making
physical-device claims. iOS runtime/build validation remains outstanding.

## Verified APKs and build follow-up

Both normal `lib/main.dart` verification APKs were built from
`f5034e29677e947b7a065e6f4213e2063b16fba1`, using the pinned SDK:

- ARM64 release: `paperless-alpha2-release-android-arm64-5.0.0-alpha2+730-f5034e2967.apk`
- x86_64 debug: `paperless-alpha2-debug-android-x64-5.0.0-alpha2+730-f5034e2967.apk`

They are in `build/verified-apks/` with JSON source/SDK/checksum manifests, and
are copied into the private backup's `verified-apks/` directory. Both signatures
verified with Android build-tools, their signing certificates match, their
checksums match their manifests, and their required OpenCV native libraries are
present. The release DEX does not contain IntegrationTestPlugin. The normal debug
APK was installed and cold-launched successfully on the emulator after the
integration run. These APKs use the local debug key, including the optimized
release-mode artifact. They were not published as an app release.

A first release attempt exposed pinned-SDK build tooling issues. `f5034e29` lets
Flutter regenerate mode-specific plugins instead of retaining integration_test
registration through `--no-pub`, and disables Kotlin incremental compilation via
the supported Gradle property. All 13 Kotlin release compile tasks were checked
as non-incremental. The subsequent ARM64 release and x86_64 debug builds passed.
A non-fatal CupertinoIcons font warning was logged in release; font assets and
runtime dependency versions were not changed by this consolidation.

The build guard accepts the clean canonical source and rejects uncommitted
changes. Known generated Kotlin session files are excluded from SDK source
checks. A local ignored editor setting points to the repository's `flutter` SDK.
Later completion commits update audit documentation only; the artifact source
revision is deliberately recorded exactly rather than relabeling the APKs.

## Branch and checkout retirement, 2026-10-26

The maintained branch and four archive tags were pushed to the fork, and its
GitHub default and local `origin/HEAD` now point to
`codex/scan-enhancement-alpha2`. These branches were deleted locally and remotely
after verifying that their remote histories are contained in the archive tags:

- `codex/scan-enhancement-v5`
- `codex/scan-enhancement-v4-backup`
- `codex/scan-enhancement-v5-pre-alpha2-backup`

Remote deletion used expected-revision leases to avoid deleting concurrent work.
The only registered working checkout is `D:\DEV\paperless-mobile`. Historical
upstream branch references remain for comparison, not development.

Git removed the secondary checkout registration but could not delete all files
because of Windows long paths. Automatic policy rejected recursive removal, so
the remaining directory was moved atomically into this private archive instead:
`C:\Users\Anwender\.codex-backups\paperless-mobile\2026-10-26\retired-checkout`.
It is not an active working Git checkout; its parent README explains recovery.
The original `C:\Users\Anwender\.codex\worktrees\scanner-v5\paperless-mobile`
path is gone. No source/private data was discarded to complete cleanup.

`consolidated-code.bundle` was restored into a bare verification repository and
passed full object integrity checks. Required Alpha 2, v4, v5 and pre-alpha2
histories were checked. `final-consolidated.bundle` and `final-manifest.json`
record the published completion state, local configuration and verified APKs.
Use the backup directory's RESTORE.md; do not resume development in an archive.

Camera/detection supervision from `271aa5fa` and maximum-resolution capture remain
deferred in `improvements-plan.md`. No later scanner settings screen, maximum
camera default, PDF viewer replacement or v5 scan-grouping UI was imported.
