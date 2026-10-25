import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/processing/edge_detection_isolate.dart';

void _delayedWorker(SendPort main) async {
  await Future<void>.delayed(const Duration(milliseconds: 60));
  _respondingWorker(main);
}

void _respondingWorker(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);
  port.listen((dynamic message) {
    final request = message as List;
    // Zero deliberately hangs this request; subsequent requests may succeed
    // after the runner replaces the worker.
    if ((request[0] as Uint8List).first != 0) {
      (request[4] as SendPort).send(null);
    }
  });
}

void _noHandshake(SendPort main) => ReceivePort().listen((_) {});
void _exitBeforeReady(SendPort main) {}
void _crashBeforeReady(SendPort main) => throw StateError('startup crash');

void _exitOnRequest(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);
  port.listen((_) => Isolate.exit());
}

void _crashOnRequest(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);
  port.listen((_) => throw StateError('processing crash'));
}

Future<DetectionOutcome?> _detect(
  EdgeDetectionRunner runner, {
  int value = 1,
}) => runner.detect(
  rgbaBytes: Uint8List.fromList([value, value, value, 255]),
  width: 1,
  height: 1,
  rotationCompensation: 0,
  edgeDetectionConfig: EdgeDetectionConfig.fast,
);

void main() {
  test(
    'startup is shared and early camera frames are skipped without queuing',
    () async {
      final runner = EdgeDetectionRunner(workerEntryPoint: _delayedWorker);
      addTearDown(runner.dispose);
      final starting = runner.start();
      expect(identical(starting, runner.start()), isTrue);
      final first = _detect(runner);
      expect(runner.isProcessing, isTrue);
      expect(await _detect(runner), isNull);
      await starting;
      expect(await first, isA<FrameNotFound>());
      expect(runner.isProcessing, isFalse);
      expect(await _detect(runner), isA<FrameNotFound>());
    },
  );

  test(
    'missing readiness, startup exit and startup error all finish',
    () async {
      for (final entry in [_noHandshake, _exitBeforeReady, _crashBeforeReady]) {
        final runner = EdgeDetectionRunner(
          workerEntryPoint: entry,
          startupTimeout: const Duration(milliseconds: 150),
        );
        try {
          expect(await _detect(runner), isA<DetectionFailed>());
          expect(runner.isProcessing, isFalse);
        } finally {
          runner.dispose();
        }
      }
    },
  );

  test(
    'a timed out request releases the slot and the next frame recovers',
    () async {
      final runner = EdgeDetectionRunner(
        workerEntryPoint: _respondingWorker,
        requestTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(runner.dispose);
      expect(await _detect(runner, value: 0), isA<DetectionFailed>());
      expect(runner.isProcessing, isFalse);
      expect(await _detect(runner), isA<FrameNotFound>());
    },
  );

  test('worker exit and error during a request release pending work', () async {
    for (final entry in [_exitOnRequest, _crashOnRequest]) {
      final runner = EdgeDetectionRunner(workerEntryPoint: entry);
      try {
        expect(await _detect(runner), isA<DetectionFailed>());
        expect(runner.isProcessing, isFalse);
      } finally {
        runner.dispose();
      }
    }
  });

  test(
    'reset cancels an outstanding request and permits a fresh worker',
    () async {
      final runner = EdgeDetectionRunner(workerEntryPoint: _respondingWorker);
      addTearDown(runner.dispose);
      await runner.start();
      final pending = _detect(runner, value: 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      runner.reset();
      expect(await pending, isA<DetectionFailed>());
      expect(await _detect(runner), isA<FrameNotFound>());
    },
  );

  test(
    'disposal cancels startup and pending requests without late results',
    () async {
      for (final entry in [_noHandshake, _respondingWorker]) {
        final runner = EdgeDetectionRunner(workerEntryPoint: entry);
        final pending = _detect(runner, value: 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        runner.dispose();
        expect(await pending, isNull);
        expect(runner.isProcessing, isFalse);
        expect(await _detect(runner), isNull);
      }
    },
  );
}
