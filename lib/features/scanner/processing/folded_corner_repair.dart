part of 'ranked_document_detector.dart';

class _DocumentCandidate {
  final List<ui.Offset> normalized;
  final List<ui.Offset> pixels;
  final List<double> sides;
  final double support;
  final double score;

  _DocumentCandidate(
    this.normalized,
    this.pixels,
    this.sides,
    this.support,
    this.score,
  );
}

class _FoldRepair {
  final _DocumentCandidate quad;
  final int corner;
  final double addedArea;

  _FoldRepair(this.quad, this.corner, this.addedArea);
}

/// A fold removes one corner and leaves a short bevel between its two sides.
/// Require three distinct surviving corners and two adjacent bevel endpoints.
int? _foldedCorner(List<ui.Offset> quad, List<List<ui.Offset>> bevels) {
  // Blur, dilation and hull simplification can shave several processing pixels
  // off a real corner. This tolerance matches contour vertices, not page anchors.
  const tolerance = 6.0;
  final edgeTolerance = math.max(
    tolerance,
    math.max((quad[0] - quad[2]).distance, (quad[1] - quad[3]).distance) * .015,
  );
  for (final polygon in bevels) {
    final matched = <int>{};
    final missing = <int>[];
    for (var corner = 0; corner < 4; corner++) {
      var nearest = 0;
      for (var i = 1; i < 5; i++) {
        if ((quad[corner] - polygon[i]).distance <
            (quad[corner] - polygon[nearest]).distance) {
          nearest = i;
        }
      }
      if ((quad[corner] - polygon[nearest]).distance <= tolerance) {
        matched.add(nearest);
      } else {
        missing.add(corner);
      }
    }
    if (missing.length != 1 || matched.length != 3) continue;
    final ends = [
      for (var i = 0; i < 5; i++)
        if (!matched.contains(i)) i,
    ];
    if ((ends[0] - ends[1]).abs() != 1 && (ends[0] - ends[1]).abs() != 4) {
      continue;
    }
    final corner = missing.single;
    final origin = quad[corner];
    final previous = quad[(corner + 3) % 4] - origin;
    final next = quad[(corner + 1) % 4] - origin;
    bool liesOnMissingEnd(ui.Offset point, ui.Offset side) {
      final delta = point - origin;
      final t =
          (delta.dx * side.dx + delta.dy * side.dy) / side.distanceSquared;
      return t > 0 &&
          t <= .35 &&
          (point - (origin + side * t)).distance <= edgeTolerance;
    }

    final a = polygon[ends[0]], b = polygon[ends[1]];
    if ((liesOnMissingEnd(a, previous) && liesOnMissingEnd(b, next)) ||
        (liesOnMissingEnd(b, previous) && liesOnMissingEnd(a, next))) {
      return corner;
    }
  }
  return null;
}

List<ui.Offset> _repairSelectedPage(
  _DocumentCandidate original,
  List<_FoldRepair> repairs,
  List<int> edges,
  int width,
  int height,
) {
  final diagonal = math.max(
    (original.pixels[0] - original.pixels[2]).distance,
    (original.pixels[1] - original.pixels[3]).distance,
  );
  final anchorTolerance = math.max(3.0, diagonal * .03);
  var bestSupport = original.support;
  var bestMovement = double.infinity;
  var selected = original.normalized;
  for (final repair in repairs) {
    final proposed = repair.quad;
    final corner = repair.corner;
    if ([
      for (var i = 0; i < 4; i++)
        if (i != corner) i,
    ].any(
      (i) =>
          (original.pixels[i] - proposed.pixels[i]).distance > anchorTolerance,
    )) {
      continue;
    }
    final movement =
        (original.pixels[corner] - proposed.pixels[corner]).distance;
    if (movement <= anchorTolerance) continue;
    final normalized = [...original.normalized]
      ..[corner] = proposed.normalized[corner];
    if (!isValidDocumentQuad(normalized)) continue;
    final pixels = [...original.pixels]..[corner] = proposed.pixels[corner];
    // Measure confidence with the original three-pixel corridor on both frames.
    // Retained anchors can sit on the inner/outer side of a blurred contour, so
    // allow their bounded offset when checking that all four sides still exist.
    final anchorOffset = [
      for (var i = 0; i < 4; i++)
        if (i != corner) (original.pixels[i] - proposed.pixels[i]).distance,
    ].reduce(math.max);
    final radius = anchorOffset.ceil().clamp(3, 6);
    final sides = _boundarySupport(edges, width, height, pixels);
    final boundedSides = radius == 3
        ? sides
        : _boundarySupport(edges, width, height, pixels, radius: radius);
    final support = sides.reduce((a, b) => a + b) / 4;
    if (support < .65 || boundedSides.any((value) => value < .45)) continue;
    // Only the two sides adjoining this corner change. Measure the five-point
    // improvement there, without diluting it with the two unchanged sides.
    final previousSide = (corner + 3) % 4;
    final before = (original.sides[previousSide] + original.sides[corner]) / 2;
    final after = (sides[previousSide] + sides[corner]) / 2;
    if (after < before + .05) continue;
    if (support > bestSupport ||
        (support == bestSupport && movement < bestMovement)) {
      bestSupport = support;
      bestMovement = movement;
      // Three corners retain their exact original coordinates.
      selected = normalized;
    }
  }
  return selected;
}

