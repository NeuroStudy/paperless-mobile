import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/models/debug_stage.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/models/scanner_parameters.dart';
import 'package:paperless_mobile/features/scanner/processing/edge_detection_isolate.dart';
import 'package:paperless_mobile/features/scanner/processing/scanner_detection_session.dart';

import 'camera_test_support.dart';

final _frame = FrameDetected(
  DocumentFrame(
    topLeft: Offset.zero,
    topRight: const Offset(1, 0),
    bottomRight: const Offset(1, 1),
    bottomLeft: const Offset(0, 1),
  ),
  const Size(2, 2),
);

class _Runner extends EdgeDetectionRunner {
  int starts = 0;
  int resets = 0;
  int detections = 0;
  bool disposed = false;
  Completer<void>? startup;
  Completer<DetectionOutcome?>? response;
  DetectionOutcome result = FrameNotFound();

  @override
  Future<void> start() async {
    starts++;
    await startup?.future;
  }

  @override
  Future<DetectionOutcome?> detect({
    required Uint8List rgbaBytes,
    required int width,
    required int height,
    required int rotationCompensation,
    required EdgeDetectionConfig edgeDetectionConfig,
  }) async {
    detections++;
    return response?.future ?? Future.value(result);
  }

  @override
  void reset() => resets++;

  @override
  void dispose() => disposed = true;
}

class _Harness {
  final runner = _Runner();
  final camera = TestCameraController();
  final replacement = TestCameraController();
  final detections = <DocumentFrame?>[];
  int resets = 0;
  int replacements = 0;
  late final ScannerDetectionSession session = ScannerDetectionSession(
    runner: runner,
    onDetection: (frame, _, debug) {
      debug?.dispose();
      detections.add(frame);
    },
    onReset: () => resets++,
    restartCamera: () async {
      replacements++;
      await session.setCamera(null);
      await session.setCamera(replacement);
    },
  );

  Future<void> enable(bool enabled) => session.configure(
    enabled: enabled,
    debugStage: DebugStage.none,
    config: EdgeDetectionConfig.fast,
  );

  Future<void> start() async {
    await enable(true);
    await session.setCamera(camera);
  }
}

void _sessionTest(
  String name,
  Future<void> Function(WidgetTester, _Harness) body,
) {
  testWidgets(name, (tester) async {
    final h = _Harness();
    try {
      await body(tester, h);
    } finally {
      await h.session.dispose();
    }
  });
}

void main() {
  _sessionTest('equal settings on rebuild preserve the running detector', (
    tester,
    h,
  ) async {
    await h.start();
    final resets = h.resets;
    await h.session.configure(
      enabled: true,
      debugStage: DebugStage.none,
      config: const ScannerParameters().toEdgeDetectionConfig(),
    );
    expect(h.camera.starts, 1);
    expect(h.resets, resets);
    await h.session.configure(
      enabled: true,
      debugStage: DebugStage.none,
      config: const ScannerParameters(
        resizeThreshold: 400,
      ).toEdgeDetectionConfig(),
    );
    expect(h.camera.starts, 2);
    expect(h.resets, greaterThan(resets));
  });
  _sessionTest('disabling during worker startup prevents a late stream start', (
    tester,
    h,
  ) async {
    h.runner.startup = Completer<void>();
    await h.enable(true);
    final starting = h.session.setCamera(h.camera);
    await tester.pump();
    final disabling = h.enable(false);
    h.runner.startup!.complete();
    await starting;
    await disabling;
    expect(h.camera.starts, 0);
    expect(h.camera.value.isStreamingImages, isFalse);
  });

  _sessionTest(
    'capture pause awaits shutdown through rapid configuration changes',
    (tester, h) async {
      await h.start();
      h.camera.streamStop = Completer<void>();
      var paused = false;
      final pausing = h.session.setPaused(true).then((_) => paused = true);
      await tester.pump();
      expect(paused, isFalse);
      final disabled = h.enable(false);
      final enabled = h.enable(true);
      h.camera.deliver();
      h.camera.streamStop!.complete();
      await pausing;
      await disabled;
      await enabled;
      expect(h.camera.value.isStreamingImages, isFalse);
      expect(h.detections, isEmpty);
      await h.session.setPaused(false);
      expect(h.camera.starts, 2);
      expect(h.camera.value.isStreamingImages, isTrue);
    },
  );

  _sessionTest(
    'stream start retries and ordinary misses keep the stream healthy',
    (tester, h) async {
      h.camera.failStart = true;
      await h.start();
      expect(h.camera.value.isStreamingImages, isFalse);
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.camera.value.isStreamingImages, isTrue);
      final resets = h.resets;
      for (var i = 0; i < 5; i++) {
        h.camera.deliver();
        await tester.pump(const Duration(seconds: 1));
      }
      expect(h.camera.starts, 2);
      expect(h.replacements, 0);
      expect(h.resets, resets);
      expect(h.detections, hasLength(5));
    },
  );

  _sessionTest(
    'worker failure resets detection without restarting a healthy stream',
    (tester, h) async {
      await h.start();
      h.runner.result = DetectionFailed('worker stopped');
      h.camera.deliver();
      await tester.pump();
      h.runner.result = _frame;
      await tester.pump(const Duration(milliseconds: 250));
      h.camera.deliver();
      await tester.pump();
      expect(h.camera.starts, 1);
      expect(h.detections.single, same(_frame.frame));
    },
  );

  _sessionTest('silent streams restart before replacing the camera', (
    tester,
    h,
  ) async {
    await h.start();
    await tester.pump(const Duration(seconds: 3));
    expect(h.camera.starts, 2);
    expect(h.replacements, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(h.replacements, 1);
    expect(h.replacement.value.isStreamingImages, isTrue);
    h.camera.deliver();
    await tester.pump();
    expect(h.detections, isEmpty);
    h.replacement.deliver();
    await tester.pump();
    expect(h.detections, hasLength(1));
  });

  _sessionTest(
    'pausing invalidates a detection that completes during capture',
    (tester, h) async {
      await h.start();
      h.runner.response = Completer<DetectionOutcome?>();
      h.camera.deliver();
      await tester.pump();
      await h.session.setPaused(true);
      h.runner.response!.complete(_frame);
      await tester.pump();
      expect(h.detections, isEmpty);
      h.runner.response = null;
      h.runner.result = _frame;
      await h.session.setPaused(false);
      h.camera.deliver();
      await tester.pump();
      expect(h.detections.single, same(_frame.frame));
    },
  );

  _sessionTest(
    'failed pause aborts capture and a finally resume restores detection',
    (tester, h) async {
      final control = ScannerDetectionController()..attach(h.session);
      await h.start();
      h.camera.failStop = true;
      var captured = false;
      try {
        await control.pause();
        captured = true;
      } catch (_) {
        // Capture must not proceed after a failed stream shutdown.
      } finally {
        await control.resume();
      }
      expect(captured, isFalse);
      expect(h.camera.value.isStreamingImages, isTrue);
    },
  );

  _sessionTest('disposal cancels retries and delayed startup', (
    tester,
    h,
  ) async {
    h.runner.startup = Completer<void>();
    await h.enable(true);
    final starting = h.session.setCamera(h.camera);
    await tester.pump();
    final disposal = h.session.dispose();
    h.runner.startup!.complete();
    await starting;
    await disposal;
    await tester.pump(const Duration(seconds: 10));
    expect(h.camera.starts, 0);
    expect(h.runner.disposed, isTrue);
    expect(h.detections, isEmpty);
    expect(h.replacements, 0);
  });
}
