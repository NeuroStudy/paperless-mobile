import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:paperless_mobile/features/scanner/models/debug_stage.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/utils/utils.dart';

/// Stateless recognition: v5 owns smoothing, stability and auto capture.
Future<(DocumentFrame?, ui.Image?)> detectRankedDocument(
  cv.Mat input,
  EdgeDetectionConfig config,
  DebugStage debugStage,
) async {
  final owned = <cv.Mat>[];
  cv.Mat own(cv.Mat mat) {
    owned.add(mat);
    return mat;
  }

  try {
    if (input.isEmpty || input.cols < 3 || input.rows < 3) return (null, null);
    final gray = own(
      input.channels == 1
          ? input.clone()
          : cv.cvtColor(input, cv.COLOR_RGBA2GRAY),
    );
    final maxEdge = math.max(input.cols, input.rows);
    final scale = config.resizeThreshold > 0
        ? math.min(1.0, config.resizeThreshold / maxEdge)
        : 1.0;
    final w = math.max(3, (gray.cols * scale).round()),
        h = math.max(3, (gray.rows * scale).round());
    final resized = own(cv.resize(gray, (w, h), interpolation: cv.INTER_AREA));
    final border = config.borderSize;
    final padded = own(
      cv.copyMakeBorder(
        resized,
        border,
        border,
        border,
        border,
        cv.BORDER_CONSTANT,
        value: cv.Scalar.black,
      ),
    );
    final blurred = own(cv.medianBlur(padded, config.medianBlurKernel));
    final threshold = _gradientThreshold(blurred);
    final edges = own(
      cv.canny(blurred, math.max(8.0, threshold * .4), threshold),
    );
    final mask = own(
      cv.threshold(blurred, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU).$2,
    );
    final kernel = own(
      cv.getStructuringElement(cv.MORPH_RECT, (
        config.morphologyKernel,
        config.morphologyKernel,
      )),
    );
    final dilation = own(
      cv.getStructuringElement(cv.MORPH_RECT, (
        config.dilateKernel,
        config.dilateKernel,
      )),
    );
    final closedEdges = own(cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel));
    final proposals = [
      closedEdges,
      own(cv.morphologyEx(mask, cv.MORPH_CLOSE, kernel)),
    ];
    final edgePixels = edges.data;
    var bestScore = .52;
    List<ui.Offset>? best;
    final candidates = <List<ui.Offset>>[];
    for (final proposal in proposals) {
      final expanded = own(cv.dilate(proposal, dilation));
      final (contours, hierarchy) = cv.findContours(
        expanded,
        cv.RETR_LIST,
        cv.CHAIN_APPROX_SIMPLE,
      );
      try {
        final ranked = [
          for (var i = 0; i < contours.length; i++)
            (i, cv.contourArea(contours[i])),
        ]..sort((a, b) => b.$2.compareTo(a.$2));
        for (final candidate in ranked.take(30)) {
          final areaFraction = candidate.$2 / (w * h);
          if (areaFraction < config.minAreaFactor || areaFraction > .97) {
            continue;
          }
          final contour = contours[candidate.$1];
          final perimeter = cv.arcLength(contour, true);
          for (final epsilon in {config.approxEpsilonFactor, .025, .04}) {
            final approx = cv.approxPolyDP(contour, perimeter * epsilon, true);
            try {
              if (approx.length != 4) continue;
              final points = orderDocumentCorners([
                for (final point in approx)
                  ui.Offset(
                    (point.x - border) / (w - 1),
                    (point.y - border) / (h - 1),
                  ),
              ]);
              if (!isValidDocumentQuad(points)) continue;
              if (points
                      .where(
                        (p) =>
                            p.dx < .005 ||
                            p.dy < .005 ||
                            p.dx > .995 ||
                            p.dy > .995,
                      )
                      .length >
                  2) {
                continue;
              }
              final pixelPoints = [
                for (final p in points)
                  ui.Offset(p.dx * (w - 1) + border, p.dy * (h - 1) + border),
              ];
              final support = _boundarySupport(
                edgePixels,
                edges.cols,
                edges.rows,
                pixelPoints,
              );
              if (support < .35) continue;
              final area = documentQuadArea(points);
              final rectangularity =
                  math.min(areaFraction, area) / math.max(areaFraction, area);
              final score =
                  support * .50 +
                  rectangularity * .20 +
                  math.sqrt(area) * .20 +
                  .05;
              candidates.add(pixelPoints);
              if (score > bestScore) {
                bestScore = score;
                best = points;
              }
            } finally {
              approx.dispose();
            }
          }
        }
      } finally {
        hierarchy.dispose();
        contours.dispose();
      }
    }
    ui.Image? debug;
    if (debugStage != DebugStage.none) {
      final stage = switch (debugStage) {
        DebugStage.grayscale => padded,
        DebugStage.blurred => blurred,
        DebugStage.canny => edges,
        DebugStage.morphClosed => closedEdges,
        _ => null,
      };
      final canvas = own(
        stage != null
            ? cv.cvtColor(stage, cv.COLOR_GRAY2RGBA)
            : cv.Mat.zeros(padded.rows, padded.cols, cv.MatType.CV_8UC4),
      );
      if (stage == null) {
        for (final points in candidates) {
          for (var i = 0; i < 4; i++) {
            final a = points[i], b = points[(i + 1) % 4];
            final from = cv.Point(a.dx.round(), a.dy.round()),
                to = cv.Point(b.dx.round(), b.dy.round());
            final color = cv.Scalar(0, 255, 0, 255);
            try {
              cv.line(canvas, from, to, color);
            } finally {
              from.dispose();
              to.dispose();
              color.dispose();
            }
          }
        }
      }
      debug = await canvas.toUiImage();
    }
    if (best == null) return (null, debug);
    final points = [
      for (final p in best)
        ui.Offset(p.dx * (input.cols - 1), p.dy * (input.rows - 1)),
    ];
    return (
      DocumentFrame(
        topLeft: points[0],
        topRight: points[1],
        bottomRight: points[2],
        bottomLeft: points[3],
      ),
      debug,
    );
  } finally {
    for (final mat in owned.reversed) {
      mat.dispose();
    }
  }
}

