import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/processing/detect_edges.dart';

import 'camera_test_support.dart';

void main() {
  test('BGRA padding is omitted from the RGBA image', () {
    final image = testCameraImage(
      width: 1,
      height: 2,
      planes: [
        {
          'bytes': Uint8List.fromList([
            1,
            2,
            3,
            255,
            99,
            99,
            99,
            99,
            4,
            5,
            6,
            255,
          ]),
          'bytesPerRow': 8,
        },
      ],
    );
    final result = prepareCameraImage(
      image,
      0,
      DeviceOrientation.portraitUp,
      CameraLensDirection.back,
    );
    expect(result!.bytes, [3, 2, 1, 255, 6, 5, 4, 255]);
  });

  test('YUV planes honor independent strides and optional pixel stride', () {
    final image = testCameraImage(
      format: 35,
      width: 2,
      height: 4,
      planes: [
        {
          'bytes': Uint8List.fromList([
            90,
            90,
            0,
            0,
            90,
            90,
            0,
            0,
            90,
            90,
            0,
            0,
            90,
            90,
          ]),
          'bytesPerRow': 4,
        },
        {
          'bytes': Uint8List.fromList([128, 0, 0, 128]),
          'bytesPerRow': 3,
        },
        {
          'bytes': Uint8List.fromList([128, 0, 0, 0, 0, 128]),
          'bytesPerRow': 5,
        },
      ],
    );
    final result = prepareCameraImage(
      image,
      0,
      DeviceOrientation.portraitUp,
      CameraLensDirection.back,
    );
    expect(result!.bytes, [
      for (var i = 0; i < 8; i++) ...[90, 90, 90, 255],
    ]);
  });

  test('packed NV21 is accepted when CameraX reports YUV420', () {
    final bytes = Uint8List.fromList([90, 90, 90, 90, 128, 128]);
    for (final format in [17, 35]) {
      final image = testCameraImage(
        format: format,
        planes: [
          {'bytes': bytes, 'bytesPerRow': 2, 'bytesPerPixel': 1},
        ],
      );
      final result = prepareCameraImage(
        image,
        90,
        DeviceOrientation.portraitUp,
        CameraLensDirection.back,
      );
      expect(result!.rotation, 90);
      expect(result.bytes, [
        for (var i = 0; i < 4; i++) ...[90, 90, 90, 255],
      ]);
    }
  });
}
