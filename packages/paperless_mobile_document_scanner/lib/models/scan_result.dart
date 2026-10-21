import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:paperless_mobile_document_scanner/models/document_frame.dart';

/// Color filter options for scanned images.
enum ScanColorFilter { none, greyscale, blackAndWhite }

/// Stores a scanned document with its transformation parameters and lightweight
/// preview data. Full-resolution bytes live on disk; only a small thumbnail is
/// kept in memory.
class ScanResult {
  /// The original captured image file (full resolution, no crop).
  final File originalFile;

  /// Pixel dimensions of the original image.
  final Size originalImageSize;

  /// The crop frame applied to the original image.
  DocumentFrame cropFrame;

  /// How many 90° clockwise turns have been applied (0–3).
  int quarterTurns;

  /// The color filter applied.
  ScanColorFilter colorFilter;

  /// B&W adaptive threshold constant (only relevant when [colorFilter] is
  /// [ScanColorFilter.blackAndWhite]).
  double bwThreshold;

  /// Whether auto-enhance was applied.
  bool enhanced;

  /// Whether enhancement reduces shadows. Older callers retain the default.
  bool reduceShadows;

  /// A small thumbnail of the final edited image (kept in memory for the
  /// preview list).
  Uint8List thumbnailBytes;

  /// The output file containing the full-resolution edited image.
  final File outputFile;

  ScanResult({
    required this.originalFile,
    required this.originalImageSize,
    required this.cropFrame,
    required this.quarterTurns,
    required this.colorFilter,
    required this.bwThreshold,
    required this.enhanced,
    this.reduceShadows = true,
    required this.thumbnailBytes,
    required this.outputFile,
  });
}
