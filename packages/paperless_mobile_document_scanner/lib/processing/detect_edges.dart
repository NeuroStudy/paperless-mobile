import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile_document_scanner/models/debug_stage.dart';
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile_document_scanner/models/input_image.dart';
import 'package:paperless_mobile_document_scanner/utils/utils.dart';
import 'package:paperless_mobile_document_scanner/processing/ranked_document_detector.dart';

final _orientations = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Computes the rotation compensation needed based on device and sensor
/// orientation. Returns null if inputs are insufficient.
int? computeRotationCompensation(
  int? sensorOrientation,
  DeviceOrientation deviceOrientation,
  CameraLensDirection lensDirection,
) {
  var rotationCompensation = _orientations[deviceOrientation];
  if (rotationCompensation == null || sensorOrientation == null) return null;
  if (lensDirection == CameraLensDirection.front) {
    rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
  } else {
    rotationCompensation =
        (sensorOrientation - rotationCompensation + 360) % 360;
  }
  return rotationCompensation;
}

/// Copies only luminance pixels, respecting camera row and pixel strides.
/// Chroma and row padding must never become document edges.
Uint8List? copyCameraLuma(
  Uint8List source, {
  required int width,
  required int height,
  required int bytesPerRow,
  int bytesPerPixel = 1,
}) {
  if (width <= 0 ||
      height <= 0 ||
      bytesPerPixel <= 0 ||
      bytesPerRow < (width - 1) * bytesPerPixel + 1 ||
      source.length <
          (height - 1) * bytesPerRow + (width - 1) * bytesPerPixel + 1) {
    return null;
  }
  final output = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    final row = y * bytesPerRow;
    if (bytesPerPixel == 1) {
      output.setRange(y * width, (y + 1) * width, source, row);
    } else {
      for (var x = 0; x < width; x++) {
        output[y * width + x] = source[row + x * bytesPerPixel];
      }
    }
  }
  return output;
}

/// Prepares analysis pixels without changing camera capture settings.
/// Android YUV frames use their luminance plane, as in the native recognizer.
/// BGRA frames retain the existing conversion path.
({Uint8List bytes, int width, int height, int rotation, int channels})?
prepareCameraImage(
  CameraImage image,
  int? sensorOrientation,
  DeviceOrientation deviceOrientation,
  CameraLensDirection lensDirection,
) {
  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  final rotation = computeRotationCompensation(
    sensorOrientation,
    deviceOrientation,
    lensDirection,
  );
  if (format == null || rotation == null || image.planes.isEmpty) return null;
  final plane = image.planes.first;
  final Uint8List? bytes;
  final int channels;
  switch (format) {
    case InputImageFormat.yuv_420_888:
    case InputImageFormat.nv21:
    case InputImageFormat.yuv420:
      bytes = copyCameraLuma(
        plane.bytes,
        width: image.width,
        height: image.height,
        bytesPerRow: plane.bytesPerRow,
        bytesPerPixel: plane.bytesPerPixel ?? 1,
      );
      channels = 1;
    case InputImageFormat.bgra8888:
      bytes = bgraToRgbaInPlace(plane.bytes);
      channels = 4;
    default:
      return null;
  }
  if (bytes == null) return null;
  return (
    bytes: bytes,
    width: image.width,
    height: image.height,
    rotation: rotation,
    channels: channels,
  );
}

void processImage(
  CameraImage image,
  int? sensorOrientation,
  DeviceOrientation deviceOrientation,
  CameraLensDirection lensDirection,
  void Function(DocumentFrame frame, Size imageSize, ui.Image? debugImage)
  onFrameDetected, {
  DebugStage debugStage = DebugStage.none,
}) async {
  final prepared = prepareCameraImage(
    image,
    sensorOrientation,
    deviceOrientation,
    lensDirection,
  );
  if (prepared == null) return;
  final mat = cv4.Mat.fromList(
    prepared.height,
    prepared.width,
    prepared.channels == 1 ? cv4.MatType.CV_8UC1 : cv4.MatType.CV_8UC4,
    prepared.bytes,
  );
  try {
    switch (prepared.rotation) {
      case 90:
        await cv4.rotateAsync(mat, cv4.ROTATE_90_CLOCKWISE, dst: mat);
      case 180:
        await cv4.rotateAsync(mat, cv4.ROTATE_180, dst: mat);
      case 270:
        await cv4.rotateAsync(mat, cv4.ROTATE_90_COUNTERCLOCKWISE, dst: mat);
    }
    final (frame, debugImage) = await detectDocumentEdges(
      mat,
      debugStage: debugStage,
    );
    if (frame == null) {
      debugImage?.dispose();
    } else {
      onFrameDetected(
        frame,
        Size(mat.cols.toDouble(), mat.rows.toDouble()),
        debugImage,
      );
    }
  } finally {
    mat.dispose();
  }
}

/// Shared recognition for the camera isolate and captured images.
Future<(DocumentFrame?, ui.Image?)> detectDocumentEdges(
  cv4.Mat mat, {
  EdgeDetectionConfig config = EdgeDetectionConfig.fourPoint,
  DebugStage debugStage = DebugStage.none,
  List<ui.Offset>? previousCorners,
}) => detectRankedDocument(
  mat,
  config,
  debugStage,
  previousCorners: previousCorners,
);
