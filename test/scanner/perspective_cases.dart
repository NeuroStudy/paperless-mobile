import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile_document_scanner/view/edge_adjustment_view.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';

// Project physical page coordinates through a pinhole camera, independently of
// the crop's inverse homography and aspect-ratio calculation. The green square
// provides a content-shape check in addition to checking the image dimensions.
class _ProjectedPage {
  final double width;
  final double height;
  final double pitch;
  final double yaw;
  final double roll;
  final int sceneWidth;
  final double focalScale;
  final double distance;

  _ProjectedPage({
    this.width = 210,
    this.height = 297,
    this.pitch = 35,
    this.yaw = 20,
    this.roll = 0,
    this.sceneWidth = 800,
    this.focalScale = .875,
    this.distance = 700,
  });

  int get sceneHeight => sceneWidth * 3 ~/ 4;
  Size get size => Size(sceneWidth.toDouble(), sceneHeight.toDouble());

  Offset project(double x, double y) {
    final a = pitch * math.pi / 180;
    final b = yaw * math.pi / 180;
    final c = roll * math.pi / 180;
    // Rotate around X, Y, then Z; translate the page in front of the camera.
    final y1 = math.cos(a) * y;
    final z1 = math.sin(a) * y;
    final x2 = math.cos(b) * x + math.sin(b) * z1;
    final z2 = -math.sin(b) * x + math.cos(b) * z1;
    final x3 = math.cos(c) * x2 - math.sin(c) * y1 - width / 2;
    final y3 = math.sin(c) * x2 + math.cos(c) * y1 - height / 2;
    final z3 = z2 + distance * focalScale / .875;
    return Offset(
      sceneWidth * focalScale * x3 / z3 + sceneWidth / 2,
      sceneWidth * focalScale * y3 / z3 + sceneHeight / 2,
    );
  }

  DocumentFrame get frame => DocumentFrame(
    topLeft: project(0, 0),
    topRight: project(width, 0),
    bottomRight: project(width, height),
    bottomLeft: project(0, height),
  );

  Uint8List render() {
    final picture = image.Image(width: sceneWidth, height: sceneHeight);
    image.fill(picture, color: image.ColorRgb8(40, 40, 40));
    void polygon(double x, double y, double w, double h, image.Color color) {
      image.fillPolygon(
        picture,
        vertices: [
          project(x, y),
          project(x + w, y),
          project(x + w, y + h),
          project(x, y + h),
        ].map((p) => image.Point(p.dx, p.dy)).toList(),
        color: color,
      );
    }

    polygon(0, 0, width, height, image.ColorRgb8(245, 245, 245));
    final side = math.min(width, height) / 3;
    polygon(
      (width - side) / 2,
      (height - side) / 2,
      side,
      side,
      image.ColorRgb8(20, 170, 60),
    );
    return Uint8List.fromList(image.encodePng(picture));
  }
}

// Pixel counts include both corner centers; geometry assertions remain unchanged.
(int, int) _legacySize(DocumentFrame f) => (
  math
          .max(
            (f.topRight - f.topLeft).distance,
            (f.bottomRight - f.bottomLeft).distance,
          )
          .round() +
      1,
  math
          .max(
            (f.bottomLeft - f.topLeft).distance,
            (f.bottomRight - f.topRight).distance,
          )
          .round() +
      1,
);

void _expectProportions(image.Image picture, double ratio) {
  expect(picture.width / picture.height, closeTo(ratio, ratio * .01));
  final green = picture.where((p) => p.g > 120 && p.r < 80 && p.b < 100);
  var left = picture.width, top = picture.height, right = -1, bottom = -1;
  for (final pixel in green) {
    left = math.min(left, pixel.x);
    right = math.max(right, pixel.x);
    top = math.min(top, pixel.y);
    bottom = math.max(bottom, pixel.y);
  }
  expect(right, greaterThan(left), reason: 'The square must survive the crop.');
  expect((right - left + 1) / (bottom - top + 1), closeTo(1, .04));
}

Future<void> _waitForEditor(WidgetTester tester) async {
  for (var i = 0; i < 250; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
  }
  fail('The editor did not finish processing.');
}

