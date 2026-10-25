import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges.dart';

/// Detects document edges from a static image (PNG/JPEG bytes).
///
/// Uses the same [EdgeDetectionConfig.fourPoint] recognizer as live analysis.
/// Pass a custom [config] to override.
///
/// Returns the detected [DocumentFrame] if a document quad is found, or `null`.
Future<DocumentFrame?> detectEdgesFromImageBytes(
  Uint8List imageBytes, {
  EdgeDetectionConfig config = EdgeDetectionConfig.fourPoint,
}) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  try {
    if (mat.isEmpty) return null;
    // Convert to RGBA (format expected by detectDocumentEdges).
    final rgba = await cv4.cvtColorAsync(mat, cv4.COLOR_BGR2RGBA);
    try {
      final (frame, debugImage) = await detectDocumentEdges(
        rgba,
        config: config,
        repairFoldedCorners: true,
      );
      debugImage?.dispose();
      return frame;
    } finally {
      rgba.dispose();
    }
  } finally {
    mat.dispose();
  }
}
