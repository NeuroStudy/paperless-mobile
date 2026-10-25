import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/scanner/models/debug_stage.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/processing/detect_edges.dart';
import 'package:paperless_mobile/features/scanner/processing/edge_detection_isolate.dart';

/// Lets capture await stream shutdown before calling takePicture.
class ScannerDetectionController {
  ScannerDetectionSession? _session;
  bool _paused = false;

  void attach(ScannerDetectionSession session) {
    _session = session;
    unawaited(session.setPaused(_paused));
  }

  void detach(ScannerDetectionSession session) {
    if (identical(_session, session)) _session = null;
  }

  Future<void> pause() async {
    _paused = true;
    await _session?.setPaused(true);
  }

  Future<void> resume() async {
    _paused = false;
    await _session?.setPaused(false);
  }
}

/// Serializes camera stream transitions and supervises detector health.
/// No-document results are successful work and never cause recovery.
class ScannerDetectionSession {
  final EdgeDetectionRunner runner;
  final void Function(DocumentFrame?, ui.Size, ui.Image?) onDetection;
  final VoidCallback onReset;
  final Future<void> Function() restartCamera;
  final Duration streamTimeout;
  final List<Duration> retryDelays;

  ScannerDetectionSession({
    required this.onDetection,
    required this.onReset,
    required this.restartCamera,
    EdgeDetectionRunner? runner,
    this.streamTimeout = const Duration(seconds: 3),
    this.retryDelays = const [
      Duration(milliseconds: 250),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ],
  }) : runner = runner ?? EdgeDetectionRunner();

  CameraController? _camera;
  CameraController? _streamCamera;
  Future<void> _transition = Future.value();
  Timer? _watchdog;
  Timer? _retry;
  bool _enabled = false;
  bool _paused = false;
  bool _disposed = false;
  bool _processing = false;
  bool _restartStream = false;
  bool _streamRestarted = false;
  int _generation = 0;
  int _failures = 0;
  DebugStage _debugStage = DebugStage.none;
  EdgeDetectionConfig _config = EdgeDetectionConfig.fast;

  bool get _shouldRun =>
      !_disposed &&
      _enabled &&
      !_paused &&
      (_camera?.value.isInitialized ?? false);

  Future<void> setCamera(CameraController? camera) {
    if (identical(camera, _camera)) return _transition;
    _invalidate();
    _camera = camera;
    _streamRestarted = false;
    return _queue();
  }

  Future<void> configure({
    required bool enabled,
    required DebugStage debugStage,
    required EdgeDetectionConfig config,
  }) {
    if (_enabled == enabled && _debugStage == debugStage && _config == config) {
      return _transition;
    }
    _invalidate();
    _enabled = enabled;
    _debugStage = debugStage;
    _config = config;
    _restartStream = true;
    return _queue();
  }

  Future<void> setPaused(bool paused) {
    if (_paused == paused) return _transition;
    _invalidate();
    _paused = paused;
    _restartStream = true;
    return _queue(propagateError: paused);
  }

  void _invalidate() {
    _generation++;
    _watchdog?.cancel();
    _retry?.cancel();
    _retry = null;
    runner.reset();
    onReset();
  }

  Future<void> _queue({bool propagateError = false}) {
    final operation = _transition.then((_) => _reconcile());
    _transition = operation.catchError((Object error, StackTrace stack) {
      _failed(error);
    });
    return propagateError ? operation : _transition;
  }

  Future<void> _reconcile() async {
    final streamCamera = _streamCamera;
    if (streamCamera != null &&
        (!_shouldRun ||
            !identical(streamCamera, _camera) ||
            _restartStream ||
            !streamCamera.value.isStreamingImages)) {
      _streamCamera = null;
      if (streamCamera.value.isStreamingImages) {
        await streamCamera.stopImageStream().timeout(streamTimeout);
      }
    }
    if (!_shouldRun || _retry != null) return;
    if (identical(_streamCamera, _camera) && !_restartStream) return;
    _restartStream = false;
    final camera = _camera!;
    final generation = _generation;
    if (_debugStage == DebugStage.none) await runner.start();
    if (!_isCurrent(camera, generation)) return;
    _streamCamera = camera;
    _armWatchdog();
    await camera
        .startImageStream((image) {
          if (!_isCurrent(camera, generation)) return;
          _streamRestarted = false;
          _armWatchdog();
          if (_processing || _retry != null) return;
          unawaited(_process(image, camera, generation));
        })
        .timeout(streamTimeout);
  }

  bool _isCurrent(CameraController camera, int generation) =>
      _shouldRun && generation == _generation && identical(camera, _camera);

  Future<void> _process(
    CameraImage image,
    CameraController camera,
    int generation,
  ) async {
    _processing = true;
    try {
      if (_debugStage != DebugStage.none) {
        final result = await processImage(
          image,
          camera.description.sensorOrientation,
          camera.value.deviceOrientation,
          camera.description.lensDirection,
          debugStage: _debugStage,
          config: _config,
        );
        if (!_isCurrent(camera, generation)) {
          result?.$3?.dispose();
          return;
        }
        if (result == null) {
          throw const FormatException('Unsupported camera image');
        }
        _failures = 0;
        onDetection(result.$1, result.$2, result.$3);
      } else {
        final prepared = prepareCameraImage(
          image,
          camera.description.sensorOrientation,
          camera.value.deviceOrientation,
          camera.description.lensDirection,
        );
        if (prepared == null) {
          throw const FormatException('Unsupported camera image');
        }
        final outcome = await runner.detect(
          rgbaBytes: prepared.bytes,
          width: prepared.width,
          height: prepared.height,
          rotationCompensation: prepared.rotation,
          edgeDetectionConfig: _config,
        );
        if (!_isCurrent(camera, generation) || outcome == null) return;
        switch (outcome) {
          case FrameDetected(:final frame, :final imageSize):
            _failures = 0;
            onDetection(frame, imageSize, null);
          case FrameNotFound():
            _failures = 0;
            onDetection(
              null,
              ui.Size(prepared.width.toDouble(), prepared.height.toDouble()),
              null,
            );
          case DetectionFailed(:final reason):
            _failed(reason);
        }
      }
    } catch (error) {
      if (_isCurrent(camera, generation)) _failed(error);
    } finally {
      _processing = false;
    }
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(streamTimeout, () {
      if (!_shouldRun) return;
      final recreateCamera = _streamRestarted;
      _invalidate();
      _streamRestarted = true;
      _restartStream = true;
      if (recreateCamera) {
        // Do not await camera replacement from inside the transition queue:
        // replacement itself awaits setCamera(null) to finish stream shutdown.
        unawaited(restartCamera().catchError((Object error) => _failed(error)));
      } else {
        unawaited(_queue());
      }
    });
  }

  void _failed(Object error) {
    if (!_shouldRun || _retry != null) return;
    debugPrint('Scanner detection recovery: $error');
    runner.reset();
    onReset();
    final index = _failures.clamp(0, retryDelays.length - 1);
    _failures++;
    _retry = Timer(retryDelays[index], () {
      _retry = null;
      if (_shouldRun) {
        unawaited(_queue());
      }
    });
  }

  Future<void> dispose() {
    if (_disposed) return _transition;
    _disposed = true;
    _invalidate();
    runner.dispose();
    return _queue();
  }
}
