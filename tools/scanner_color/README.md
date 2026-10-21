# Scanner color workbench

Run filter experiments locally before changing the native implementation. The
workbench reads local images, writes PNGs and metrics, and makes no network calls.
Use a Python virtual environment with `pip install -r requirements.txt`. No Python
package, generated image, or personal reference document is shipped in the app.

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

## Experiments

The workbench retains four reproducible methods:

| Method | Observation on the reference |
| --- | --- |
| `baseline` | The previous RGB closing/fill pipeline leaves yellow bands around blue lettering. |
| `expanded-mask` | Excluding more ink and removing the final closing helps, but wide masks blend across nearby shadow boundaries. |
| `luminance-chroma` | Separate illumination and local color estimates reduce some artifacts, but still leave a band where text crosses a shadow. |
| `refined` | Narrow luminance-based ink exclusion, actual RGB paper samples, and protected highlight cleanup remove most of the bands. This is the method ported to both native implementations. |

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