void registerPerspectiveTests() {
  for (final angles in [(35.0, 20.0, 0.0), (45.0, 25.0, 15.0)]) {
    test('tilted A4 proportions and square content: $angles', () async {
      final page = _ProjectedPage(
        pitch: angles.$1,
        yaw: angles.$2,
        roll: angles.$3,
      );
      final legacy = _legacySize(page.frame);
      expect((legacy.$1 / legacy.$2 / (210 / 297) - 1).abs(), greaterThan(.15));
      final result = image.decodePng(
        await perspectiveTransform(
          imageBytes: page.render(),
          frame: page.frame,
        ),
      )!;
      _expectProportions(result, 210 / 297);
      expect(
        math.max(result.width, result.height),
        math.max(legacy.$1, legacy.$2),
      );
    });
  }

  for (final dimensions in [(297.0, 210.0), (80.0, 300.0), (210.0, 210.0)]) {
    test(
      'automatic proportions support physical page size $dimensions',
      () async {
        final page = _ProjectedPage(
          width: dimensions.$1,
          height: dimensions.$2,
          distance: 550,
        );
        final result = image.decodePng(
          await perspectiveTransform(
            imageBytes: page.render(),
            frame: page.frame,
          ),
        )!;
        _expectProportions(result, page.width / page.height);
      },
    );
  }

  for (final sceneWidth in [1600, 2400]) {
    test(
      'proportion recovery is independent of image resolution $sceneWidth',
      () async {
        final page = _ProjectedPage(sceneWidth: sceneWidth);
        final result = image.decodePng(
          await perspectiveTransform(
            imageBytes: page.render(),
            frame: page.frame,
          ),
        )!;
        _expectProportions(result, 210 / 297);
      },
    );
  }

  test('rotated source image recovers landscape A4 proportions', () async {
    final page = _ProjectedPage();
    final rotated = image.copyRotate(
      image.decodePng(page.render())!,
      angle: 90,
    );
    Offset turn(Offset p) => Offset(page.sceneHeight - 1 - p.dy, p.dx);
    final f = page.frame;
    final frame = DocumentFrame(
      topLeft: turn(f.bottomLeft),
      topRight: turn(f.topLeft),
      bottomRight: turn(f.topRight),
      bottomLeft: turn(f.bottomRight),
    );
    final result = image.decodePng(
      await perspectiveTransform(
        imageBytes: Uint8List.fromList(image.encodePng(rotated)),
        frame: frame,
      ),
    )!;
    _expectProportions(result, 297 / 210);
  });

  for (final entry in {
    'frontal': _ProjectedPage(pitch: 0, yaw: 0),
    'parallel sides': _ProjectedPage(yaw: 0),
    'unstable near parallel': _ProjectedPage(yaw: 2),
    'small narrow receipt': _ProjectedPage(width: 80, height: 300),
    'focal length below range': _ProjectedPage(focalScale: .4),
    'focal length above range': _ProjectedPage(focalScale: 6),
  }.entries) {
    test(
      'uncertain geometry retains existing dimensions: ${entry.key}',
      () async {
        final page = entry.value;
        final expected = _legacySize(page.frame);
        final result = image.decodePng(
          await perspectiveTransform(
            imageBytes: page.render(),
            frame: page.frame,
          ),
        )!;
        expect((result.width, result.height), expected);
      },
    );
  }

  testWidgets(
    'corrected capture, recrop and file re-edit save displayed pixels',
    (tester) async {
      final page = _ProjectedPage();
      final original = page.render();
      final cropped = (await tester.runAsync(
        () => perspectiveTransform(imageBytes: original, frame: page.frame),
      ))!;
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('scanner_proportions_'),
      ))!;
      addTearDown(() => directory.delete(recursive: true));
      final file = (await tester.runAsync(
        () => File('${directory.path}/original.png').writeAsBytes(original),
      ))!;

      for (final fromFile in [false, true]) {
        ImageEditResult? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: ImageEditView(
              key: ValueKey(fromFile),
              originalImageBytes: fromFile ? null : original,
              originalImageFile: fromFile ? file : null,
              originalImageSize: page.size,
              initialCropFrame: page.frame,
              initialCroppedBytes: fromFile ? null : cropped,
              isNewCapture: !fromFile,
              animateEntry: false,
              onConfirmed: (value) => saved = value,
              onCancelled: () {},
            ),
          ),
        );
        await _waitForEditor(tester);
        _expectProportions(
          image.decodePng(
            (tester.widget<Image>(find.byType(Image)).image as MemoryImage)
                .bytes,
          )!,
          210 / 297,
        );

        // Commit the same physical page again through the actual crop screen.
        await tester.tap(find.text('Crop'));
        await tester.pumpAndSettle();
        expect(find.byType(EdgeAdjustmentView), findsOneWidget);
        await tester.tap(find.text('Done'));
        await _waitForEditor(tester);
        await tester.pumpAndSettle();
        final displayed =
            (tester.widget<Image>(find.byType(Image)).image as MemoryImage)
                .bytes;
        await tester.tap(find.text('Apply'));
        expect(saved, isNotNull);
        expect(saved!.editedBytes, displayed);
        _expectProportions(image.decodePng(saved!.editedBytes)!, 210 / 297);
      }
      expect(await tester.runAsync(file.readAsBytes), original);
    },
  );
}