/// Without an ordinary page, a reconstructed shape needs independent evidence
/// from one enclosed paper component. Camera borders are never paper components.
List<ui.Offset>? _foldedPageFallback(
  List<_FoldRepair> repairs,
  cv.Mat mask,
  int imageWidth,
  int imageHeight,
  int border,
) {
  if (repairs.isEmpty) return null;
  final labels = cv.Mat.empty(),
      stats = cv.Mat.empty(),
      centers = cv.Mat.empty();
  try {
    final count = cv.connectedComponentsWithStats(
      mask,
      labels,
      stats,
      centers,
      8,
      cv.MatType.CV_32S,
      cv.CCL_DEFAULT,
    );
    final bytes = labels.data;
    final components = bytes.buffer.asInt32List(
      bytes.offsetInBytes,
      bytes.length ~/ 4,
    );
    final areas = List<int>.filled(count, 0);
    for (var id = 1; id < count; id++) {
      final x = stats.at<int>(id, cv.CC_STAT_LEFT);
      final y = stats.at<int>(id, cv.CC_STAT_TOP);
      final width = stats.at<int>(id, cv.CC_STAT_WIDTH);
      final height = stats.at<int>(id, cv.CC_STAT_HEIGHT);
      if (x <= border ||
          y <= border ||
          x + width >= border + imageWidth ||
          y + height >= border + imageHeight) {
        continue;
      }
      areas[id] = stats.at<int>(id, cv.CC_STAT_AREA);
    }
    var bestAgreement = .85;
    var bestSupport = -1.0;
    var leastAddedArea = double.infinity;
    List<ui.Offset>? selected;
    for (final repair in repairs) {
      final agreement = _paperAgreement(
        repair.quad.pixels,
        components,
        areas,
        labels.cols,
        labels.rows,
      );
      if (agreement < .85) continue;
      if (agreement > bestAgreement ||
          (agreement == bestAgreement && repair.quad.support > bestSupport) ||
          (agreement == bestAgreement &&
              repair.quad.support == bestSupport &&
              repair.addedArea < leastAddedArea)) {
        bestAgreement = agreement;
        bestSupport = repair.quad.support;
        leastAddedArea = repair.addedArea;
        selected = repair.quad.normalized;
      }
    }
    return selected;
  } finally {
    labels.dispose();
    stats.dispose();
    centers.dispose();
  }
}

/// Raster intersection-over-union with each eligible connected component.
/// Scan convex spans so matching allocates only one count per component.
double _paperAgreement(
  List<ui.Offset> quad,
  List<int> labels,
  List<int> areas,
  int width,
  int height,
) {
  final intersections = List<int>.filled(areas.length, 0);
  final firstRow = math.max(0, quad.map((p) => p.dy).reduce(math.min).floor());
  final lastRow = math.min(
    height - 1,
    quad.map((p) => p.dy).reduce(math.max).ceil(),
  );
  var quadPixels = 0;
  for (var y = firstRow; y <= lastRow; y++) {
    final scanY = y + .5;
    final crossings = <double>[];
    for (var i = 0; i < 4; i++) {
      final a = quad[i], b = quad[(i + 1) % 4];
      if ((a.dy <= scanY && b.dy > scanY) || (b.dy <= scanY && a.dy > scanY)) {
        crossings.add(a.dx + (scanY - a.dy) * (b.dx - a.dx) / (b.dy - a.dy));
      }
    }
    if (crossings.length != 2) continue;
    crossings.sort();
    final left = math.max(0, (crossings[0] - .5).ceil());
    final right = math.min(width - 1, (crossings[1] - .5).floor());
    for (var x = left; x <= right; x++) {
      quadPixels++;
      final id = labels[y * width + x];
      if (areas[id] > 0) intersections[id]++;
    }
  }
  var agreement = 0.0;
  for (var id = 1; id < areas.length; id++) {
    if (areas[id] == 0) continue;
    final union = quadPixels + areas[id] - intersections[id];
    if (union > 0) agreement = math.max(agreement, intersections[id] / union);
  }
  return agreement;
}
