# Scanner color workbench

Run filter experiments locally before changing the shared implementation. The
workbench reads local images, writes PNGs and metrics, and makes no network calls.
Use a Python virtual environment with `pip install -r requirements.txt`. No Python
package, generated image, or personal reference document is shipped in the app.

## Current Dart baseline and conservative refinement

`dart_reference.py` is the explicit reference for the shared Dart implementation.
It decodes with OpenCV `IMREAD_COLOR` (BGR), bounds analysis to 768 with
`INTER_AREA`, rounds positive values half up, scales closing kernels from the
**original** source dimensions, and samples byte maps with Dart's pixel-centred
double bilinear formula. It does not insert a perspective warp or resize the
rendered crop. `color_lab.py` retains the older experiments separately; its
historical `baseline` is **not** the current Dart baseline.

Install the requirements in a local environment, then run from the repository
root. Outputs belong under ignored `build/`:

```powershell
python tools/scanner_color/validate_refinement.py `
  --output build/scanner-color-refinement
python tools/scanner_color/refinement_lab.py exact-crop.png `
  --output build/scanner-color-refinement/my-crop
```

The validation command fails on a violated acceptance gate. To include the four
local screenshots, pass `--photos /path/to/the/local/four-image-directory`, whose
files are `1-115089.jpg`, `2-115091.jpg`, `3-115093.jpg`, `4-115104.jpg`. Personal
paths and images are not tracked. The optional screenshots reproduce the
Sparkasse distortion and measure the independent cleanup on image 3; image 4 is
only an appearance reference. In the original screenshot coordinate system:

* Sparkasse quad: `(78,348), (495,339), (517,980), (65,988)`, rectified to
  452 by 641 with cubic interpolation. The fixed red measurement mask uses
  `x=28..419, y=1..10` in the rectified image and requires original red dominance
  greater than 35. This excludes editor handles and the green border.
* Image 3 page: `x=38..552, y=217..896`; fixed crease rectangle:
  original `x=465..547, y=456..466`. Cleanup is tested alone: no second white
  balance, contrast, or highlight curve.

The red failure came from narrow saturated content disappearing from the broad
morphological color estimate. Residual red samples then contaminated the paper
field; normalizing the strip against itself produced yellow/orange breaks. The
refinement additionally checks **original analysis pixels**, normalized by the
existing channel references, with the same relative spread threshold `.35`.
Detected pixels join content protection and paper-sample exclusion. Existing
contrast selection, gain limits, histogram thresholds, and fallback stay intact.

Cleanup operates on the normalized analysis image after the final paper-map
median and before final contrast. Its frozen v1 parameters are also emitted to
`parameters.json`:

* Strong ink: maximum RGB darkness at least 64; expand by two analysis pixels.
  Join fragments with horizontal radius 4 and vertical radius 1, then pad
  plausible text boxes by three pixels (width at most 80% and height at most 15%
  of the page). Existing content protection is retained.
* Recover faint glyphs connected to shallow shadow residuals using a 5 by 5
  grayscale closing, local difference at least 3, component height below 24,
  width at most eight times height and below 80% page width. Expand by two.
  Suppress that rescue within a two-pixel neighborhood of a dense elongated
  residual (span at least 24, axis ratio at least 8, occupancy at least 45%).
* Preserve small weak components (span below 24), sparse structures (occupancy
  below 45%, including shallow signatures), and stable printed rules. Both
  absolute weak components and local closing residuals receive the rule test.
  Rules require span at least 24, axis ratio at least 4, at least 95% occupied
  columns/rows, central 90% centre-position spread at most `.65` pixel **and**
  central 90% thickness spread at most one pixel. This tolerates table junctions
  while rejecting wandering, irregular folds.
* Expand final protection by one. The byte cleanup confidence is 0 on protected
  pixels, 85 one pixel away, 170 two pixels away, and 255 beyond that. Cleanup
  eligibility is darkness 8 through 60 and channel spread at most 18.
