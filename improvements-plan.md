# Deferred improvements for the Alpha 2 scanner

## Decision: defer camera and detection recovery

Recorded on 2026-10-25 at the user's request.

Source commit: `271aa5fa006f7955ea106c71aad59ee9df121217`
(`fix: recover scanner detection and camera lifecycle`), originally on
`codex/scan-enhancement-v5`.

**Status: deferred. Do not port this commit during the current Alpha 2
consolidation.** Revisit it if a reproducible scanner startup, detection-worker,
capture, or background/resume failure occurs. It is not a prerequisite for the
other planned ports. Do not bring it in indirectly when adapting their tests.

The development baseline is `codex/scan-enhancement-alpha2`, initially at
`9bb8c8d5`. The single maintained working folder is `D:\DEV\paperless-mobile`. The original
source commit is preserved by `archive/2026-10-25/scan-enhancement-v5` and the
private consolidation Git bundles. The old development branch has been retired;
inspect the archive tag without switching the maintained development branch.

## Goal and reason for deferral

The goal is to recover automatically when document detection does not start,
its background worker stops responding, or camera analysis stops delivering
frames, so the user does not need to close and reopen the scanner. A related
goal is to prevent capture, stream shutdown and camera replacement from racing.

Alpha 2 already contains camera teardown and cancellation fixes from
`212a5a6f`: detach listeners before shutdown, stop only active streams, wait for
initialization and release, ignore stale initialization/results, and cancel
pending worker waits when disposing. Keep those existing fixes.

The deferred commit adds broader supervision and recovery. Its necessity has
not been established on the retained Alpha 2 implementation. Porting it now
would change several interacting camera components and require substantial
adaptation, so the current preference is to retain Alpha 2's working behavior
and fix a demonstrated problem later.

## What the source commit adds

| Area | Behavior in the source commit |
| --- | --- |
| Worker startup | Share startup between callers, reserve the in-flight slot before startup completes, and impose a five-second startup deadline. |
| Worker requests | Impose a three-second reply deadline; handle worker errors, exits and cancellation; complete pending waits and close communication ports. |
| Outcome handling | Distinguish a skipped frame, a successful no-document result and an actual processing failure. Finding no document must not trigger recovery. |
| Stream supervision | After three seconds without camera frames, restart the analysis stream; replace the camera if the restarted stream remains silent. |
| Retry control | Retry failures with capped delays of 250 ms, one second and two seconds. Reset stale tracking state during recovery. |
| Transition ordering | Serialize stream start/stop, camera release and resume. Use session generations to reject results from earlier camera sessions. |
| Capture coordination | Snapshot the fallback crop, await detection/stream pause before taking a picture, and resume detection after unsuccessful capture as well as after editing. |
| Image conversion | Respect supported image formats and row/pixel strides; share live/debug conversion, orientation and detection configuration. |
| Camera lifecycle | Notify detection when a controller is released/replaced, detach listeners before disposal, and prevent late callbacks from updating disposed views. |

The source introduces `ScannerDetectionSession` and
`ScannerDetectionController`, a restartable `EdgeDetectionRunner`, an explicit
`DetectionFailed` outcome, and changes to the scanner view, camera view and
capture integration. It also adds lifecycle, worker, stream and image-conversion
tests and updates the Android test entrypoints.

## Requirements for any future Alpha 2 implementation

1. Reproduce the actual failure first and add a regression test. Implement the
   smallest relevant recovery change rather than automatically importing the
   entire source commit.
2. Work only on the canonical Alpha 2 branch. Keep the standalone
   `paperless_mobile_document_scanner` package and its existing app integration.
3. Preserve Android's luminance-only analysis, YUV420 camera configuration,
   four-point detector defaults and previous-corner ranking/tracking. Do not
   replace these with the v5 branch's RGBA analysis or detector defaults.
4. Preserve the compact scanner controls, spirit level, overlays, portrait
   capture, 1080p default, auto-capture timing and perspective-proportion
   correction. Recovery must not introduce the later scanner settings UI.
5. Keep normal no-document scenes distinct from faults. Prevent duplicate
   captures, parallel recovery loops and late results reaching a new session.
6. Adapt package imports, image-channel transport and controller notifications
   together if the supervision architecture is needed. Preserve existing public
   scanner callbacks or provide compatible adapters.
7. Treat the source deadlines and retry delays as documented starting values,
   not proven Alpha 2 requirements. Verify them against the reproduced failure
   and representative device behavior before enabling recovery.

## Validation before adopting a future fix

- Establish that the new regression fails before the fix and passes after it.
- Run Alpha 2's existing recognition, capture-quality, perspective, worker and
  camera lifecycle suites without weakening their assertions.
