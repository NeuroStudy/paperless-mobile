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

## Scan capture quality

The scanner and both camera-view defaults now request
`ResolutionPreset.ultraHigh` (approximately 3840x2160). The previous scanner
default was `high` (approximately 1280x720), limiting the detail available for
fine text before cropping or editing. The resolution selector is debug-only,
so the higher default also applies in release builds.

Explicit resolution overrides remain supported. The camera plugin negotiates a
supported resolution when 4K is unavailable; the target does not guarantee exact
dimensions on every device. Higher-resolution captures can take longer to
process and produce larger files. Detection/enhancement analysis remains bounded,
while edits and saved PNGs retain the cropped image resolution. Thumbnails are
generated separately and are not used as saved image data. Existing scans are
not reprocessed and cannot recover detail lost during their original capture.

The baseline and historical verification notes below describe the earlier
recognition/enhancement adaptation; this capture-default change supersedes their
statements that camera resolution remains identical to alpha2.

## Scope

The scanner retains alpha2's standalone package, camera controller and preview,
camera resolution and controls, orientation, capture flow,
auto-capture timing and tracker, countdown, vibration, spirit level and rectangle
painters. The scanner screen and crop adjustment layout are unchanged. The later
upstream scanner reorganization, settings screen and PDF viewer replacement are
not included. The existing GPL license files and attribution are retained.

Only recognition and enhancement are adapted from the preserved implementation:

- The shared live/still detector follows the preserved native four-point
  algorithm: up to 960px analysis, Gaussian 5 smoothing, gradient-adaptive Canny
  and Otsu proposals, a 3x3 close without added dilation/padding, a 6%-97% contour
  area range, bounded contour ranking, the original polygon approximations,
  edge-support scoring and convex geometry checks. It returns alpha2's absolute
  image coordinates. Explicit legacy fast/accurate presets remain available;
  the default is `EdgeDetectionConfig.fourPoint`.
- Live ranking retains the native previous-corner agreement weight and its
  ranking reference smoothing. It resets on loss or changed frame geometry and
  does not lock onto a document after movement. This is separate from alpha2's
  unchanged overlay smoothing, capture tracker, timing and rectangle painter.
  The older native behavior that hid corners after stability is excluded.
- Android analysis copies the Y plane directly with row/pixel strides, as in the
  earlier scanner. It avoids full-frame YUV-to-RGBA-to-gray conversion and ignores
  chroma/padding. The persistent worker accepts both luminance and RGBA input.
  Camera controls, captured color photographs and their saved enhancement remain
  unchanged. The scanner-view adapter forwards the analysis channel count.
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

The alpha2 camera teardown also needs lifecycle fixes. It previously stopped an
already stopped stream after capture, and its controller listener could rebuild
an element while unmounting. Regression tests reproduce both the `defunct`
assertion and `No camera is streaming images` exception on the original code.
The preview now detaches its listener before shutdown, stops only an active
stream, waits for pending initialization/flash setup before disposing, and waits
for release before reopening on resume. Late initialization and old stream
results are ignored. Disposing the detector cancels pending startup/reply waits
and closes their ports; closing a file-based editor ignores late file/crop work.
These changes preserve camera resolution, image formats, flash defaults, focus
and exposure behavior, controls, layout, detection and capture timing.

The app lockfile at the tag omitted four existing scanner dependencies. Their
entries are completed using the same tag's scanner example lockfile:
`sensors_plus` 7.0.0, `sensors_plus_platform_interface` 2.0.1, `vibration` 3.1.8,
`vibration_platform_interface` 0.1.2. Existing camera packages and every other
locked package version remain unchanged. The scanner's test dependencies also
declare the already locked `camera_platform_interface` for a controllable native
host in lifecycle regression tests; runtime dependencies are unchanged.

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