* For normalized maximum channel darkness `d`, the permitted lift is
  `min(.5*d, 20, max(0,d-8)) * clamp((60-d)/12,0,1)`. Multiply by sampled
  confidence/255 and apply one common RGB deficit factor. The low-end floor and
  high-end taper avoid a tonal reversal at the darkness limits. Recheck darkness
  and color on each original full-resolution pixel. Dark cores stay unchanged;
  the map adds at most 768 by 768 bytes and no full-resolution float image.

The corpus includes dark text, anti-aliased faint text, a wholly faint sentence,
decimal punctuation, a shallow signature, a pale table grid, known dirt and
irregular folds, edge/inset red strips, neutral/warm/cool shadows, and JPEG quality
80. Native-resolution 1-pixel pale rules cross a dirt gradient on a 1536-pixel
page, testing information loss during analysis downsampling. The 7..65 darkness
ramp must remain monotonic. Text metrics use every truth-covered pixel with
baseline local contrast above two levels, measured against an 11 by 11 local
paper maximum; excluded near-white pixels are reported explicitly. Cleanup
preservation compares with an identical profile with its cleanup map omitted.

Frozen Python measurements (2026-10-25):

| Fixed case | Before | After | Result |
| --- | ---: | ---: | --- |
| Image 3 crease, mean residual darkness | 8.1395 | 4.9471 | 39.22% less |
| Synthetic dirt, mean residual darkness | 11.8224 | 7.1255 | 39.73% less |
| Synthetic fold, 768 / 1536 render | 23.3654 | 11.7920 / 12.2374 | 49.53% / 47.63% less |
| Sparkasse red ROI, yellow fraction | 23.15% | 0% | 3918 fixed red pixels |
| Sparkasse minimum red dominance | -30 | 38 | No hue-direction reversal |
| Measurable faint strokes / punctuation / rules / signatures | — | 100% coverage and local contrast | Zero changed content pixels in 14 generated pages |
| Native 1-pixel rules, 12/25-level source contrast | — | 100% coverage and local contrast | Zero changed rule pixels |

All 15 pre-change Dart baseline lossless renders matched Python exactly (RGB
MAE/max 0). After the shared Dart port, all 15 refined renders, renders with
cleanup omitted, and paper/protection/cleanup bytes also matched exactly; the
contrast differences were below `1e-12`. To export and compare a new native
profile/output:

```powershell
# Use the same compatible SDK as dependency resolution. This workspace was
# validated with Flutter 3.41.9 / Dart 3.11.5 at C:/dev/flutter.
$scannerDart = 'C:/dev/flutter/bin/dart.bat'
& $scannerDart run tools/scanner_color/export_refinement.dart `
  exact-crop.png build/scanner-color-refinement/native
python tools/scanner_color/refinement_lab.py exact-crop.png `
  --output build/scanner-color-refinement/parity `
  --native build/scanner-color-refinement/native
```

The Dart harness also accepts `--manifest build/scanner-color-refinement/manifest.json
build/scanner-color-refinement/native-batch`. It writes lossless output and raw
paper/protection/cleanup bytes. `--baseline-native` compares a pre-change export.
For a whole exported batch, run:

```powershell
python tools/scanner_color/compare_native.py `
  build/scanner-color-refinement/manifest.json `
  build/scanner-color-refinement/native-batch
