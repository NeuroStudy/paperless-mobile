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
`9bb8c8d5`. The intended single working folder after consolidation is
`D:\DEV\paperless-mobile`. Preserve the source commit in the consolidation
backup/archive before retiring its development branch.

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
