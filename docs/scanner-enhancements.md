# Scanner processing enhancements

This contribution starts from upstream `feat/custom-document-scanner` at
`cb7caa467afaf00c66eeccbbdb9d383f6fe23274`. The v4 implementation and native
test suites are preserved on the fork's `codex/scan-enhancement-v4-backup` branch
at `4e2f3cd9e5abbb4797a63a2a2fbdfdec3f574de3`.

## Behavior

Recognition combines gradient-adaptive edges and Otsu paper separation. A bounded
contour search ranks convex quadrilaterals using edge support, contour agreement
and area. Camera frames and still images use the same detector and retain v5's
configuration, coordinate system, smoothing and auto-capture tracker. The previous
native tracker's hidden-after-stability overlay is intentionally not carried over.

Enhance uses the refined color workbench algorithm rather than the previous
unsharp mask. Reduce shadows defaults on, but Enhance itself still defaults off.
The shadow switch is available while Enhance is enabled; turning shadow reduction
off retains modest contrast correction. Both choices survive saving and re-editing.
Older metadata defaults `reduceShadows` to true without changing existing image
files or enabling Enhance.

Analysis uses at most a 768-pixel longest edge. Actual RGB/BGR paper samples stay
together, with protection for printed fills, photographic texture and faint ink.
Illumination gain is capped at 4x and insufficient paper evidence selects the
conservative fallback. Deep underexposure and printed gray fills can be ambiguous;
the controls remain reversible. Analysis and rendering run off the UI isolate.
The editor caches a pure-data profile for the committed crop, invalidates it when
the crop changes, and shares it across enhancement toggles and rotation. Native
Mats are released in the processing isolate. Full-size correction uses the small
map directly, without allocating a full-size floating-point image.

The pipeline retains v5's order: untouched perspective crop, enhancement, rotation,
then the existing color filter. The saved image uses the displayed result.

Busy controls also reject inputs arriving before their disabled state rebuilds,
so edit metadata cannot get ahead of the rendered image. A failed render prevents
Apply until a subsequent edit renders successfully. The editor scrollbar owns
its horizontal controller, and camera listeners are removed before stream
shutdown to avoid updates during widget disposal. These are integration fixes;
the camera and editor workflows retain their existing controls.

Background-estimation rationale: Bako et al., *Removing Shadows from Images of
Documents*, ACCV 2016,
<https://web.ece.ucsb.edu/~psen/Papers/ACCV16_RemovingShadows.pdf>.
No research implementation, trained model or personal reference image is bundled.
Existing upstream license and attribution notices are retained.

## Conservative color and background refinement

The thin Sparkasse strip exposed a gap in the broad color mask: morphological
closing can erase a narrow colored feature before the mask examines it. Those
pixels then become paper samples, causing uneven channel gains and yellow/orange
breaks in the enhanced strip. The refinement supplements broad detection with
reference-normalized color detection on the original analysis pixels, using the
same relative channel-spread threshold of `.35`. The existing content protection
and paper-sample exclusion consume the combined mask. Contrast selection, the
4x illumination limit and fallback criteria retain their existing behavior.

Background cleanup operates between paper normalization and final contrast. Its
classification uses the bounded analysis image and adds an optional byte map to
the crop-specific `EnhancementProfile`. The map is transient processing data;
existing calls, saved metadata, crop invalidation, toggle behavior and the
enhancement/rotation/filter order are unchanged. A missing map preserves the
previous rendering behavior, allowing direct cleanup-versus-no-cleanup checks
with an identical paper estimate and contrast.

The Python workbench retains the historical experiments separately from an
explicit reference for the shared Dart implementation. The reference decodes
with OpenCV in BGR order, uses AREA analysis resizing and source-size kernel
scaling, and reproduces pixel-centered double-precision map interpolation and
Dart rounding. It does not silently apply an extra perspective transform before
analysis. Personal screenshots and generated comparisons remain in ignored
local output; synthetic fixtures are generated from source.

Before the port, lossless exports of the unchanged Dart implementation matched
the explicit Python baseline exactly (all channels, maximum error and mean
absolute error both zero) for the rectified Sparkasse source and synthetic pages
at 1x and 2x. This check distinguishes a processing change from decoder,
interpolation or rounding differences in the workbench.

The frozen v1 cleanup constants are:

