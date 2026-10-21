# Paperless Mobile scanner

This is a maintained local fork of `edge_detection` 1.1.3, upstream revision
`bbc6a939e29689790f1b64734df39a66334e0be9` from
https://github.com/sawankumarbundelkhandi/edge_detection.

The iOS WeScan source is vendored from the **1.7.0 tag**, revision
`a265d3321184c79414066d7e06d4f05d3902afc0`, matching the previously resolved pod.
Its upstream podspec incorrectly called that tag 1.6.0; the local podspec corrects
the version and sets the existing scanner minimum of iOS 13. Both upstream
licenses are retained. The app Podfile explicitly selects this local pod.

Android uses CameraX with a bounded, luminance-only analysis pipeline and ranked
OpenCV contours. Both platforms use a smaller proportional camera viewport,
alignment dots that disappear on stable detection, and a reversible crop/filter
editor. The channel API and destination JPEG contract are unchanged.

Enhanced color includes adaptive illumination correction, enabled by default and
controlled by **Reduce shadows** in the preview. Turning it off uses the previous
modest contrast adjustment. The other filters are unaffected.

## Color optimization

Analysis happens after the perspective crop, in sRGB, on an image no larger than
768 pixels. Narrow/wide luminance closings distinguish thin faint strokes from
strong thick strokes. A one-pixel margin excludes colored JPEG fringes without
bridging the gaps between lines. Strong broad color, dense texture, and enclosed
rectangular panels receive separate protection. Surrounding paper supplies the
missing illumination samples, keeping actual RGB triplets together instead of
combining unrelated channel maxima. A raw-pixel percentile avoids inflated paper
estimates caused by resampling overshoot. Images without enough reliable paper
use conservative contrast.

A median-smoothed RGB map corrects uneven illumination and color casts. A gentle
curve cleans the last roughly 6% below white, preserving color direction and
bypassing protected fills. White-anchored contrast (1.08–1.6) then improves ink
legibility. Gain is capped at 4x, so severely underexposed areas can retain shading.
This is an appearance approximation, not Adobe's implementation.

The editor caches one profile per committed crop and shares it between preview
and export. Rotation and toggling do not repeat analysis. Android applies the map
in 64-row strips to bound floating-point working memory; iOS uses Core Image.
All renders start from the untouched image. Faint ink is retained rather than
thresholded to white. Printed gray areas and hard rectangular shadows can be
ambiguous, so the conservative fallback and Original filter remain available.

Background-estimation rationale: Bako et al., *Removing Shadows from Images of
Documents*, ACCV 2016, https://web.ece.ucsb.edu/~psen/Papers/ACCV16_RemovingShadows.pdf.
No research source code or learned model is bundled.

## Device acceptance

Check ordinary pages, receipts, landscape pages, low contrast, shadows, clutter,
colored stamps, faint writing, and no-document scenes. Compare four annotated
corners with the previous implementation: target <=2% image-diagonal error on
>=90% of ordinary-page fixtures, improved difficult cases, and no increase in
false detections. These are release targets, not claimed measured results.

Exercise capture, import, repeated crop/apply/cancel, rotate, every filter, rapid
filter changes, retake, cancel, background/resume, and write failure. Verify that
preview coordinates match the saved crop and that repeated edits do not degrade
the image. Save is atomic, JPEG quality 95, longest edge <=4096, never upscaled.
Camera accuracy, OCR/content preservation, frame rate and memory must be checked
on physical devices; desktop compilation alone cannot establish these results.

## Automated verification

JVM tests cover crop geometry and temporal tracking. Android instrumentation
covers detection, EXIF, JPEG saving, crop/apply/cancel, and camera/editor flows.
Color tests cover 0/5/15/35/60/80% light loss, soft and sharp boundaries, warm/cool casts,
faint writing, gray/colored panels, photo-like texture, the gain limit, profile
reuse, rotation, preview/export agreement, switch restoration, and a 7.7MP export.
They also check paper between JPEG-compressed blue text lines and pale fills
surrounded by dense lettering. The optional reference test measures fixed line
gaps and writes a lossless PNG for comparison with the offline prototype.
These synthetic fixtures do not establish real-camera accuracy or physical-device
performance. An optional local reference test accepts `-e scannerReference
/data/local/tmp/example.jpg`; it expects the supplied 1176x1280 comparison screenshot
and writes the processed page and map to the test app's external files directory.
Personal reference images are never bundled with the plugin or its tests.

The [offline Python workbench](tools/README.md) reproduces the previous pipeline,
alternative methods, and the refined filter, with images and diagnostic metrics.
Its dependencies are isolated from the application.

Run from the app's Android Gradle project:

```
gradle :edge_detection:testDebugUnitTest :edge_detection:connectedDebugAndroidTest
```

Also run `flutter analyze --no-pub lib/features/document_scan packages/edge_detection/lib`
and `flutter build apk --debug --no-pub` from the app root. The fork requires Android
API 23+ (the app already requires API 24+) and preserves iOS 13+. iOS sources were
syntax checked on Windows; **run CocoaPods installation and an Xcode build on a
Mac before releasing iOS**. The Podfile selects the local WeScan source; CocoaPods
will refresh its lockfile and checksums during that build.

The WeScan pod's `ProcessingTests` test spec contains iOS shadow-grade and
preview/toggle tests. Include that test spec in a Mac test host and run its XCTest
scheme on a simulator/device. Windows syntax checks do not execute Core Image
kernels or establish Android/iOS rendering parity.