```

Keep the same decoded crop: JPEG re-encoding or a different perspective warp
prevents lossless parity. Per-case comparisons, enlarged regions, truth masks,
protection/cleanup maps, parameters, timing, and metrics remain under ignored
build output. Rendering and analysis timings are diagnostic, not device claims.

The shared Dart port passed 48 desktop scanner/app tests and all 20 checks in
`scanner_processing_test.dart` on an API 36 x86_64 emulator, including the six new
refinement cases and live camera capture. The Android x64 debug build succeeds.
Full-app analysis has no errors or warnings and nine existing informational
lints outside this work. The 7.7MP debug analysis/render measured 1.56 seconds on
Windows and 3.38 seconds on the software-GPU emulator. See
`docs/scanner-enhancements.md` for the compatible SDK/JDK commands and the local
Gradle-cache workaround used for this run.

Very faint neutral information below analysis resolution can remain ambiguous:
an isolated 1-pixel, eight-level mark on dirt was not established as preserved.
These tests do not claim OCR accuracy or universal handwriting preservation.
Small uncertain dots are deliberately retained; remaining broad gray fills,
extreme exposure and document photographs still need visual review. Original and
Reduce shadows remain the reversible controls. Android/iOS runtime verification
is documented with the shared scanner checks in `docs/scanner-enhancements.md`.

```sh
python color_lab.py original.jpg --crop 198,46,795,1167 \
  --reference adobe.jpg --reference-crop 199,43,802,1180 \
  --output /path/to/ignored/scan-experiment
```

Crop values are `x,y,width,height`. Omit them for already cropped pages. The sample
coordinates above isolate the pages in the supplied comparison screenshots; they
are not part of the filter. Output includes each processed page, paper map,
excluded-sample mask, protected-content mask, a comparison, and `metrics.json`.
Pass `--native native-export.png` to compare the refined Python output with a
lossless Android export of the same crop. `--methods baseline refined` limits the
run to those methods.

## Historical experiments

The workbench retains four reproducible methods:

| Method | Observation on the reference |
| --- | --- |
| `baseline` | The previous RGB closing/fill pipeline leaves yellow bands around blue lettering. |
| `expanded-mask` | Excluding more ink and removing the final closing helps, but wide masks blend across nearby shadow boundaries. |
| `luminance-chroma` | Separate illumination and local color estimates reduce some artifacts, but still leave a band where text crosses a shadow. |
| `refined` | Narrow luminance-based ink exclusion, actual RGB paper samples, and protected highlight cleanup remove most of the bands. This was ported to the previous native implementations; it predates the explicit shared Dart reference above. |

Additional trials varied ink-window sizes (5/7/9/15/31), exclusion radii (1/2/3),
local chroma neighborhoods (9/15/31/63), and highlight cleanup strength. Wider
exclusion and another per-channel morphological closing were rejected because
they contaminated paper estimates near text or mixed opposite sides of a shadow.

The refined method uses a small window for faint thin strokes and a larger window
for strong thick strokes. It retains broad colored graphics, dense texture, and
enclosed gray panels. A raw-pixel percentile avoids treating resampling overshoot
as the paper white point. The last roughly 6% below white receives a smooth curve
using one factor for all RGB channels. Protected fills bypass that curve. Paper
estimation still uses the existing bounded analysis resolution and gain limit.

## Interpreting results

Metrics use a fixed candidate-paper mask selected from the input, not from each
output. They measure brightness/chroma contamination, not OCR accuracy or loss of
faint writing. Always inspect signatures, pale logos, colored text and filled
graphics alongside the paper metrics. The resized Adobe screenshot is an
appearance reference: different crop geometry and JPEG encoding prevent an exact
pixel comparison. A white image would score well on paper metrics and fail content
preservation, so those metrics must never be the sole acceptance criterion.

On the supplied original, the native export and Python refined output differed by
0.10 RGB levels on average (0–255 scale). Fixed strips above/between the blue text
in the native export averaged 254.52 brightness and 0.69 channel spread. The
previous native JPEG measured 242.44 and 12.47 in those strips. Both signatures
and the pale logo were visually retained. These are measurements of this example,
not a benchmark across arbitrary documents.

Native regression tests cover JPEG-compressed colored text, dense type with pale
fills, 0/5/15/35/60/80% light loss, sharp/soft boundaries, warm/cool casts, faint
writing, conservative fallbacks, preview/export reuse and the existing scanner
workflow. Very faint marks, filled gray areas inside shadows, and severely
underexposed paper remain intrinsically ambiguous; keep the Original filter and
Reduce shadows toggle available. iOS runtime tests require a Mac.