The initial alpha2 adaptation passed 17 desktop and 12 Android processing/editor
tests. The follow-up recognition correction adds independent native-algorithm
reference cases for steeper skews, rotation, faint edges, clutter and non-documents,
plus previous-candidate continuity, movement/loss, luminance strides and an actual
Android camera-frame check. Reference generation is documented in
`tools/scanner_detection/`. Targeted analysis of changed files has no findings.
The recognition correction passed 31 desktop tests and 27 Android API 36
processing, editor, recognition and camera-input checks. All ten single-image
comparisons agree with the independent translation of the earlier native
algorithm; eight of those checks failed before the correction. The live
luminance case averaged approximately 20ms/frame on the emulator at a 960-pixel
analysis limit. These are synthetic/debug observations, not phone guarantees.
Full-app analysis succeeds with `--no-fatal-infos`, reporting 19 pre-existing
informational lints and no warnings or errors. A source/dependency audit confirms
the camera constructor settings, controls/layout/painters, capture settings and the committed
lockfile's 279 original entries match the tag. The 7.7MP analysis/render case took approximately 1.5 seconds on
the emulator in debug mode; this is not a physical-device performance guarantee.
Normal `lib/main.dart` Android debug builds succeed for ARM64 and x86_64.

The Android harness runs these processing/editor cases in the app on a selected
device and an actual camera input frame. It does not claim real-camera accuracy.
It uses the standard integration driver with a direct VM connection because the
pinned SDK's DDS startup is intermittent on this Windows host, and `flutter test
--no-dds` reports a host-side unsupported golden stream despite running the app
tests successfully. `-DiagnosticOutput` enables verbose runner logs. The harness
grants camera permission only to the debug test app on the selected device.
With the lifecycle fixes, the suite passes 42 desktop tests and 32 Android API 36
checks, including the production capture/editor round trip and worker cancellation.
Camera capture settings, controls and layout remain alpha2's. Lifecycle regression
tests cover closing with no stream, after stopping for capture, while streaming,
during initialization and flash setup, and background/resume with native shutdown
still pending. Android also exercises the real capture → edit → discard → live
camera → close flow. Physical camera accuracy, real OS interruptions, prolonged
scanning, preview fit and memory behavior still require device verification.
An iOS build/runtime check on a Mac is required before claiming iOS readiness.

## Scan proportions

Perspective cropping previously used the longest photographed horizontal and
vertical edges independently for output dimensions. Camera tilt foreshortens
those directions differently, so straightened pages could still look stretched.
Independent pinhole-camera projections of A4 reproduce 17%-25% excess width.

The shared perspective transform now estimates the physical rectangle ratio
from a unit-square homography, assuming square pixels and an optical center at
the image center. The method follows Zhang and He, *Whiteboard scanning and image
enhancement*, sections 3.2-3.3:
<https://www.microsoft.com/en-us/research/uploads/prod/2016/11/Digital-Signal-Processing.pdf>.
It accepts focal lengths between 0.5 and 5 times the image's longest dimension
and requires less than or equal to 2% ratio variation when each corner coordinate
is perturbed by plus/minus `max(1, longestDimension / 960)` pixels. Singular,
nonphysical or unstable estimates retain the previous dimensions. Accepted
estimates retain the previous longest output dimension and derive the other
dimension from the recovered ratio. No page format is forced to A4.

Capture, manual recropping and file-based re-editing use this same calculation.
Existing exported files are unchanged. Camera calibration and lens-distortion
correction are not introduced, so automatic recovery remains approximate and
some camera angles deliberately use the previous sizing.

`test/scanner/perspective_test.dart` and the Android integration harness share
independently projected A4, landscape, receipt, square and rotated-image cases.
They check a 1% page-ratio tolerance, square content, resolution independence,
conservative fallback and editor/recrop/re-edit displayed-versus-saved agreement.
The combined suites pass 64 desktop checks (including the app widget test) and
49 Android API 36 emulator checks. Full-app analysis with `--no-fatal-infos`
reports the same 19 existing informational lints, with no warnings or errors.
A physical A4 comparison from frontal and tilted phone captures is still needed.
