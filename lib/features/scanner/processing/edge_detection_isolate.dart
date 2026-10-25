import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/processing/detect_edges.dart';

sealed class DetectionOutcome {}

class FrameDetected extends DetectionOutcome {
  final DocumentFrame frame;
  final Size imageSize;
  FrameDetected(this.frame, this.imageSize);
}

/// A successfully processed image without a document is not a worker failure.
class FrameNotFound extends DetectionOutcome {}

class DetectionFailed extends DetectionOutcome {
  final String reason;
  DetectionFailed(this.reason);
}

/// A restartable worker with one in-flight frame, including during startup.
class EdgeDetectionRunner {
  final Duration startupTimeout;
  final Duration requestTimeout;
  final void Function(SendPort) _entryPoint;

  EdgeDetectionRunner({
    this.startupTimeout = const Duration(seconds: 5),
    this.requestTimeout = const Duration(seconds: 3),
    // Injectable workers let tests exercise crashes and missing replies.
    void Function(SendPort)? workerEntryPoint,
  }) : _entryPoint = workerEntryPoint ?? _workerEntryPoint;

  Isolate? _isolate;
  SendPort? _workerSendPort;
  Future<void>? _starting;
  Completer<SendPort?>? _ready;
  Completer<Object?>? _pending;
  final Set<ReceivePort> _ports = {};
  bool _isProcessing = false;
  bool _disposed = false;
  int _generation = 0;

  bool get isProcessing => _isProcessing;

  Future<void> start() {
    if (_disposed) return Future.error(StateError('Detector is disposed'));
    if (_workerSendPort != null) return Future.value();
    return _starting ??= _startWorker();
  }

  Future<void> _startWorker() async {
    final generation = ++_generation;
    final ready = _ready = Completer<SendPort?>();
    final handshake = _port();
    final errors = _port();
    final exits = _port();
    handshake.listen((message) {
      if (generation == _generation && !ready.isCompleted) {
        ready.complete(message as SendPort);
      }
    });
    errors.listen((message) {
      if (generation == _generation) _failWorker('Worker error: $message');
    });
    exits.listen((_) {
      if (generation == _generation) _failWorker('Worker exited');
    });

    try {
      final port = await (() async {
        final isolate = await Isolate.spawn(
          _entryPoint,
          handshake.sendPort,
          onError: errors.sendPort,
          onExit: exits.sendPort,
          errorsAreFatal: true,
        );
        if (_disposed || generation != _generation) {
          isolate.kill(priority: Isolate.immediate);
          return null;
        }
        _isolate = isolate;
        return ready.future;
      })().timeout(startupTimeout);
      if (port == null || generation != _generation || _disposed) {
        throw StateError('Detector startup cancelled or worker exited');
      }
      _workerSendPort = port;
    } catch (error) {
      if (generation == _generation) _failWorker(error.toString());
      rethrow;
    } finally {
      _close(handshake);
      if (identical(_ready, ready)) _ready = null;
      _starting = null;
    }
  }

  /// Returns null only when a frame is skipped or the runner is disposed.
  Future<DetectionOutcome?> detect({
    required Uint8List rgbaBytes,
    required int width,
    required int height,
    required int rotationCompensation,
    required EdgeDetectionConfig edgeDetectionConfig,
  }) async {
    if (_disposed || _isProcessing) return null;
    // Reserve before the first await: camera frames can arrive before readiness.
    _isProcessing = true;
    ReceivePort? replyPort;
    Completer<Object?>? pending;
    try {
      await start();
      if (_disposed) return null;
      replyPort = _port();
      final response = pending = _pending = Completer<Object?>();
      replyPort.listen((message) {
        if (!response.isCompleted) response.complete(message);
      });
      _workerSendPort!.send([
        rgbaBytes,
        width,
        height,
        rotationCompensation,
        replyPort.sendPort,
        edgeDetectionConfig,
      ]);
      final result = await response.future.timeout(requestTimeout);
      if (_disposed) return null;
      if (result is DetectionFailed) {
        _failWorker(result.reason);
        return result;
      }
      if (result == null) return FrameNotFound();
      final data = (result as List).cast<double>();
      if (data.length != 10 || data.any((value) => !value.isFinite)) {
        throw const FormatException('Invalid detector reply');
      }
      return FrameDetected(
        DocumentFrame(
          topLeft: Offset(data[2], data[3]),
          topRight: Offset(data[4], data[5]),
          bottomRight: Offset(data[6], data[7]),
          bottomLeft: Offset(data[8], data[9]),
        ),
        Size(data[0], data[1]),
      );
    } catch (error) {
      if (_disposed) return null;
      _failWorker(error.toString());
      return DetectionFailed(error.toString());
    } finally {
      if (replyPort != null) _close(replyPort);
      if (identical(_pending, pending)) _pending = null;
      _isProcessing = false;
    }
  }

  ReceivePort _port() {
    final port = ReceivePort();
    _ports.add(port);
    return port;
  }

  void _close(ReceivePort port) {
    port.close();
    _ports.remove(port);
  }

  void _failWorker(String reason) {
    _generation++;
    _workerSendPort = null;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete(null);
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(DetectionFailed(reason));
    }
    for (final port in _ports.toList()) {
      _close(port);
    }
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  /// Cancels old work; the next start/detect call creates a fresh worker.
  void reset() => _failWorker('Detection cancelled');

  void dispose() {
    _disposed = true;
    reset();
  }

  static void _workerEntryPoint(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);
    workerReceivePort.listen((message) async {
      final msg = message as List;
      final replyPort = msg[4] as SendPort;
      try {
        replyPort.send(
          await _processFrame(
            msg[0] as Uint8List,
            msg[1] as int,
            msg[2] as int,
            msg[3] as int,
            msg[5] as EdgeDetectionConfig,
          ),
        );
      } catch (error) {
        replyPort.send(DetectionFailed(error.toString()));
      }
    });
  }

  static Future<List<double>?> _processFrame(
    Uint8List rgbaBytes,
    int width,
    int height,
    int rotationCompensation,
    EdgeDetectionConfig config,
  ) async {
    if (width <= 0 || height <= 0 || rgbaBytes.length != width * height * 4) {
      throw const FormatException('Invalid RGBA image dimensions');
    }
    final mat = cv4.Mat.fromList(height, width, cv4.MatType.CV_8UC4, rgbaBytes);
    try {
      switch (rotationCompensation) {
        case 90:
          await cv4.rotateAsync(mat, cv4.ROTATE_90_CLOCKWISE, dst: mat);
        case 180:
          await cv4.rotateAsync(mat, cv4.ROTATE_180, dst: mat);
        case 270:
          await cv4.rotateAsync(mat, cv4.ROTATE_90_COUNTERCLOCKWISE, dst: mat);
      }
      final (frame, debug) = await detectDocumentEdges(mat, config: config);
      debug?.dispose();
      if (frame == null) return null;
      return [
        mat.cols.toDouble(),
        mat.rows.toDouble(),
        frame.topLeft.dx,
        frame.topLeft.dy,
        frame.topRight.dx,
        frame.topRight.dy,
        frame.bottomRight.dx,
        frame.bottomRight.dy,
        frame.bottomLeft.dx,
        frame.bottomLeft.dy,
      ];
    } finally {
      mat.dispose();
    }
  }
}
