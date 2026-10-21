# Four-point recognition comparison

`reference_detector.py` independently translates the preserved Kotlin
`PaperProcessor.kt` algorithm from commit `4e2f3cd9` on
`codex/scan-enhancement-v4-backup`. This is an offline numerical oracle, not a
replacement app dependency or a run of the original APK. The Python/OpenCV
versions used to generate the reference are pinned in `requirements.txt`;
the Android reference used OpenCV 3.4.5 and the app uses dartcv4's OpenCV build.
The tests allow three source-image pixels for library/rounding differences.

The earlier Dart port changed the algorithm's behavior: it reduced live analysis
to 320px, used median filtering and padding/dilation, accepted smaller contours,
and omitted previous-corner agreement. Eight of ten added comparisons failed
before the correction, including false documents in noise and small background
patches. The restored default uses 960px analysis, Gaussian 5 smoothing, a 3x3
close on separate Canny/Otsu proposals, no padding/dilation, a 6%-97% area range,
the original approximation values, edge support and score weights.

The regression inputs are synthetic and generated in
`test/scanner/recognition_cases.dart`. No personal photographs are included.
With a Python environment containing the pinned requirements, regenerate the
reference on Windows using:

```powershell
$env:SCANNER_FIXTURE_EXPORT = 'C:\temp\scanner-recognition-fixtures'
$env:SCANNER_FIXTURE_EXPORT_ONLY = '1'
.\flutter\bin\flutter.bat test --no-pub test/scanner/recognition_test.dart
Remove-Item Env:SCANNER_FIXTURE_EXPORT_ONLY
Remove-Item Env:SCANNER_FIXTURE_EXPORT
python tools/scanner_detection/reference_detector.py C:\temp\scanner-recognition-fixtures --dart-output test/scanner/recognition_reference.dart
.\flutter\bin\dart.bat format test/scanner/recognition_reference.dart
.\flutter\bin\flutter.bat test --no-pub test/scanner/recognition_test.dart
```

The reference compares independent single images. Additional live-worker tests
check candidate continuity, reacquisition after movement/loss, rotation and direct
luminance input. They keep alpha2's auto-capture tracker and drawing behavior.
Luminance stride tests ensure padding/chroma do not create false edges. The
Android integration harness also checks an actual NV21 camera frame, granting
permission to the debug test app on the explicitly selected device.
The harness uses `flutter drive --no-dds` to avoid the pinned SDK's intermittent
DDS connection and its DDS-only golden stream listener in `flutter test`.

Synthetic/reference agreement establishes regression coverage. It does not prove
all real scenes can be classified correctly. Test the resulting APK on real
pages, receipts, clutter, shadows and skews on the intended phone.
