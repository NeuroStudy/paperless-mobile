import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Corners are pixel centers: an image's last pixel is (width - 1, height - 1).
class DocumentFrame {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  DocumentFrame({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  factory DocumentFrame.fullImage(Size imageSize) {
    _validateImageSize(imageSize);
    return DocumentFrame(
      topLeft: Offset.zero,
      topRight: Offset(imageSize.width - 1, 0),
      bottomRight: Offset(imageSize.width - 1, imageSize.height - 1),
      bottomLeft: Offset(0, imageSize.height - 1),
    );
  }

  /// Also accepts older saved frames whose far corners were width/height.
  DocumentFrame clampedToImage(Size imageSize) {
    _validateImageSize(imageSize);
    Offset clamp(Offset point) {
      if (!point.dx.isFinite || !point.dy.isFinite) {
        throw ArgumentError.value(point, 'frame', 'Corners must be finite');
      }
      return Offset(
        point.dx.clamp(0.0, imageSize.width - 1),
        point.dy.clamp(0.0, imageSize.height - 1),
      );
    }

    return DocumentFrame(
      topLeft: clamp(topLeft),
      topRight: clamp(topRight),
      bottomRight: clamp(bottomRight),
      bottomLeft: clamp(bottomLeft),
    );
  }

  /// The all-zero frame was used as a placeholder by legacy scan metadata.
  DocumentFrame restoredForImage(Size imageSize) {
    if (topLeft == Offset.zero &&
        topRight == Offset.zero &&
        bottomRight == Offset.zero &&
        bottomLeft == Offset.zero) {
      return DocumentFrame.fullImage(imageSize);
    }
    return clampedToImage(imageSize);
  }

  /// Maps corresponding pixel centers between preview and captured images.
  DocumentFrame mapToImage({required Size from, required Size to}) {
    _validateImageSize(to);
    return clampedToImage(from)
        .scale(
          (to.width - 1) / math.max(1.0, from.width - 1),
          (to.height - 1) / math.max(1.0, from.height - 1),
        )
        .clampedToImage(to);
  }

  static void _validateImageSize(Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 1 ||
        size.height < 1) {
      throw ArgumentError.value(size, 'imageSize', 'Image must contain pixels');
    }
  }

  DocumentFrame scale(double scaleX, double scaleY) {
    return DocumentFrame(
      topLeft: Offset(topLeft.dx * scaleX, topLeft.dy * scaleY),
      topRight: Offset(topRight.dx * scaleX, topRight.dy * scaleY),
      bottomRight: Offset(bottomRight.dx * scaleX, bottomRight.dy * scaleY),
      bottomLeft: Offset(bottomLeft.dx * scaleX, bottomLeft.dy * scaleY),
    );
  }

  /// Linearly interpolates between this frame and [other] by [t].
  /// At t=0 returns this, at t=1 returns [other].
  DocumentFrame lerpTo(DocumentFrame other, double t) {
    return DocumentFrame(
      topLeft: Offset.lerp(topLeft, other.topLeft, t)!,
      topRight: Offset.lerp(topRight, other.topRight, t)!,
      bottomRight: Offset.lerp(bottomRight, other.bottomRight, t)!,
      bottomLeft: Offset.lerp(bottomLeft, other.bottomLeft, t)!,
    );
  }

  /// Returns the maximum Euclidean distance between corresponding corners
  /// of this frame and [other].
  double maxCornerDistance(DocumentFrame other) {
    final distances = [
      (topLeft - other.topLeft).distance,
      (topRight - other.topRight).distance,
      (bottomRight - other.bottomRight).distance,
      (bottomLeft - other.bottomLeft).distance,
    ];
    return distances.reduce((a, b) => a > b ? a : b);
  }

  /// Returns `true` when the maximum Euclidean distance between any
  /// pair of corresponding corners is within [maxDistance] pixels.
  bool isSimilarTo(DocumentFrame other, {required double maxDistance}) {
    return maxCornerDistance(other) <= maxDistance;
  }

  /// Returns the geometric center of the four corners.
  Offset get center {
    return Offset(
      (topLeft.dx + topRight.dx + bottomRight.dx + bottomLeft.dx) / 4,
      (topLeft.dy + topRight.dy + bottomRight.dy + bottomLeft.dy) / 4,
    );
  }

  /// Returns the maximum distance from [center] to any corner.
  double get maxRadiusFromCenter {
    final c = center;
    return [
      (topLeft - c).distance,
      (topRight - c).distance,
      (bottomRight - c).distance,
      (bottomLeft - c).distance,
    ].reduce((a, b) => a > b ? a : b);
  }

  /// Approximate area of the quadrilateral using the shoelace formula.
  double get area {
    // Shoelace formula for a simple polygon with vertices in order.
    return 0.5 *
        ((topLeft.dx * topRight.dy - topRight.dx * topLeft.dy) +
                (topRight.dx * bottomRight.dy - bottomRight.dx * topRight.dy) +
                (bottomRight.dx * bottomLeft.dy -
                    bottomLeft.dx * bottomRight.dy) +
                (bottomLeft.dx * topLeft.dy - topLeft.dx * bottomLeft.dy))
            .abs();
  }

  /// Returns `true` if [candidate] is a plausible replacement for this frame
  /// given the respective image sizes.
  ///
  /// Both frames are normalised to a 0..1 coordinate space (relative to their
  /// image dimensions) before comparing:
  ///   * **Area ratio**: the areas must be within [maxAreaRatio] of each other.
  ///   * **Center shift**: the normalised centres must be within
  ///     [maxCenterShift] (fraction of the image diagonal).
  ///
  /// Use this to decide whether a newly detected frame on a captured still
  /// image matches the frame the user "agreed" to during live preview.
  bool isPlausibleMatch(
    DocumentFrame candidate, {
    required Size thisImageSize,
    required Size candidateImageSize,
    double maxAreaRatio = 0.4,
    double maxCenterShift = 0.15,
  }) {
    // Normalise both frames to 0..1 coordinate space.
    final normThis = scale(
      1.0 / math.max(1.0, thisImageSize.width - 1),
      1.0 / math.max(1.0, thisImageSize.height - 1),
    );
    final normCandidate = candidate.scale(
      1.0 / math.max(1.0, candidateImageSize.width - 1),
      1.0 / math.max(1.0, candidateImageSize.height - 1),
    );

    // Area comparison.
    final areaA = normThis.area;
    final areaB = normCandidate.area;
    if (areaA <= 0 || areaB <= 0) return false;
    final areaRatio = (areaA - areaB).abs() / areaA;
    if (areaRatio > maxAreaRatio) return false;

    // Center position comparison.
    final centerDelta = (normThis.center - normCandidate.center).distance;
    if (centerDelta > maxCenterShift) return false;

    return true;
  }

  @override
  String toString() {
    return 'DocumentFrame(topLeft: $topLeft, topRight: $topRight, bottomRight: $bottomRight, bottomLeft: $bottomLeft)';
  }
}