/// Clockwise winding, starting at the top-left, including perspective pages.
List<ui.Offset> orderDocumentCorners(List<ui.Offset> raw) {
  if (raw.length != 4) return raw;
  final center = raw.reduce((a, b) => a + b) / 4;
  final points = [...raw]
    ..sort(
      (a, b) => math
          .atan2(a.dy - center.dy, a.dx - center.dx)
          .compareTo(math.atan2(b.dy - center.dy, b.dx - center.dx)),
    );
  var start = 0;
  for (var i = 1; i < 4; i++) {
    if (points[i].dx + points[i].dy < points[start].dx + points[start].dy) {
      start = i;
    }
  }
  return [for (var i = 0; i < 4; i++) points[(start + i) % 4]];
}

double documentQuadArea(List<ui.Offset> points) {
  if (points.length != 4) return 0;
  var area = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = points[i], b = points[(i + 1) % 4];
    area += a.dx * b.dy - b.dx * a.dy;
  }
  return area.abs() / 2;
}

bool isValidDocumentQuad(List<ui.Offset> points) {
  if (points.length != 4 ||
      points.any(
        (p) =>
            !p.dx.isFinite ||
            !p.dy.isFinite ||
            p.dx < 0 ||
            p.dy < 0 ||
            p.dx > 1 ||
            p.dy > 1,
      ) ||
      documentQuadArea(points) < .005) {
    return false;
  }
  for (var i = 0; i < 4; i++) {
    final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
    if ((a - b).distance <= .01 ||
        (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx) <= .00001) {
      return false;
    }
  }
  return true;
}

double _gradientThreshold(cv.Mat gray) {
  final dx = cv.sobel(gray, cv.MatType.CV_16S, 1, 0),
      dy = cv.sobel(gray, cv.MatType.CV_16S, 0, 1);
  final absX = cv.convertScaleAbs(dx), absY = cv.convertScaleAbs(dy);
  try {
    final x = absX.data, y = absY.data, histogram = List.filled(256, 0);
    for (var i = 0; i < x.length; i++) {
      histogram[math.min(255, x[i] + y[i])]++;
    }
    var count = 0;
    for (var value = 0; value < 256; value++) {
      count += histogram[value];
      if (count >= (x.length * .85).floor()) {
        return (value * 1.5).clamp(24.0, 160.0);
      }
    }
    return 80;
  } finally {
    absX.dispose();
    absY.dispose();
    dx.dispose();
    dy.dispose();
  }
}

double _boundarySupport(
  List<int> edges,
  int width,
  int height,
  List<ui.Offset> points,
) {
  var hits = 0;
  for (var side = 0; side < 4; side++) {
    final a = points[side], b = points[(side + 1) % 4];
    for (var step = 1; step <= 32; step++) {
      final p = ui.Offset.lerp(a, b, step / 33)!;
      var found = false;
      for (var dy = -3; dy <= 3 && !found; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final x = p.dx.round() + dx, y = p.dy.round() + dy;
          if (x >= 0 &&
              x < width &&
              y >= 0 &&
              y < height &&
              edges[y * width + x] != 0) {
            found = true;
            break;
          }
        }
      }
      if (found) hits++;
    }
  }
  return hits / 128;
}
