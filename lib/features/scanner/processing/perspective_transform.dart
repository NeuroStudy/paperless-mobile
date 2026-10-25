import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';

/// Rectifies [frame] using pixel-center coordinates and returns PNG bytes.
/// Integer-aligned rectangles copy their pixels without interpolation.
Future<Uint8List> perspectiveTransform({
  required Uint8List imageBytes,
  required DocumentFrame frame,
}) async {
  final owned = <cv4.Mat>[];
  cv4.Mat own(cv4.Mat mat) {
    owned.add(mat);
    return mat;
  }

  cv4.VecPoint2f? srcPoints;
  cv4.VecPoint2f? dstPoints;
  try {
    final image = own(cv4.imdecode(imageBytes, cv4.IMREAD_COLOR));
    if (image.isEmpty) throw const FormatException('Cannot decode scan');
    final crop = frame.clampedToImage(
      Size(image.cols.toDouble(), image.rows.toDouble()),
    );
    final points = [
      crop.topLeft,
      crop.topRight,
      crop.bottomRight,
      crop.bottomLeft,
    ];

    // Snap only floating-point noise, never a fractional selection or tilt.
    const epsilon = 1e-6;
    final integers = points.every(
      (p) =>
          (p.dx - p.dx.round()).abs() <= epsilon &&
          (p.dy - p.dy.round()).abs() <= epsilon,
    );
    final corners = [
      for (final p in points)
        Offset(p.dx.roundToDouble(), p.dy.roundToDouble()),
    ];
    if (integers &&
        corners[0].dy == corners[1].dy &&
        corners[1].dx == corners[2].dx &&
        corners[2].dy == corners[3].dy &&
        corners[3].dx == corners[0].dx &&
        corners[0].dx <= corners[1].dx &&
        corners[0].dy <= corners[3].dy) {
      final rect = cv4.Rect(
        corners[0].dx.toInt(),
        corners[0].dy.toInt(),
        (corners[1].dx - corners[0].dx).toInt() + 1,
        (corners[3].dy - corners[0].dy).toInt() + 1,
      );
      try {
        return _encodePng(own(image.region(rect)));
      } finally {
        rect.dispose();
      }
    }

    // A pixel count includes both ends of the span between corner centers.
    final width =
        math
            .max(
              (crop.topRight - crop.topLeft).distance,
              (crop.bottomRight - crop.bottomLeft).distance,
            )
            .round() +
        1;
    final height =
        math
            .max(
              (crop.bottomLeft - crop.topLeft).distance,
              (crop.bottomRight - crop.topRight).distance,
            )
            .round() +
        1;
    if (width < 2 || height < 2 || !_isConvex(points)) {
      throw ArgumentError.value(
        frame,
        'frame',
        'Crop must be a convex quadrilateral',
      );
    }
    srcPoints = cv4.VecPoint2f.generate(
      4,
      (i) => cv4.Point2f(points[i].dx, points[i].dy),
    );
    final destination = [
      Offset.zero,
      Offset(width - 1.0, 0),
      Offset(width - 1.0, height - 1.0),
      Offset(0, height - 1.0),
    ];
    dstPoints = cv4.VecPoint2f.generate(
      4,
      (i) => cv4.Point2f(destination[i].dx, destination[i].dy),
    );
    final transform = own(cv4.getPerspectiveTransform2f(srcPoints, dstPoints));
    final warped = own(
      await cv4.warpPerspectiveAsync(image, transform, (
        width,
        height,
      ), flags: cv4.INTER_LINEAR),
    );
    return _encodePng(warped);
  } finally {
    dstPoints?.dispose();
    srcPoints?.dispose();
    for (final mat in owned.reversed) {
      mat.dispose();
    }
  }
}

Uint8List _encodePng(cv4.Mat image) {
  final (success, bytes) = cv4.imencode('.png', image);
  if (!success) throw const FormatException('Cannot encode cropped scan');
  return bytes;
}

bool _isConvex(List<Offset> points) {
  bool? positive;
  for (var i = 0; i < 4; i++) {
    final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cross.abs() <= 1e-6) return false;
    if (positive != null && positive != (cross > 0)) return false;
    positive = cross > 0;
  }
  return true;
}
