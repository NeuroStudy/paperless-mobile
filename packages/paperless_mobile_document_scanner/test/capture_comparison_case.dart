import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile_document_scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';

// Opt-in physical-device diagnostic. Keep the phone stationary over the same
// colored document for all six cases. Originals remain untouched on the device;
// the companion driver retrieves every artifact even if a later case fails.
void registerCaptureComparisonTest(
  ValueChanged<Map<String, dynamic>> onReport,
) {
  testWidgets(
    'capture resolution and analysis format comparison',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'scanner_capture_',
      );
      final cases = <Map<String, dynamic>>[];
      final report = <String, dynamic>{
        'directory': directory.path,
        'cases': cases,
        'note':
            'Visual comparison, not an automatic physical-camera quality pass.',
      };
      onReport(report);
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      report['camera'] = camera.name;
      for (final resolution in [
        ResolutionPreset.high,
        ResolutionPreset.veryHigh,
        ResolutionPreset.ultraHigh,
      ]) {
        for (final format in [ImageFormatGroup.nv21, ImageFormatGroup.yuv420]) {
          final name = '${resolution.name}_${format.name}';
          final entry = <String, dynamic>{
            'name': name,
            'requestedResolution': resolution.name,
            'analysisFormat': format.name,
            'files': <String>[],
          };
          cases.add(entry);
          final controller = CameraController(
            camera,
            resolution,
            enableAudio: false,
            imageFormatGroup: format,
          );
          var released = false;
          Future<void> save(String suffix, Uint8List bytes) async {
            final filename = '${name}_$suffix';
            await File('${directory.path}/$filename').writeAsBytes(bytes);
            (entry['files'] as List<String>).add(filename);
          }

          try {
            await controller.initialize();
            await controller.setFlashMode(FlashMode.off);
            await tester.pumpWidget(
              MaterialApp(home: CameraPreview(controller)),
            );
            final received = Completer<CameraImage>();
            await controller.startImageStream((frame) {
              if (!received.isCompleted) received.complete(frame);
            });
            final analysis = await received.future.timeout(
              const Duration(seconds: 20),
            );
            entry['analysisSize'] = [analysis.width, analysis.height];
            entry['analysisPlanes'] = [
              for (final plane in analysis.planes)
                {
                  'rowStride': plane.bytesPerRow,
                  'pixelStride': plane.bytesPerPixel,
                },
            ];
            // Give autofocus and exposure the same settling interval in each case.
            await tester.pump(const Duration(seconds: 2));
            await controller.stopImageStream();
            final capture = await controller.takePicture();
            final bytes = await capture.readAsBytes();
            await save('original.jpg', bytes);
            await tester.pumpWidget(const SizedBox.shrink());
            await controller.dispose();
            released = true;

            final decoded = await decodeImageFromList(bytes);
            final size = Size(
              decoded.width.toDouble(),
              decoded.height.toDouble(),
            );
            entry['capturedSize'] = [decoded.width, decoded.height];
            try {
              await save(
                'flutter.png',
                (await decoded.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!.buffer.asUint8List(),
              );
            } finally {
              decoded.dispose();
            }
            final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
            try {
              entry['opencvSize'] = [mat.cols, mat.rows];
              final encoded = cv.imencode('.png', mat);
              expect(encoded.$1, isTrue);
              await save('opencv.png', encoded.$2);
            } finally {
              mat.dispose();
            }
            final frame =
                await detectEdgesFromImageBytes(bytes) ??
                DocumentFrame(
                  topLeft: Offset.zero,
                  topRight: Offset(size.width - 1, 0),
                  bottomRight: Offset(size.width - 1, size.height - 1),
                  bottomLeft: Offset(0, size.height - 1),
                );
            entry['cropCorners'] = [
              for (final point in [
                frame.topLeft,
                frame.topRight,
                frame.bottomRight,
                frame.bottomLeft,
              ])
                [point.dx, point.dy],
            ];
            final cropped = await perspectiveTransform(
              imageBytes: bytes,
              frame: frame,
            );
            await save('perspective.png', cropped);
            for (final mode in [(false, true), (true, true), (true, false)]) {
              ImageEditResult? result;
              await tester.pumpWidget(
                MaterialApp(
                  home: ImageEditView(
                    key: UniqueKey(),
                    originalImageBytes: bytes,
                    originalImageSize: size,
                    initialCropFrame: frame,
                    initialCroppedBytes: cropped,
                    initialEnhanced: mode.$1,
                    initialReduceShadows: mode.$2,
                    isNewCapture: true,
                    onConfirmed: (value) => result = value,
                    onCancelled: () {},
                  ),
                ),
              );
              final deadline = DateTime.now().add(const Duration(seconds: 60));
              do {
                await tester.pump(const Duration(milliseconds: 100));
              } while (find
                      .byType(CircularProgressIndicator)
                      .evaluate()
                      .isNotEmpty &&
                  DateTime.now().isBefore(deadline));
              expect(find.byType(CircularProgressIndicator), findsNothing);
              final displayed =
                  (tester.widget<Image>(find.byType(Image)).image
                          as MemoryImage)
                      .bytes;
              await tester.tap(find.text('Apply'));
              expect(result, isNotNull);
              expect(result!.editedBytes, displayed);
              await save(
                'export_enhance-${mode.$1}_shadows-${mode.$2}.png',
                result!.editedBytes,
              );
            }
            entry['status'] = 'captured';
            debugPrint('$name: ${entry['capturedSize']}');
          } catch (error) {
            entry['error'] = error.toString();
            entry['status'] = 'failed';
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            if (!released) await controller.dispose();
            await File(
              '${directory.path}/report.json',
            ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
          }
        }
      }
      expect(cases.where((c) => c['status'] == 'failed'), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
