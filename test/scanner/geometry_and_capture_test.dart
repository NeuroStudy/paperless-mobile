import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/processing/frame_stability_tracker.dart';
import 'package:paperless_mobile/features/scanner/processing/ranked_document_detector.dart';

void main() {
  test(
    'perspective pages, landscape pages and narrow receipts remain valid',
    () {
      for (final points in [
        [
          const Offset(.1, .15),
          const Offset(.8, .1),
          const Offset(.9, .85),
          const Offset(.2, .95),
        ],
        [
          const Offset(.1, .4),
          const Offset(.9, .4),
          const Offset(.9, .65),
          const Offset(.1, .65),
        ],
        [
          const Offset(.4, .1),
          const Offset(.55, .1),
          const Offset(.55, .9),
          const Offset(.4, .9),
        ],
      ]) {
        expect(isValidDocumentQuad(points), isTrue);
      }
    },
  );
  test(
    'crossing, concave, duplicate and out-of-bounds corners are rejected',
    () {
      for (final points in [
        [
          const Offset(.1, .1),
          const Offset(.9, .9),
          const Offset(.9, .1),
          const Offset(.1, .9),
        ],
        [
          const Offset(.1, .1),
          const Offset(.9, .1),
          const Offset(.4, .4),
          const Offset(.1, .9),
        ],
        [
          const Offset(.1, .1),
          const Offset(.9, .1),
          const Offset(.9, .1),
          const Offset(.1, .9),
        ],
        [
          const Offset(-.1, .1),
          const Offset(.9, .1),
          const Offset(.9, .9),
          const Offset(.1, .9),
        ],
      ]) {
        expect(isValidDocumentQuad(points), isFalse);
      }
    },
  );
  test(
    'corner ordering is independent of contour starting point and winding',
    () {
      final ordered = orderDocumentCorners([
        const Offset(.9, .9),
        const Offset(.9, .1),
        const Offset(.1, .1),
        const Offset(.1, .9),
      ]);
      expect(ordered, [
        const Offset(.1, .1),
        const Offset(.9, .1),
        const Offset(.9, .9),
        const Offset(.1, .9),
      ]);
    },
  );
  test(
    'v5 tracker captures once and resets on movement or detection loss',
    () async {
      final tracker = FrameStabilityTracker(
        const AutoCaptureConfig(
          minConsecutiveSimilarFrames: 2,
          preStableDelay: Duration.zero,
          stableDuration: Duration(milliseconds: 10),
          distanceThreshold: 5,
        ),
      );
      final frame = DocumentFrame(
        topLeft: const Offset(10, 10),
        topRight: const Offset(90, 10),
        bottomRight: const Offset(90, 90),
        bottomLeft: const Offset(10, 90),
      );
      tracker.update(frame);
      tracker.update(frame);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tracker.isReadyToCapture, isTrue);
      expect(tracker.stableFrame, same(frame));
      tracker.markCaptured();
      expect(tracker.isReadyToCapture, isFalse);
      tracker.update(frame.scale(2, 2));
      expect(tracker.progress, 0);
      tracker.update(null);
      expect(tracker.stableFrame, isNull);
      expect(tracker.progress, 0);
      tracker.update(frame);
      expect(tracker.isReadyToCapture, isFalse);
    },
  );
}
