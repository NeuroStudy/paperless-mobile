import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile/features/scanner/view/edge_adjustment_view.dart';
import 'package:paperless_mobile/features/scanner/view/image_edit_view.dart';
import 'package:paperless_mobile/features/scanner/view/widgets/draggable_frame_overlay_painter.dart';
import 'package:paperless_mobile/features/scanner/view/widgets/frame_overlay_painter.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

DocumentFrame _rect(double left, double top, double right, double bottom) =>
    DocumentFrame(
      topLeft: Offset(left, top),
      topRight: Offset(right, top),
      bottomRight: Offset(right, bottom),
      bottomLeft: Offset(left, bottom),
    );

img.Image _pattern(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    p.r = 30 + (p.x * 37 + p.y * 19) % 220;
    p.g = 30 + (p.x * 11 + p.y * 53) % 220;
    p.b = 30 + (p.x * 71 + p.y * 7) % 220;
  }
  return image;
}

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

void _samePixels(img.Image actual, img.Image expected) {
  expect((actual.width, actual.height), (expected.width, expected.height));
  expect(
    actual.getBytes(order: img.ChannelOrder.rgb),
    orderedEquals(expected.getBytes(order: img.ChannelOrder.rgb)),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

/// Shared with the Android integration harness: exercise the real native crop.
void registerPerspectiveTransformTests() {
  test(
    'full-page PNG and JPEG crops preserve every decoded pixel and border',
    () async {
      for (final (width, height) in [(31, 46), (32, 47), (79, 43)]) {
        final image = _pattern(width, height);
        for (final bytes in [
          _png(image),
          Uint8List.fromList(img.encodeJpg(image)),
        ]) {
          final decoded = cv.imdecode(bytes, cv.IMREAD_COLOR);
          try {
            final expected = img.decodePng(cv.imencode('.png', decoded).$2)!;
            final output = await perspectiveTransform(
              imageBytes: bytes,
              frame: DocumentFrame.fullImage(
                Size(width.toDouble(), height.toDouble()),
              ),
            );
            expect(
              output.take(8),
              orderedEquals([137, 80, 78, 71, 13, 10, 26, 10]),
            );
            _samePixels(img.decodePng(output)!, expected);
          } finally {
            decoded.dispose();
          }
        }
      }
    },
  );

  test('legacy width/height bounds preserve all rows and columns', () async {
    final image = _pattern(32, 47);
    final result = await perspectiveTransform(
      imageBytes: _png(image),
      frame: _rect(0, 0, 32, 47),
    );
    _samePixels(img.decodePng(result)!, image);
  });

  test(
    'integer rectangle includes both corner pixels without interpolation',
    () async {
      final image = _pattern(32, 47);
      final expected = img.copyCrop(image, x: 3, y: 7, width: 26, height: 33);
      for (final noise in [0.0, 1e-7]) {
        final output = await perspectiveTransform(
          imageBytes: _png(image),
          frame: _rect(3 + noise, 7 + noise, 28 + noise, 39 + noise),
        );
        _samePixels(img.decodePng(output)!, expected);
      }
    },
  );

  test(
    'single pixel images, rows, columns and selections use direct copies',
    () async {
      for (final (width, height) in [(1, 1), (1, 20), (20, 1)]) {
        final image = _pattern(width, height);
        final output = await perspectiveTransform(
          imageBytes: _png(image),
          frame: DocumentFrame.fullImage(
            Size(width.toDouble(), height.toDouble()),
          ),
        );
        _samePixels(img.decodePng(output)!, image);
      }
      final image = _pattern(20, 20);
      final column = await perspectiveTransform(
        imageBytes: _png(image),
        frame: _rect(5, 3, 5, 10),
      );
      _samePixels(
        img.decodePng(column)!,
        img.copyCrop(image, x: 5, y: 3, width: 1, height: 8),
      );
      final pixel = await perspectiveTransform(
        imageBytes: _png(image),
        frame: _rect(5, 3, 5, 3),
      );
      _samePixels(
        img.decodePng(pixel)!,
        img.copyCrop(image, x: 5, y: 3, width: 1, height: 1),
      );
    },
  );

  test(
    'a one-pixel pale line retains its contrast and does not spread',
    () async {
      final image = img.Image(width: 576, height: 768);
      img.fill(image, color: img.ColorRgb8(250, 250, 250));
      img.drawLine(
        image,
        x1: 55,
        y1: 450,
        x2: 510,
        y2: 450,
        color: img.ColorRgb8(225, 225, 225),
      );
      final output = img.decodePng(
        await perspectiveTransform(
          imageBytes: _png(image),
          frame: DocumentFrame.fullImage(const Size(576, 768)),
        ),
      )!;
      expect(output.getPixel(100, 450).r, 225);
      expect(output.getPixel(100, 449).r, 250);
      expect(output.getPixel(100, 451).r, 250);
    },
  );

  test(
    'fractional selections retain bilinear sampling rather than snapping',
    () async {
      final image = img.Image(width: 32, height: 32);
      for (final p in image) {
        p.r = p.x * 4;
        p.g = p.y * 4;
        p.b = 80;
      }
      final output = img.decodePng(
        await perspectiveTransform(
          imageBytes: _png(image),
          frame: _rect(2.25, 3.25, 12.25, 18.25),
        ),
      )!;
      expect((output.width, output.height), (11, 16));
      expect(output.getPixel(0, 0).r, 9);
      expect(output.getPixel(0, 0).g, 13);
      expect(output.getPixel(10, 15).r, 49);
      expect(output.getPixel(10, 15).g, 73);
    },
  );

  test(
    'perspective crops retain corrected dimensions and selected corner colors',
    () async {
      final image = _pattern(40, 40);
      final frame = DocumentFrame(
        topLeft: const Offset(2, 2),
        topRight: const Offset(26, 4),
        bottomRight: const Offset(29, 25),
        bottomLeft: const Offset(1, 27),
      );
      final output = img.decodePng(
        await perspectiveTransform(imageBytes: _png(image), frame: frame),
      )!;
      expect((output.width, output.height), (29, 26));
      for (final (x, y, sx, sy) in [
        (0, 0, 2, 2),
        (28, 0, 26, 4),
        (28, 25, 29, 25),
        (0, 25, 1, 27),
      ]) {
        expect(
          output.getPixel(x, y).toList().take(3),
          orderedEquals(image.getPixel(sx, sy).toList().take(3)),
        );
      }
      final slightlyTilted = DocumentFrame(
        topLeft: const Offset(2, 2),
        topRight: const Offset(12, 2),
        bottomRight: const Offset(12.25, 18),
        bottomLeft: const Offset(2, 18),
      );
      final tilted = img.decodePng(
        await perspectiveTransform(
          imageBytes: _png(image),
          frame: slightlyTilted,
        ),
      )!;
      expect(
        tilted.getBytes(order: img.ChannelOrder.rgb),
        isNot(
          orderedEquals(
            img
                .copyCrop(image, x: 2, y: 2, width: 11, height: 17)
                .getBytes(order: img.ChannelOrder.rgb),
          ),
        ),
      );
    },
  );

  test(
    'invalid data and non-finite or non-convex perspective crops fail safely',
    () async {
      final bytes = _png(_pattern(32, 47));
      for (final frame in [
        _rect(double.nan, 1, 20, 30),
        _rect(1, 1, double.infinity, 30),
        DocumentFrame(
          topLeft: const Offset(1, 1),
          topRight: const Offset(20, 30),
          bottomRight: const Offset(20, 1),
          bottomLeft: const Offset(1, 30),
        ),
        DocumentFrame(
          topLeft: const Offset(1, 1),
          topRight: const Offset(20, 1),
          bottomRight: const Offset(5, 5),
          bottomLeft: const Offset(1, 30),
        ),
        DocumentFrame(
          topLeft: const Offset(1, 1),
          topRight: const Offset(3, 3),
          bottomRight: const Offset(4, 4),
          bottomLeft: const Offset(2, 2),
        ),
      ]) {
        await expectLater(
          perspectiveTransform(imageBytes: bytes, frame: frame),
          throwsArgumentError,
        );
      }
      await expectLater(
        perspectiveTransform(
          imageBytes: Uint8List.fromList([1, 2, 3]),
          frame: DocumentFrame.fullImage(const Size(32, 47)),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'saved frame normalization preserves fractional corners and old placeholders',
    () {
      final old = _rect(0, 0, 600, 800);
      final restored = old.restoredForImage(const Size(600, 800));
      expect(restored.bottomRight, const Offset(599, 799));
      expect(old.bottomRight, const Offset(600, 800));
      expect(
        _rect(0, 0, 0, 0).restoredForImage(const Size(600, 800)).bottomRight,
        const Offset(599, 799),
      );
      expect(
        _rect(
          2.25,
          3.5,
          590.75,
          790.5,
        ).restoredForImage(const Size(600, 800)).bottomRight,
        const Offset(590.75, 790.5),
      );
    },
  );

  test(
    'preview mapping preserves pixel-center endpoints across resolutions',
    () {
      final source = DocumentFrame.fullImage(const Size(320, 240));
      final target = source.mapToImage(
        from: const Size(320, 240),
        to: const Size(4032, 3024),
      );
      expect(target.topLeft, Offset.zero);
      expect(target.bottomRight, const Offset(4031, 3023));
      expect(
        source.isPlausibleMatch(
          target,
          thisImageSize: const Size(320, 240),
          candidateImageSize: const Size(4032, 3024),
          maxAreaRatio: 1e-10,
          maxCenterShift: 1e-10,
        ),
        isTrue,
      );
      expect(
        DocumentFrame.fullImage(const Size(1, 20))
            .mapToImage(from: const Size(1, 20), to: const Size(30, 40))
            .topRight
            .dx,
        0,
      );
    },
  );

  test(
    'live overlay outlines the pixel centers inside the displayed image',
    () async {
      final recorder = ui.PictureRecorder();
      FrameOverlayPainter(
        frameColor: const Color(0xff00ff00),
        frame: DocumentFrame.fullImage(const Size(10, 10)),
        imageSize: const Size(10, 10),
      ).paint(Canvas(recorder), const Size(100, 100));
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 100);
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(data.getUint8((50 * 100 + 5) * 4 + 1), 255);
        expect(data.getUint8((50 * 100 + 95) * 4 + 1), 255);
        expect(data.getUint8((50 * 100) * 4 + 3), 0);
      } finally {
        image.dispose();
        picture.dispose();
      }
    },
  );

  testWidgets(
    'crop editor clamps dragging, resets bounds and confirms all pixels',
    (tester) async {
      final image = _pattern(320, 480);
      Uint8List? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: EdgeAdjustmentView(
            imageBytes: _png(image),
            imageSize: const Size(320, 480),
            initialFrame: _rect(0, 0, 320, 480),
            onConfirmed: (bytes, frame) => confirmed = bytes,
            onCancelled: () {},
          ),
        ),
      );
      final finder = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is DraggableFrameOverlayPainter,
      );
      DraggableFrameOverlayPainter painter() =>
          tester.widget<CustomPaint>(finder).painter!
              as DraggableFrameOverlayPainter;
      expect(painter().frame.bottomRight, const Offset(319, 479));
      final bounds = tester.getRect(finder);
      final scale = (bounds.width / 320).clamp(0.0, bounds.height / 480);
      final origin = Offset(
        bounds.center.dx - 320 * scale / 2,
        bounds.center.dy - 480 * scale / 2,
      );
      final last = origin + Offset(319.5 * scale, 479.5 * scale);
      await tester.dragFrom(last, const Offset(100, 100));
      await tester.pump();
      expect(painter().frame.bottomRight, const Offset(319, 479));
      await tester.dragFrom(
        origin + Offset(.5 * scale, .5 * scale),
        const Offset(30, 30),
      );
      await tester.pump();
      expect(painter().frame.topLeft.dx, greaterThan(0));
      await tester.tap(find.byTooltip('Reset to scan bounds'));
      await tester.pump();
      expect(painter().frame.topLeft, Offset.zero);
      expect(painter().frame.bottomRight, const Offset(319, 479));
      await tester.tap(find.text('Done'));
      await _pumpUntil(tester, () => confirmed != null);
      _samePixels(img.decodePng(confirmed!)!, image);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    're-editing a legacy full frame returns the original pixels on Apply',
    (tester) async {
      final image = _pattern(32, 47);
      ImageEditResult? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: ImageEditView(
            originalImageBytes: _png(image),
            originalImageSize: const Size(32, 47),
            initialCropFrame: _rect(0, 0, 32, 47),
            onConfirmed: (result) => confirmed = result,
            onCancelled: () {},
            isNewCapture: false,
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(confirmed!.cropFrame.bottomRight, const Offset(31, 46));
      _samePixels(img.decodePng(confirmed!.editedBytes)!, image);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
