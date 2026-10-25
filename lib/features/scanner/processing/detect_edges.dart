import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile/features/scanner/models/debug_stage.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/models/input_image.dart';
import 'package:paperless_mobile/features/scanner/utils/utils.dart';
import 'ranked_document_detector.dart';

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
  if (format == null ||
      image.width <= 0 ||
      image.height <= 0 ||
      image.planes.isEmpty) {
    return null;
  }

  final bytes = switch (format) {
    InputImageFormat.yuv_420_888 =>
      image.planes.length == 1
          ? nv21ToRGBA8888(image)
          : yuv420ToRGBA8888(image),
    InputImageFormat.nv21 => nv21ToRGBA8888(image),
    InputImageFormat.bgra8888 => bgraImageToRGBA8888(image),
    _ => null,
  };

  if (bytes == null) return null;

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

/// Debug processing uses the same conversion, rotation and configuration as live detection.
Future<(DocumentFrame?, Size, ui.Image?)?> processImage(
  CameraImage image,
  int? sensorOrientation,
  DeviceOrientation deviceOrientation,
  CameraLensDirection lensDirection, {
  DebugStage debugStage = DebugStage.none,
  EdgeDetectionConfig config = EdgeDetectionConfig.fast,
}) async {
  final prepared = prepareCameraImage(
    image,
    sensorOrientation,
    deviceOrientation,
    lensDirection,
  );
  if (prepared == null) return null;
  final mat = cv4.Mat.fromList(
    prepared.height,
    prepared.width,
    cv4.MatType.CV_8UC4,
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
      config: config,
      debugStage: debugStage,
    );
    return (frame, Size(mat.cols.toDouble(), mat.rows.toDouble()), debugImage);
  } finally {
    mat.dispose();
  }
}

/// Shared recognition for the camera isolate and captured/imported images.
Future<(DocumentFrame?, ui.Image?)> detectDocumentEdges(
  cv4.Mat mat, {
  EdgeDetectionConfig config = EdgeDetectionConfig.fast,
  DebugStage debugStage = DebugStage.none,
}) => detectRankedDocument(mat, config, debugStage);