| Stage | Constant or criterion (analysis pixels unless stated) |
| --- | --- |
| Candidate background | Normalized darkness `d = 255 - min(B,G,R)` in 8–60; channel spread at most 18 |
| Strong ink | Darkness at least 64; protect a radius of 2 |
| Text fragments | Join strong ink with a 9×3 rectangle; protect padded boxes by 3, limited to 80% page width and 15% page height |
| Local faint ink | Rounded normalized mean gray, 5×5 closing, residual at least 3; glyph height below 24, width at most 8×height and below 80% page width; protect radius 2 |
| Fold guard for local glyphs | Residual span at least 24, aspect at least 8, occupancy at least 45%; expand guard by 2 |
| Uncertain marks | Preserve components with span below 24 or occupancy below 45%, including shallow signatures |
| Printed rules | Span at least 24, aspect at least 4, at least 95% axial coverage; central 90% of centers varies at most .65 and thickness at most 1 |
| Protection boundary | Expand by 1; confidence 0 inside, 85 at distance 1, 170 at distance 2, 255 beyond |

The printed-rule predicate runs on both local ink and absolute residuals. This
preserves a pale rule embedded in dirt, while requiring both straightness and
stable thickness lets an irregular crease remain eligible. The fold guard stops
small closing artifacts around that crease from being mistaken for punctuation.

The normalized brightness lift is
`L(d) = min(.5*d, 20, max(0,d-8)) * clamp((60-d)/12, 0, 1)`.
Cleanup multiplies the existing common RGB deficit factor by
`1 - L(d)/d * confidence/255`, before final contrast. Thus it removes at most
half the normalized deficit and at most 20 normalized brightness levels. The
low floor and upper taper avoid a discontinuity at either darkness limit.
Rendering samples the small byte map directly and rechecks the full-resolution
pixel's darkness and channel spread. No additional full-resolution floating-point
buffer is allocated. The cached profile gains at most 589,824 cleanup bytes.

On the fixed right-hand crease rectangle in image 3 (original screenshot
`x=465..547, y=456..466`, exclusive upper bounds 548/467), cleanup alone reduced
mean background deficit from 8.1395 to 4.9471, **39.22%**. This already-enhanced
page receives no second normalization or contrast adjustment in that diagnostic.
On the rectified Sparkasse source, an inset mask excluding editor borders and
handles measured **23.15% to 0%** yellow pixels in the red strip; minimum red
dominance increased from -30 to 38. Image 2 identifies the reported failure, and
image 4 is an appearance reference with different geometry, not pixel truth.

The generated neutral pages measured 39.73% less dirt residual and 49.53%/47.63%
less irregular-fold residual at 1x/2x. All 14 page variants (including edge/inset
strips, neutral/warm/cool shadows and JPEG) retained 100% of measurable faint
strokes and local ink contrast, with unchanged dark cores, punctuation, table
rules and signatures. Faint metrics include antialiased truth pixels with local
baseline contrast above 2; local contrast uses an 11×11 neighboring paper
estimate. Native-resolution one-pixel pale rules over dirt also passed at ink
amplitudes of 12 and 25. A 7–65 darkness ramp stays monotonic. The workbench
asserts acceptance thresholds and exits unsuccessfully on a failed gate.

These are finite fixture results, not a general OCR guarantee. An audit found
that a single-pixel, 8-level faint dot on dirt can lose local contrast (8.78 to
4.78); stronger 12–25-level dots were unchanged. Extremely faint content below
analysis resolution remains ambiguous. Small uncertain dirt marks are often
preserved deliberately; cleanup gently reduces residuals rather than removing
all marks. Keep Original and Reduce shadows available and inspect sensitive
documents before export.

Reproduce with `tools/scanner_color/README.md`. All personal-image diagnostics,
lossless native exports, parameters, protection/cleanup masks, enlarged problem
regions, timings and metrics live under ignored `build/scanner-color-refinement/`.

The 2026-10-25 refinement checks used Flutter 3.41.9 / Dart 3.11.5 from
`C:/dev/flutter`, Python 3.12.14, NumPy 2.5.4, OpenCV 5.0.0 and Pillow 12.3.0.
The current dependency resolution requires a compatible SDK; the repository's
older local SDK could not compile its resolved native-hook dependencies. Use
the same SDK for dependency resolution, tests and builds. The offline Dart
exporter uses package imports and needs no native-library environment override.

