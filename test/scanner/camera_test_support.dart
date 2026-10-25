import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

const testCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 0,
);

CameraImage testCameraImage({
  int format = 1111970369,
  int width = 2,
  int height = 2,
  List<Map<String, Object?>>? planes,
}) {
  // The legacy constructor accepts raw fixtures without a platform plugin.
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'format': format,
    'width': width,
    'height': height,
    'planes':
        planes ??
        [
          {'bytes': Uint8List(width * height * 4), 'bytesPerRow': width * 4},
        ],
  });
}

class TestCameraController extends CameraController {
  TestCameraController({bool initialized = true})
    : super(testCamera, ResolutionPreset.medium, enableAudio: false) {
    value = value.copyWith(
      isInitialized: initialized,
      previewSize: const Size(2, 2),
    );
  }

  Completer<void>? initialization;
  Completer<void>? streamStart;
  Completer<void>? streamStop;
  bool failStart = false;
  bool failStop = false;
  bool failFlash = false;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  void Function(CameraImage)? callback;

  @override
  Future<void> initialize() async {
    await initialization?.future;
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    if (failFlash) throw CameraException('flashUnsupported', 'No flash');
    value = value.copyWith(flashMode: mode);
  }

  @override
  Future<void> startImageStream(void Function(CameraImage) onAvailable) async {
    starts++;
    if (failStart) {
      failStart = false;
      throw CameraException('startFailed', 'Transient start failure');
    }
    await streamStart?.future;
    if (value.isStreamingImages) throw StateError('Overlapping stream start');
    callback = onAvailable;
    value = value.copyWith(isStreamingImages: true);
  }

  @override
  Future<void> stopImageStream() async {
    stops++;
    value = value.copyWith(isStreamingImages: false);
    await streamStop?.future;
    if (failStop) {
      failStop = false;
      throw CameraException('stopFailed', 'Transient stop failure');
    }
  }

  void deliver() => callback?.call(testCameraImage());

  @override
  Widget buildPreview() => const SizedBox.expand();

  @override
  Future<void> dispose() async {
    disposals++;
    value = value.copyWith(isInitialized: false, isStreamingImages: false);
    // initialize() is overridden, so no platform resources were allocated.
    await super.dispose();
  }
}
