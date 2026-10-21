# Scanner improvements on the published alpha2 baseline

This branch starts at the published `v5.0.0-alpha2` tag,
`4113d5b4a37e83a9fa585f1e992816037331f8c8`. The official release asset
`app-release.apk` has SHA-256
`806ffb58c7407bc3ff66ae9782374969df0b0e5e377f30623de388f8aed8bf15`.
This is the user's working release baseline. A new debug build is not the same
binary as the signed release APK.

The earlier integration based on upstream `cb7caa46` is preserved on
`codex/scan-enhancement-v5` at `742a08ad`. Its subsequent uncommitted dependency
lockfile change is saved on `codex/scan-enhancement-v5-pre-alpha2-backup` at
`ee7e030f`. The complete v4 implementation, native regression suites and original
development changes remain on `codex/scan-enhancement-v4-backup` at `4e2f3cd9`.

## Scope

The scanner retains alpha2's standalone package, camera controller and preview,
camera resolution and controls, stream conversion and orientation, capture flow,
auto-capture timing and tracker, countdown, vibration, spirit level and rectangle
painters. The scanner screen and crop adjustment layout are unchanged. The later
upstream scanner reorganization, settings screen and PDF viewer replacement are
not included. The existing GPL license files and attribution are retained.

Only recognition and enhancement are adapted from the preserved implementation:

- The shared live/still detector combines gradient-adaptive Canny edges and Otsu
  paper proposals, bounded contour ranking, multiple polygon approximations,
  edge-support scoring and convex geometry checks. It retains alpha2's fast and
  accurate presets and returns its absolute image coordinates. Existing smoothing
  and auto capture receive the improved corners; the overlay remains alpha2's.
- Enhance uses optimized color correction and shadow reduction. Enhance initially
  stays off. Reduce shadows defaults on and appears while Enhance is enabled.
  Turning it off uses the conservative contrast adjustment.
- Analysis is bounded to a 768-pixel longest edge with a 4x gain cap and conservative
  fallback. Faint ink, colored text, printed fills and image texture are protected.
  Rendering uses the small analysis map rather than a full-size floating-point map.
- The editor caches analysis for a committed crop, invalidates it on recropping
  and releases it on disposal. Native processing runs in isolates with explicit
  Mat disposal. Processing order remains crop, enhancement, rotation, color filter.
  Each render starts from untouched crop bytes, and Apply saves displayed bytes.
- Shadow choice flows through `ImageEditResult`, `ScanResult`, new scan acceptance
  and re-editing. Callers omitting the new field default to true. Alpha2 stores
  editable parameters within a scanner session and exports finished image files;
  the later branch's JSON/session persistence architecture is not imported.
  Existing exported images are not automatically reprocessed.

Editor busy-input guards, failure handling and a shared horizontal scroll
controller protect preview/save consistency without changing the control layout.
The only new editor control is Reduce shadows. Its English label follows the
standalone alpha2 editor's existing labels.

The app lockfile at the tag omitted four existing scanner dependencies. Their
entries are completed using the same tag's scanner example lockfile:
`sensors_plus` 7.0.0, `sensors_plus_platform_interface` 2.0.1, `vibration` 3.1.8,
`vibration_platform_interface` 0.1.2. Existing camera packages and every other
locked package version remain unchanged. No dependency manifests are changed.

The reference workbench is retained in `tools/scanner_color/`; its original
comparison measurements refer to the preserved v4 native implementation.
Background-estimation rationale: Bako et al., *Removing Shadows from Images of
Documents*, ACCV 2016,
<https://web.ece.ucsb.edu/~psen/Papers/ACCV16_RemovingShadows.pdf>.
No research implementation, trained model or private reference image is bundled.

## Verification

Use the pinned Flutter submodule at
`44a626f4f0027bc38a46dc68aed5964b05a83c18` (Flutter 3.41.0), matching the tag:

```powershell
.\flutter\bin\flutter.bat pub get --enforce-lockfile
.\flutter\bin\flutter.bat gen-l10n
.\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
.\flutter\bin\flutter.bat test --no-pub test/scanner test/src/widget_test.dart
.\scripts\test_scanner_android.ps1 -DeviceId emulator-5556
.\flutter\bin\flutter.bat analyze --no-pub --no-fatal-infos
.\flutter\bin\flutter.bat build apk --debug --no-pub --split-per-abi --target-platform android-arm64,android-x64
```

The reused numerical suites cover perspective pages, receipts, landscape and low
contrast, non-document scenes, live detection feeding auto capture, movement and
detection-loss reset, shadow levels and hard edges, faint writing, colored ink,
printed fills, JPEG paper gaps, conservative fallback, bounded large exports,
rotation, switching, displayed/saved agreement, file-based re-edit restoration and
crop-analysis invalidation. Fixtures are synthetic; personal images stay local.
The historical commented-out cubit test has no entry point and is excluded by
selecting the scanner suite and the existing runnable app test explicitly.

Validated with 17 desktop tests and 12 Android API 36 emulator processing/editor
tests. Targeted analysis of changed scanner files and tests has no findings.
Full-app analysis succeeds with `--no-fatal-infos`, reporting 19 pre-existing
informational lints and no warnings or errors. A source/dependency audit confirms
the protected camera/settings/layout files and all 279 existing locked packages
match the tag. The 7.7MP analysis/render case took approximately 1.5 seconds on
the emulator in debug mode; this is not a physical-device performance guarantee.
Normal `lib/main.dart` Android debug builds succeed for ARM64 and x86_64.

The Android harness runs these processing/editor cases in the app on a selected
device. It does not claim real-camera reliability. Camera, capture and lifecycle
code are intentionally kept byte-for-byte equivalent to the alpha2 tag; physical
camera accuracy, interruption/resume, prolonged scanning, preview fit and memory
behavior still require device verification. An iOS build/runtime check on a Mac
is required before claiming iOS readiness.
