import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';

const _size = Size(2160, 3840);
final _frame = DocumentFrame(
  topLeft: Offset.zero,
  topRight: const Offset(2159, 0),
  bottomRight: const Offset(2160, 3840),
  bottomLeft: const Offset(0, 3839),
);

image.Image _colorPage() {
  final page = image.Image(width: 2160, height: 3840);
  image.fill(page, color: image.ColorRgb8(242, 242, 242));
  for (final (y, color) in [
    (300, image.ColorRgb8(30, 85, 180)),
    (600, image.ColorRgb8(205, 95, 25)),
    (900, image.ColorRgb8(25, 25, 25)),
  ]) {
    image.drawString(
      page,
      'Colored fine print 0123456789',
      font: image.arial24,
      x: 50,
      y: y,
      color: color,
    );
    image.fillRect(page, x1: 1200, y1: y, x2: 1500, y2: y + 100, color: color);
  }
  // Neutral left-edge sentinel catches colored borders; thin vertical strokes
  // and a faint signature exercise spatial detail independently of dimensions.
  image.fillRect(
    page,
    x1: 800,
    y1: 1200,
    x2: 803,
    y2: 1600,
    color: image.ColorRgb8(25, 25, 25),
  );
  image.drawLine(
    page,
    x1: 300,
    y1: 1800,
    x2: 650,
    y2: 1900,
    thickness: 3,
    color: image.ColorRgb8(185, 195, 215),
  );
  return page;
}

void _expectQuality(image.Image page) {
  final blue = page.getPixel(1300, 350);
  final orange = page.getPixel(1300, 650);
  expect(
    blue.b - blue.r,
    greaterThan(90),
    reason: 'Blue must not become orange.',
  );
  expect(
    orange.r - orange.b,
    greaterThan(110),
    reason: 'Orange must not become blue.',
  );
  for (final y in [100, 1500, 3000]) {
    final edge = page.getPixel(0, y);
    expect(
      math.max(edge.r, math.max(edge.g, edge.b)) -
          math.min(edge.r, math.min(edge.g, edge.b)),
      lessThanOrEqualTo(2),
      reason: 'No green left border.',
    );
  }
  final dark = [
    for (var x = 795; x <= 808; x++)
      if (page.getPixel(x, 1400).r < 120) x,
  ];
  expect(
    dark.length,
    inInclusiveRange(3, 5),
    reason: 'Thin lines must not spread into blur.',
  );
  var blueInk = 0, orangeInk = 0, blackInk = 0, faintInk = 0;
  for (var y = 290; y < 1940; y++) {
    for (var x = 40; x < 720; x++) {
      final p = page.getPixel(x, y);
      if (y < 340 && p.b - p.r > 60) blueInk++;
      if (y >= 590 && y < 640 && p.r - p.b > 80) orangeInk++;
      if (y >= 890 && y < 940 && p.r < 90 && p.g < 90 && p.b < 90) blackInk++;
      if (y >= 1790 && p.r < 230 && p.b > p.r) faintInk++;
    }
  }
  expect(blueInk, greaterThan(500));
  expect(orangeInk, greaterThan(500));
  expect(blackInk, greaterThan(500));
  expect(faintInk, greaterThan(200));
}

Future<void> _wait(WidgetTester tester) async {
  await tester.pump();
  for (
    var i = 0;
    i < 1500 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void registerCaptureQualityTests() {
  for (final jpeg in [false, true]) {
    test(
      '4K ${jpeg ? 'JPEG' : 'PNG'} perspective retains colors and sharp edges',
      () async {
        final source = _colorPage();
        final bytes = Uint8List.fromList(
          jpeg ? image.encodeJpg(source, quality: 95) : image.encodePng(source),
        );
        final output = image.decodePng(
          await perspectiveTransform(imageBytes: bytes, frame: _frame),
        )!;
        expect((output.width, output.height), (2160, 3840));
        _expectQuality(output);
      },
    );
  }

  testWidgets(
    '4K color edits, recrop, rotation and file re-edit preserve exported pixels',
    (tester) async {
      final original = Uint8List.fromList(image.encodePng(_colorPage()));
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('scanner_color_quality_'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/original.png');
      await tester.runAsync(() => file.writeAsBytes(original));
      final cropped = (await tester.runAsync(
        () => perspectiveTransform(imageBytes: original, frame: _frame),
      ))!;
      for (final (enhance, shadows, turns) in [
        (false, true, 0),
        (true, true, 1),
        (true, false, 3),
      ]) {
        Uint8List? accepted;
        for (final fromFile in [false, true]) {
          ImageEditResult? saved;
          await tester.pumpWidget(
            MaterialApp(
              home: ImageEditView(
                key: UniqueKey(),
                originalImageBytes: fromFile ? null : original,
                originalImageFile: fromFile ? file : null,
                originalImageSize: _size,
                initialCropFrame: _frame,
                initialCroppedBytes: fromFile ? null : cropped,
                initialEnhanced: enhance,
                initialReduceShadows: shadows,
                initialQuarterTurns: turns,
                isNewCapture: !fromFile,
                onConfirmed: (value) => saved = value,
                onCancelled: () {},
              ),
            ),
          );
          await _wait(tester);
          if (!fromFile) {
            await tester.tap(find.text('Crop'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Done'));
            await _wait(tester);
            await tester.pumpAndSettle();
          }
          final displayed =
              (tester.widget<Image>(find.byType(Image)).image as MemoryImage)
                  .bytes;
          await tester.tap(find.text('Apply'));
          expect(saved!.editedBytes, displayed);
          expect(saved!.enhanced, enhance);
          expect(saved!.reduceShadows, shadows);
          if (fromFile) expect(saved!.editedBytes, accepted);
          accepted = saved!.editedBytes;
          var page = image.decodePng(accepted)!;
          if (turns != 0) page = image.copyRotate(page, angle: -turns * 90);
          _expectQuality(page);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      expect(await tester.runAsync(file.readAsBytes), original);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