- Where relevant, exercise stalled startup, missing replies, worker crashes,
  concurrent startup requests and disposal with pending work. Check that all
  waits complete and resources are released.
- Where relevant, exercise a silent stream, stream restart, camera replacement,
  repeated failures, background/resume and stale callbacks. Confirm bounded
  retries and no recovery during intentional pause or shutdown.
- Exercise capture success/failure, return from editing and scanner closure.
  Confirm one capture per trigger and correct restoration of live analysis.
- Retain image-stride/orientation cases and live/debug recognition agreement
  without sacrificing Alpha 2's luminance-only path.
- Validate the reproduced scenario on Android and on the affected physical
  phone before claiming that its camera issue is resolved. Run iOS checks if
  shared camera lifecycle code changes.

The source commit records 58 selected scanner/app tests and targeted analysis
passing on its own v5 tree. That is historical evidence for that tree, not
validation of an Alpha 2 port or proof of physical-phone reliability.

Commit a future fix separately, referencing the reproduced issue, this source
commit, the selected changes and actual validation results. Update this document
to distinguish implemented portions from work that remains deferred.

## Deferred: maximum-resolution camera capture

Recorded on 2026-10-25 at the user's request. This is separate from the deferred
camera-recovery commit above.

**Status: investigation deferred. Keep Alpha 2's 1080p capture default during
consolidation.** Do not import the other branch's `resolutionPreset = 'max'`
default. Explicit higher-resolution overrides already exist; adding a new
resolution control or changing the production default is not part of this task.

### Goal and current behavior

The goal is to capture more fine document detail for small text, faint writing
and later OCR, using the highest resolution that produces reliable images on
the actual device. More output pixels are useful only if they retain correct
colors, sharp text and page proportions.

Alpha 2's scanner and camera view default to `ResolutionPreset.veryHigh`, a
1080p target, following commit `9bb8c8d5`. The later v5 scanner instead defaults
to `ResolutionPreset.max`. Requested presets are negotiated with the camera;
record actual JPEG dimensions rather than assuming a preset guarantees a
particular resolution or the sensor's advertised megapixel count. Keep still
capture resolution separate from the bounded live-detection analysis size.

### Known reason to retain 1080p

The existing investigation in [scanner-enhancements.md](docs/scanner-enhancements.md#capture-color-regression-investigation)
records physical S25 Ultra testing (SM-S938B, Android 16):

- Actual 2160x3840 captures contained a green left border, reversed colors and
  displaced colored lettering/signatures with both NV21 and YUV420 analysis.
- Actual 720x1280 and 1080x1920 captures retained correct colors and aligned ink.
- Pillow, Flutter and OpenCV decoded each original to identical RGB pixels,
  locating the 4K corruption in native JPEG capture before app editing.
- The 1080p perspective/editor outputs retained correct colors with Enhance
  both enabled and disabled. Switching analysis format alone did not fix 4K.

These are historical results documented for that phone and camera setup, not
evidence that maximum resolution fails on every device. Increasing resolution
must not reintroduce this known regression, and enhancement cannot restore
already-corrupted source captures.

### Future investigation and acceptance criteria

1. Extend the existing `-CaptureComparison` diagnostic to include
   `ResolutionPreset.max` alongside `high`, `veryHigh` and `ultraHigh`. Preserve
   the current stop-stream-then-capture sequence and record requested presets,
   actual JPEG/preview/analysis dimensions, formats, device and software versions.
2. Compare the same stationary document at each supported resolution, including
   blue/orange lettering, fine black text, faint signatures and neutral borders.
   Retain the untouched JPEG and compare Flutter/OpenCV decoding, perspective
   output, editor preview and saved exports. Keep private images out of Git.
3. Require correct colors, aligned ink, no green border, retained faint strokes,
   accurate proportions and displayed/saved pixel agreement. Confirm an actual
   detail benefit over 1080p; larger dimensions alone do not establish quality.
4. Measure capture/edit latency, peak memory and repeated-capture stability.
   Detection must remain bounded and responsive; increasing still resolution
   must not require full-resolution analysis of every live frame.
5. Validate on the affected S25 Ultra and representative additional physical
   devices. Emulator fallback to a lower resolution cannot validate 4K or max.
   Verify that unsupported requests and camera initialization failures can fall
   back to the known working 1080p configuration without losing existing scans.
6. Keep higher resolution explicit and opt-in until these checks pass. Any
   later default change requires its own documented implementation, tests and
   commit. Do not add unvalidated automatic corruption detection or a device
   blacklist as a substitute for diagnosing the capture fault.

No camera settings or capture behavior are changed by this document. Future
work should update this section with the actual resolutions tested, image-quality
findings, performance results and the resulting supported configuration.
