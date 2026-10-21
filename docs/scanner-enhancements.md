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
