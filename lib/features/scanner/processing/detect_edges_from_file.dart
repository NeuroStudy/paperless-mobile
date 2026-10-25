import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv4;
import 'package:paperless_mobile/features/scanner/models/debug_stage.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/processing/ranked_document_detector.dart';

/// Detects document edges from a static image (PNG/JPEG bytes).
///
/// Uses [EdgeDetectionConfig.accurate] by default for higher-quality detection
/// on a captured still image. Pass a custom [config] to override.
/// Folded-corner repair is confined to captured/imported images; live detection
/// retains the ordinary page-selection path.
///
/// Returns the detected [DocumentFrame] if a document quad is found, or `null`.
Future<DocumentFrame?> detectEdgesFromImageBytes(
  Uint8List imageBytes, {
  EdgeDetectionConfig config = EdgeDetectionConfig.accurate,
}) async {
  final mat = cv4.imdecode(imageBytes, cv4.IMREAD_COLOR);
  try {
    if (mat.isEmpty) return null;
    // Convert to RGBA, the shared detector's input format.
    final rgba = await cv4.cvtColorAsync(mat, cv4.COLOR_BGR2RGBA);
    try {
      final (frame, debugImage) = await detectRankedStillDocument(
        rgba,
        config,
        DebugStage.none,
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
