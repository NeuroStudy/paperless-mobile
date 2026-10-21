import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:paperless_mobile/features/scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile/features/scanner/view/document_scanner_view.dart';

import '../test/scanner/processing_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerProcessingTests();
  testWidgets(
    'live camera initializes, streams and captures a decodable image',
    (tester) async {
      final cameras = await availableCameras();
      expect(cameras, isNotEmpty);
      CameraController? controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentScannerView(
              camera: cameras.firstWhere(
                (c) => c.lensDirection == CameraLensDirection.back,
              ),
              resolutionPreset: ResolutionPreset.medium,
              onControllerInitialized: (value) => controller = value,
              liveEdgeDetectionEnabled: true,
              autoCaptureConfig: const AutoCaptureConfig.disabled(),
              onAutoCaptureTriggered: (_) {},
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 150 && (controller == null || !controller!.value.isStreamingImages);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller?.value.isInitialized, isTrue);
      expect(controller?.value.isStreamingImages, isTrue);
      await tester.pump(const Duration(seconds: 2));
      final capture = await controller!.takePicture();
      final file = File(capture.path);
      try {
        expect(await file.length(), greaterThan(0));
        final decoded = await decodeImageFromList(await file.readAsBytes());
        expect(decoded.width, greaterThan(1));
        expect(decoded.height, greaterThan(1));
        decoded.dispose();
      } finally {
        await file.delete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    },
  );
}
