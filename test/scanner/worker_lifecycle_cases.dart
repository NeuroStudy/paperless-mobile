import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';

void registerWorkerLifecycleTests() {
  test('closing before worker startup releases a waiting detection', () async {
    final runner = EdgeDetectionRunner();
    final pending = runner.detect(
      rgbaBytes: Uint8List(16 * 16),
      width: 16,
      height: 16,
      rotationCompensation: 0,
      channels: 1,
    );
    runner.dispose();
    runner.dispose();
    await runner.start();
    expect(await pending.timeout(const Duration(seconds: 5)), isNull);
  });

  test(
    'closing during worker startup releases the isolate and pending work',
    () async {
      final runner = EdgeDetectionRunner();
      final starting = runner.start();
      expect(identical(runner.start(), starting), isTrue);
      runner.dispose();
      await starting.timeout(const Duration(seconds: 5));
      expect(
        await runner.detect(
          rgbaBytes: Uint8List(0),
          width: 0,
          height: 0,
          rotationCompensation: 0,
        ),
        isNull,
      );
    },
  );

  test(
    'closing during detection cancels its reply instead of waiting forever',
    () async {
      final runner = EdgeDetectionRunner();
      await runner.start();
      final pending = runner.detect(
        rgbaBytes: Uint8List(1600 * 1200),
        width: 1600,
        height: 1200,
        rotationCompensation: 0,
        channels: 1,
      );
      // The detector has submitted its frame but the worker cannot have replied
      // until the next event turn. Dispose at that exact boundary.
      await Future<void>.microtask(() {});
      expect(runner.isProcessing, isTrue);
      runner.dispose();
      expect(await pending.timeout(const Duration(seconds: 5)), isNull);
      expect(runner.isProcessing, isFalse);
    },
  );
}
