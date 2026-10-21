import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'color_enhancement.dart';

/// Rotates [imageBytes] (PNG) by [quarterTurns] × 90° clockwise.
///
/// [quarterTurns] is normalised to 0–3. Returns the original bytes unchanged
/// when the effective rotation is 0°.
Future<Uint8List> rotateImage(Uint8List imageBytes, int quarterTurns) async {
  final effective = quarterTurns % 4;
  if (effective == 0) return imageBytes;

  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_UNCHANGED);

  late final cv4.Mat rotated;
  switch (effective) {
    case 1:
      rotated = cv4.rotate(mat, cv4.ROTATE_90_CLOCKWISE);
    case 2:
      rotated = cv4.rotate(mat, cv4.ROTATE_180);
    case 3:
      rotated = cv4.rotate(mat, cv4.ROTATE_90_COUNTERCLOCKWISE);
    default:
      rotated = mat;
  }

  final encoded = cv4.imencode('.png', rotated);
  mat.dispose();
  if (!identical(rotated, mat)) rotated.dispose();
  return encoded.$2;
}

/// Converts [imageBytes] (PNG) to greyscale and returns PNG bytes.
Future<Uint8List> toGrayscale(Uint8List imageBytes) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  final gray = cv4.cvtColor(mat, cv4.COLOR_BGR2GRAY);

  final encoded = cv4.imencode('.png', gray);
  mat.dispose();
  gray.dispose();
  return encoded.$2;
}

/// Converts [imageBytes] (PNG) to pure black-and-white using adaptive
/// thresholding and returns PNG bytes.
///
/// [constant] is the value subtracted from the mean in adaptive thresholding.
/// Higher values produce more black; lower values produce more white.
/// Typical range: 2–30, default 10.
Future<Uint8List> toBlackAndWhite(
  Uint8List imageBytes, {
  double constant = 10,
}) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  final gray = cv4.cvtColor(mat, cv4.COLOR_BGR2GRAY);

  // Adaptive threshold handles varying lighting across the document.
  final bw = cv4.adaptiveThreshold(
    gray,
    255,
    cv4.ADAPTIVE_THRESH_GAUSSIAN_C,
    cv4.THRESH_BINARY,
    15, // block size
    constant, // constant subtracted from the mean
  );

  final encoded = cv4.imencode('.png', bw);
  mat.dispose();
  gray.dispose();
  bw.dispose();
  return encoded.$2;
}

/// Optimized color correction; a crop profile can be reused across edits.
Future<Uint8List> autoEnhance(
  Uint8List imageBytes, {
  bool reduceShadows = true,
  EnhancementProfile? profile,
}) =>
    enhanceDocument(imageBytes, reduceShadows: reduceShadows, profile: profile);

/// Generates a thumbnail of [imageBytes] (PNG) with a maximum dimension of
/// [maxDimension] pixels (preserving the aspect ratio).
///
/// Returns the resized image as PNG-encoded bytes.
Future<Uint8List> generateThumbnail(
  Uint8List imageBytes, {
  int maxDimension = 200,
}) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  final w = mat.width;
  final h = mat.height;
  final maxDim = w > h ? w : h;

  if (maxDim <= maxDimension) {
    final encoded = cv4.imencode('.png', mat);
    mat.dispose();
    return encoded.$2;
  }

  final scale = maxDimension / maxDim;
  final newW = (w * scale).round();
  final newH = (h * scale).round();
  final resized = await cv4.resizeAsync(mat, (newW, newH));

  final encoded = cv4.imencode('.png', resized);
  mat.dispose();
  resized.dispose();
  return encoded.$2;
}
