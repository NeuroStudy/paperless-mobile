import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile_document_scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile_document_scanner/paperless_mobile_document_scanner.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';
import 'package:paperless_mobile_document_scanner/view/widgets/shutter_button.dart';

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue);
}

void registerCameraInputTest() {
  testWidgets(
    'real camera captures, edits, resumes and closes without lifecycle errors',
    (tester) async {
      // Exercise the production widgets: capture stops streaming before replacing
      // the preview, then discarding the edit creates a fresh live camera.
      await tester.pumpWidget(
        MaterialApp(
          home: PaperlessMobileDocumentScanner(
            autoCaptureConfig: const AutoCaptureConfig(enabled: false),
            onCancelled: (_) {},
            onDone: (_) {},
          ),
        ),
      );
      await _waitFor(
        tester,
        () => find.byType(CameraPreview).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<CameraPreview>(find.byType(CameraPreview))
            .controller
            .resolutionPreset,
        ResolutionPreset.ultraHigh,
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(ShutterButton));
      await _waitFor(
        tester,
        () => find.byType(ImageEditView).evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      final editor = tester.widget<ImageEditView>(find.byType(ImageEditView));
      final original = await decodeImageFromList(editor.originalImageBytes!);
      expect(
        editor.originalImageSize,
        Size(original.width.toDouble(), original.height.toDouble()),
      );
      debugPrint('4K target: captured ${original.width}x${original.height}');
      original.dispose();
      await _waitFor(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(find.text('Discard'));
      await _waitFor(
        tester,
        () => find.byType(CameraPreview).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 500));
      // This teardown happens with a live stream and background recognition.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real NV21 camera frames reach luminance recognition', (
    tester,
  ) async {
    final cameras = await availableCameras();
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    // Same capture settings as the production FocusableCameraView.
    final controller = CameraController(
      camera,
      ResolutionPreset.ultraHigh,
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
