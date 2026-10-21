import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/scan_result.dart';
import 'package:paperless_mobile/features/scanner/models/transient_scan_result.dart';

ScanResult sampleScan({bool reduceShadows = true}) => ScanResult(
  originalFileName: 'original.png',
  editedFileName: 'edited.png',
  originalImageSize: const Size(600, 800),
  cropFrame: DocumentFrame(
    topLeft: const Offset(10, 10),
    topRight: const Offset(590, 10),
    bottomRight: const Offset(590, 790),
    bottomLeft: const Offset(10, 790),
  ),
  quarterTurns: 1,
  colorFilter: ScanColorFilter.none,
  bwThreshold: 10,
  enhanced: true,
  reduceShadows: reduceShadows,
);

void main() {
  test(
    'old page metadata defaults to shadow removal without enabling Enhance',
    () {
      final json = sampleScan().toJson()
        ..remove('reduceShadows')
        ..['enhanced'] = false;
      final restored = ScanResult.fromJson(json);
      expect(restored.reduceShadows, isTrue);
      expect(restored.enhanced, isFalse);
    },
  );
  test('shadow choice survives JSON, copy and transient edits', () {
    final page = ScanResult.fromJson(sampleScan(reduceShadows: false).toJson());
    expect(page.reduceShadows, isFalse);
    expect(page.copyWith(quarterTurns: 3).reduceShadows, isFalse);
    final transient = TransientScanResult(
      originalFile: File('original.png'),
      outputFile: File('edited.png'),
      thumbnailBytes: Uint8List(0),
      scanResult: page,
    );
    transient.reduceShadows = true;
    transient.enhanced = false;
    expect(
      ScanResult.fromJson(transient.scanResult.toJson()).reduceShadows,
      isTrue,
    );
    expect(transient.enhanced, isFalse);
  });
}
