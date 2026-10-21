import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';

void registerCameraInputTest() {
  testWidgets('real NV21 camera frames reach luminance recognition', (
    tester,
  ) async {
    final cameras = await availableCameras();
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    // Same capture settings as alpha2's FocusableCameraView.
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    final runner = EdgeDetectionRunner();
    try {
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      final received = Completer<CameraImage>();
      await controller.startImageStream((frame) {
        if (!received.isCompleted) received.complete(frame);
      });
      final frame = await received.future.timeout(const Duration(seconds: 15));
      await controller.stopImageStream();
      final prepared = prepareCameraImage(
        frame,
        camera.sensorOrientation,
        controller.value.deviceOrientation,
        camera.lensDirection,
      );
      expect(prepared, isNotNull);
      expect(prepared!.channels, 1);
      expect(prepared.bytes.length, frame.width * frame.height);
      await runner.start();
      final result = await runner.detect(
        rgbaBytes: prepared.bytes,
        width: prepared.width,
        height: prepared.height,
        rotationCompensation: prepared.rotation,
        channels: prepared.channels,
      );
      expect(result, isA<DetectionOutcome>());
      expect(controller.value.isInitialized, isTrue);
      expect(controller.value.hasError, isFalse);
    } finally {
      runner.dispose();
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }
  });
}