All 48 selected desktop scanner/app tests passed, including the six new shared
refinement cases. A warm 7.7MP analysis/render took 1.56 seconds on this Windows
debug runner. All 15 lossless comparisons matched exactly for rendered RGB,
paper/protection/cleanup bytes, and rendering with cleanup omitted. Full-app
analysis has no errors or warnings and nine pre-existing informational lints
outside these changes (`--no-fatal-infos` permits that existing baseline).

The x64 Android debug APK also builds successfully. This Windows run selected
Eclipse Adoptium JDK 21 via the process's `JAVA_HOME`; its inherited Android
Studio JDK path was stale. Missing Gradle 8.12 transform metadata required an
isolated Gradle home under the ignored output directory, reusing downloaded
artifacts and regenerating transforms. `kotlin.incremental=false` in that
temporary home's `gradle.properties` avoids the Windows cross-drive Kotlin cache
issue. These are local validation environment settings, with no project build
configuration changes required by the refinement.

The complete `scanner_processing_test.dart` harness passed all **20 Android
checks** on the API 36 x86_64 emulator, including all six new refinement cases,
the existing shared processing/editor regressions, and live camera capture.
The warm 7.7MP analysis/render measured 3.38 seconds on this headless software-GPU
debug emulator; this observation is not a physical-device performance guarantee.
Logs are `android-tests.log`, `android-build.log`, `flutter-tests.log`,
`flutter-analyze.log`, `validation.log` and `native/python-parity.json` under
the ignored refinement output directory.

Commands with this workspace's compatible SDK (adjust installed paths):

```powershell
$scannerFlutter = 'C:/dev/flutter/bin/flutter.bat'
$env:JAVA_HOME = 'C:/Program Files/Eclipse Adoptium/jdk-21.0.6.7-hotspot'
& $scannerFlutter test test/scanner test/src/widget_test.dart --no-pub
& $scannerFlutter analyze --no-pub --no-fatal-infos
& $scannerFlutter build apk --debug --no-pub --target-platform android-x64
.\scripts\test_scanner_android.ps1 -DeviceId emulator-5556 `
  -FlutterPath $scannerFlutter
```

## Verification

Use the repository's pinned Flutter SDK. After dependency setup and code generation:

```powershell
.\flutter\bin\flutter.bat test test/scanner test/src/widget_test.dart
.\scripts\test_scanner_android.ps1 -DeviceId emulator-5554
.\flutter\bin\flutter.bat analyze --no-pub
.\flutter\bin\flutter.bat build apk --debug --no-pub
```

The processing cases are shared between the desktop and Android harnesses,
adapting the v4 native suites. Fixtures are generated synthetically,
carrying forward the previous geometry, shadow-grade, content-preservation,
fallback, profile-reuse, rotation and large-export assertions. Serialization tests
cover old metadata and persistence; editor tests verify the switch and saved bytes.
The original native suites remain available on the backup branch.

The PowerShell Android harness grants camera permission to the debug app on the
selected test device after installation. This avoids a system permission dialog
blocking the camera test when Flutter reinstalls the test app. Use an emulator
or a dedicated test device. The historical commented-out cubit test has no test
entry point; the command above selects the existing runnable app test and the
scanner suite.

Validated on Windows and an Android API 36 emulator: 17 desktop tests and 11
Android checks, including live detection through the auto-capture tracker,
editor persistence, camera streaming/capture and teardown. The scanner sources
and tests have no analyzer findings. Full-app analysis has nine existing
informational lints outside the changed scanner code and no errors or warnings.
The x64 Android debug build succeeds. A 7.7MP analysis/render took approximately
1.3 seconds in a warm emulator run; this debug-process observation is not a
physical-device performance guarantee.

The Python comparison workbench is retained in `tools/scanner_color/`. Its previous
Android comparison measurements describe the preserved v4 implementation; use a
new lossless export to measure parity with this shared implementation.

Synthetic/emulator checks do not establish real-camera accuracy, OCR retention or
physical-device memory/frame-rate behavior. Before release, check pages, receipts,
low contrast, shadows, colored stamps, faint writing, clutter and no-document
scenes; exercise capture, import, crop/apply/cancel, re-edit, rotate, filters,
retake and background/resume. An iOS build and runtime check on a Mac is required
before claiming iOS readiness.
