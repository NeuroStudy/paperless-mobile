import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';

/// Applies a perspective (four-point) transform to [imageBytes] so that the
/// quadrilateral defined by [frame] is warped into an axis-aligned rectangle.
///
/// Recovers the rectangle's aspect ratio when the perspective geometry is
/// reliable; otherwise retains sizing based on the photographed edge lengths.
///
/// Returns the transformed image as PNG-encoded bytes.
Future<Uint8List> perspectiveTransform({
  required Uint8List imageBytes,
  required DocumentFrame frame,
}) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  final owned = <cv4.Mat>[mat];
  cv4.VecPoint2f? srcMat;
  cv4.VecPoint2f? dstMat;
  try {
    if (mat.isEmpty) {
      throw const FormatException('Failed to decode document image');
    }
    final points = [
      frame.topLeft,
      frame.topRight,
      frame.bottomRight,
      frame.bottomLeft,
    ];
    final (width, height) = _outputSize(points, mat.width, mat.height);
    srcMat = cv4.VecPoint2f.generate(
      4,
      (i) => cv4.Point2f(points[i].dx, points[i].dy),
    );
    final destination = [
      Offset.zero,
      Offset(width - 1.0, 0),
      Offset(width - 1.0, height - 1.0),
      Offset(0, height - 1.0),
    ];
    dstMat = cv4.VecPoint2f.generate(
      4,
      (i) => cv4.Point2f(destination[i].dx, destination[i].dy),
    );
    final transform = cv4.getPerspectiveTransform2f(srcMat, dstMat);
    owned.add(transform);
    final warped = await cv4.warpPerspectiveAsync(mat, transform, (
      width,
      height,
    ));
    owned.add(warped);
    final (success, encoded) = cv4.imencode('.png', warped);
    if (!success) {
      throw Exception('Failed to encode perspective-transformed image');
    }
    return encoded;
  } finally {
    for (final resource in owned.reversed) {
      resource.dispose();
    }
    srcMat?.dispose();
    dstMat?.dispose();
  }
}

(int, int) _outputSize(List<Offset> p, int imageWidth, int imageHeight) {
  final width = math
      .max((p[1] - p[0]).distance, (p[2] - p[3]).distance)
      .round();
  final height = math
      .max((p[3] - p[0]).distance, (p[2] - p[1]).distance)
      .round();
  final longest = math.max(width, height);
  final imageLongest = math.max(imageWidth, imageHeight).toDouble();
  final center = Offset(imageWidth / 2, imageHeight / 2);
  final normalized = p.map((point) => (point - center) / imageLongest).toList();
  final ratio = _stableAspectRatio(normalized, imageLongest);
  if (ratio == null) return (width, height);

  // Keep the existing resolution budget instead of growing an image to repair
  // foreshortening. Both axes must follow the same recovered rectangle ratio.
  final outputWidth = ratio >= 1 ? longest : (longest * ratio).round();
  final outputHeight = ratio >= 1 ? (longest / ratio).round() : longest;
  if (outputWidth < 2 || outputHeight < 2) return (width, height);
  return (outputWidth, outputHeight);
}

double? _stableAspectRatio(List<Offset> points, double imageLongest) {
  final ratio = _rectangleAspectRatio(points);
  if (ratio == null) return null;

  // The detector analyzes at up to 960px. Require the estimate to tolerate at
  // least one pixel of corner uncertainty at that resolution (or at full size
  // for smaller images), including corners adjusted by hand.
  final delta = math.max(1.0, imageLongest / 960) / imageLongest;
  for (var i = 0; i < points.length; i++) {
    for (final offset in [
      Offset(delta, 0),
      Offset(-delta, 0),
      Offset(0, delta),
      Offset(0, -delta),
    ]) {
      final perturbed = List<Offset>.of(points);
      perturbed[i] += offset;
      final candidate = _rectangleAspectRatio(perturbed);
      if (candidate == null || (candidate / ratio - 1).abs() > .02) {
        return null;
      }
    }
  }
  return ratio;
}

/// Metric rectification from a unit square to the photographed rectangle.
/// Assumes square pixels, no skew and the principal point at the image center.
/// Zhang & He, "Whiteboard scanning and image enhancement", sections 3.2–3.3:
/// https://www.microsoft.com/en-us/research/uploads/prod/2016/11/Digital-Signal-Processing.pdf
double? _rectangleAspectRatio(List<Offset> p) {
  // Only a finite, strictly convex quadrilateral can represent a rectangle.
  double? winding;
  for (var i = 0; i < 4; i++) {
    final a = p[(i + 1) % 4] - p[i];
    final b = p[(i + 2) % 4] - p[(i + 1) % 4];
    final cross = a.dx * b.dy - a.dy * b.dx;
    if (!cross.isFinite || cross.abs() < 1e-10) return null;
    if (winding != null && cross * winding < 0) return null;
    winding = cross;
  }

  // Closed-form homography from (0,0), (1,0), (1,1), (0,1) to p. Centering
  // and scaling image coordinates keeps this calculation in double precision
  // without allocating native matrices for the sixteen uncertainty probes.
  final d1 = p[1] - p[2];
  final d2 = p[3] - p[2];
  final d3 = p[0] - p[1] + p[2] - p[3];
  final determinant = d1.dx * d2.dy - d2.dx * d1.dy;
  if (determinant.abs() < 1e-10) return null;
  final g = (d3.dx * d2.dy - d2.dx * d3.dy) / determinant;
  final h = (d1.dx * d3.dy - d3.dx * d1.dy) / determinant;
  final a = p[1] * (1 + g) - p[0];
  final b = p[3] * (1 + h) - p[0];

  // The first two columns of K^-1 H are orthogonal page directions. Their
  // dot product gives f²; the ratio of their norms gives width / height.
  // Parallel/near-parallel sides can make f indeterminate: keep legacy sizing.
  final denominator = g * h;
  if (denominator.abs() < 1e-8) return null;
  final focalSquared = -(a.dx * b.dx + a.dy * b.dy) / denominator;
  // Normalized focal length must be between .5 and 5 image-longest edges.
  if (!focalSquared.isFinite || focalSquared < .25 || focalSquared > 25) {
    return null;
  }
  final ratio = math.sqrt(
    (a.distanceSquared + focalSquared * g * g) /
        (b.distanceSquared + focalSquared * h * h),
  );
  return ratio.isFinite && ratio > 0 ? ratio : null;
}
