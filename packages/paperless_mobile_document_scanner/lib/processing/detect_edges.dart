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

/// Extracts RGBA bytes and rotation compensation from a [CameraImage].
/// Returns null if the format is unsupported or rotation cannot be computed.
({Uint8List bytes, int width, int height, int rotation})? prepareCameraImage(
  CameraImage image,
  int? sensorOrientation,
  DeviceOrientation deviceOrientation,
  CameraLensDirection lensDirection,
) {
  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  if (format == null) return null;

  final bytes = switch (format) {
    InputImageFormat.yuv_420_888 => yuv420ToRGBA8888(image),
    InputImageFormat.nv21 => nv21ToRGBA8888(image),
    InputImageFormat.bgra8888 => bgraToRgbaInPlace(image.planes.first.bytes),
    _ => throw UnimplementedError(),
  };

  final rotation = computeRotationCompensation(
    sensorOrientation,
    deviceOrientation,
    lensDirection,
  );
  if (rotation == null) return null;

  return (
    bytes: bytes,
    width: image.width,
    height: image.height,
    rotation: rotation,
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
  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  if (format == null) return;

  final bytes = switch (format) {
    InputImageFormat.yuv_420_888 => yuv420ToRGBA8888(image),
    InputImageFormat.nv21 => nv21ToRGBA8888(image),
    InputImageFormat.bgra8888 => bgraToRgbaInPlace(image.planes.first.bytes),
    _ => throw UnimplementedError(),
  };

  cv4.Mat mat = cv4.Mat.fromList(
    image.height,
    image.width,
    cv4.MatType.CV_8UC4,
    bytes,
  );

  final rotationCompensation = computeRotationCompensation(
    sensorOrientation,
    deviceOrientation,
    lensDirection,
  );
  if (rotationCompensation == null) return;

  switch (rotationCompensation) {
    case 90:
      await cv4.rotateAsync(mat, cv4.ROTATE_90_CLOCKWISE, dst: mat);
      break;
    case 180:
      await cv4.rotateAsync(mat, cv4.ROTATE_180, dst: mat);
      break;
    case 270:
      await cv4.rotateAsync(mat, cv4.ROTATE_90_COUNTERCLOCKWISE, dst: mat);
      break;
    default:
      // no rotation needed
      break;
  }

  final (frame, debugImage) = await detectDocumentEdges(
    mat,
    debugStage: debugStage,
  );
  final imageSize = Size(mat.cols.toDouble(), mat.rows.toDouble());
  mat.dispose();
  if (frame != null) {
    onFrameDetected(frame, imageSize, debugImage);
  }
}

/// Shared recognition for the camera isolate and captured images.
Future<(DocumentFrame?, ui.Image?)> detectDocumentEdges(
  cv4.Mat mat, {
  EdgeDetectionConfig config = EdgeDetectionConfig.fast,
  DebugStage debugStage = DebugStage.none,
}) => detectRankedDocument(mat, config, debugStage);
