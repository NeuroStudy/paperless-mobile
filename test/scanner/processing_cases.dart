import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile/features/scanner/models/document_frame.dart';
import 'package:paperless_mobile/features/scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile/features/scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile/features/scanner/processing/color_enhancement.dart';
import 'package:paperless_mobile/features/scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile/features/scanner/processing/edge_detection_isolate.dart';
import 'package:paperless_mobile/features/scanner/processing/frame_stability_tracker.dart';
import 'package:paperless_mobile/features/scanner/processing/image_edit.dart';
import 'package:paperless_mobile/features/scanner/view/image_edit_view.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

import 'document_edge_regression_cases.dart';
import 'perspective_transform_cases.dart';

image.Image _page() {
  final page = image.Image(width: 600, height: 800);
  image.fill(page, color: image.ColorRgb8(250, 248, 245));
  for (var y = 100; y <= 600; y += 50) {
    image.drawString(
      page,
      'Readable document 0123456789',
      font: image.arial24,
      x: 60,
      y: y,
      color: image.ColorRgb8(35, 35, 35),
    );
  }
  image.drawString(
    page,
    'Blue title',
    font: image.arial24,
    x: 60,
    y: 40,
    color: image.ColorRgb8(40, 95, 170),
  );
  image.drawLine(
    page,
    x1: 300,
    y1: 690,
    x2: 400,
    y2: 725,
    thickness: 2,
    color: image.ColorRgb8(195, 205, 225),
  );
  return page;
}

image.Image _shadow(
  image.Image clean,
  double loss, {
  bool hard = false,
  bool warm = true,
}) {
  final result = image.Image.from(clean);
  for (final p in result) {
    final distance = p.x / result.width + .3 * p.y / result.height - .7;
    final shade = hard
        ? (distance < 0 ? 1.0 : 0.0)
        : 1 / (1 + math.exp(distance * 15));
    final factor = 1 - loss * shade;
    p.r = (p.r * factor).round();
    p.g = (p.g * factor * (warm ? .94 : 1)).round();
    p.b = (p.b * factor * (warm ? .86 : 1)).round();
  }
  return result;
}

double _luma(image.Image picture, int x, int y) {
  final p = picture.getPixel(x, y);
  return (p.r + p.g + p.b) / 3;
}

double _darkest(image.Image picture, int x0, int y0, int x1, int y1) {
  var result = 255.0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      result = math.min(result, _luma(picture, x, y));
    }
  }
  return result;
}

Uint8List _png(image.Image picture) =>
    Uint8List.fromList(image.encodePng(picture));

/// Cases and numerical limits carried forward from the v4 native scanner suites.
void registerProcessingTests() {
  registerDocumentEdgeRegressionTests();
  registerPerspectiveTransformTests();
  test(
    'live detector supplies stable corners to auto capture and resets on loss',
    () async {
      final scene = image.Image(width: 600, height: 800);
      image.fill(scene, color: image.ColorRgb8(45, 45, 45));
      image.fillRect(
        scene,
        x1: 90,
        y1: 70,
        x2: 510,
        y2: 730,
        color: image.ColorRgb8(245, 245, 245),
      );
      final runner = EdgeDetectionRunner();
      final tracker = FrameStabilityTracker(
        const AutoCaptureConfig(
          minConsecutiveSimilarFrames: 2,
          preStableDelay: Duration.zero,
          stableDuration: Duration(milliseconds: 10),
          distanceThreshold: 5,
        ),
      );
      await runner.start();
      try {
        for (var i = 0; i < 4; i++) {
          final outcome = await runner.detect(
            rgbaBytes: scene.getBytes(order: image.ChannelOrder.rgba),
            width: 600,
            height: 800,
            rotationCompensation: 0,
            edgeDetectionConfig: EdgeDetectionConfig.fast,
          );
          expect(outcome, isA<FrameDetected>());
          tracker.update((outcome as FrameDetected).frame);
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        expect(tracker.isReadyToCapture, isTrue);
        tracker.markCaptured();
        expect(tracker.isReadyToCapture, isFalse);
        image.fill(scene, color: image.ColorRgb8(45, 45, 45));
        final lost = await runner.detect(
          rgbaBytes: scene.getBytes(order: image.ChannelOrder.rgba),
          width: 600,
          height: 800,
          rotationCompensation: 0,
          edgeDetectionConfig: EdgeDetectionConfig.fast,
        );
        expect(lost, isA<FrameNotFound>());
        tracker.update(null);
        expect(tracker.stableFrame, isNull);
        expect(tracker.progress, 0);
      } finally {
        runner.dispose();
      }
    },
  );
  test(
    'recognizes perspective pages, narrow receipts, landscape and low contrast',
    () async {
      for (final points in [
        [
          image.Point(95, 70),
          image.Point(510, 100),
          image.Point(550, 700),
          image.Point(60, 740),
        ],
        [
          image.Point(230, 60),
          image.Point(370, 60),
          image.Point(370, 740),
          image.Point(230, 740),
        ],
        [
          image.Point(40, 240),
          image.Point(560, 240),
          image.Point(560, 560),
          image.Point(40, 560),
        ],
      ]) {
        for (final contrast in [false, true]) {
          final scene = image.Image(width: 600, height: 800);
          image.fill(
            scene,
            color: image.ColorRgb8(
              contrast ? 180 : 45,
              contrast ? 180 : 45,
              contrast ? 180 : 45,
            ),
          );
          image.fillPolygon(
            scene,
            vertices: points,
            color: image.ColorRgb8(
              contrast ? 205 : 245,
              contrast ? 205 : 245,
              contrast ? 205 : 245,
            ),
          );
          for (final config in [
            EdgeDetectionConfig.fast,
            EdgeDetectionConfig.accurate,
          ]) {
            final frame = await detectEdgesFromImageBytes(
              _png(scene),
              config: config,
            );
            expect(
              frame,
              isNotNull,
              reason: 'contrast=$contrast config=${config.resizeThreshold}',
            );
            final actual = [
              frame!.topLeft,
              frame.topRight,
              frame.bottomRight,
              frame.bottomLeft,
            ];
            for (var i = 0; i < 4; i++) {
              expect(
                (actual[i] -
                        Offset(points[i].x.toDouble(), points[i].y.toDouble()))
                    .distance,
                lessThan(20),
                reason: 'corner $i',
              );
            }
          }
        }
      }
    },
  );
  test('reconstructs folded page corners without changing perspective', () async {
    for (final points in [
      [
        const Offset(95, 70),
        const Offset(510, 100),
        const Offset(550, 700),
        const Offset(60, 740),
      ],
      [
        const Offset(230, 60),
        const Offset(370, 60),
        const Offset(370, 740),
        const Offset(230, 740),
      ],
      [
        const Offset(40, 240),
        const Offset(560, 240),
        const Offset(560, 560),
        const Offset(40, 560),
      ],
    ]) {
      for (var corner = 0; corner < 4; corner++) {
        for (final fold in [.12, .28]) {
          final scene = image.Image(width: 600, height: 800);
          final background = image.ColorRgb8(45, 45, 45);
          image.fill(scene, color: background);
          // Slightly offset pages behind the top page model a stapled stack.
          image.fillPolygon(
            scene,
            vertices: [
              for (final point in points)
                image.Point(point.dx.round() + 5, point.dy.round() + 5),
            ],
            color: image.ColorRgb8(165, 165, 165),
          );
          image.fillPolygon(
            scene,
            vertices: [
              for (final point in points)
                image.Point(point.dx.round(), point.dy.round()),
            ],
            color: image.ColorRgb8(245, 245, 245),
          );
          final cutA = Offset.lerp(
            points[corner],
            points[(corner + 3) % 4],
            fold,
          )!;
          final cutB = Offset.lerp(
            points[corner],
            points[(corner + 1) % 4],
            fold,
          )!;
          image.fillPolygon(
            scene,
            vertices: [
              image.Point(points[corner].dx.round(), points[corner].dy.round()),
              image.Point(cutA.dx.round(), cutA.dy.round()),
              image.Point(cutB.dx.round(), cutB.dy.round()),
            ],
            color: background,
          );
          final bytes = _png(
            fold == .28 ? _shadow(scene, .25, warm: false) : scene,
          );
          for (final config in [
            EdgeDetectionConfig.fast,
            EdgeDetectionConfig.accurate,
          ]) {
            final frame = await detectEdgesFromImageBytes(
              bytes,
              config: config,
            );
            final reason =
                'corner=$corner fold=$fold size=${config.resizeThreshold} points=$points';
            expect(frame, isNotNull, reason: reason);
            final actual = [
              frame!.topLeft,
              frame.topRight,
              frame.bottomRight,
              frame.bottomLeft,
            ];
            for (var i = 0; i < 4; i++) {
              expect(
                (actual[i] - points[i]).distance,
                lessThan(20),
                reason: '$reason result=$frame corner=$i',
              );
            }
          }
        }
      }
    }
  });
  test('partial side gaps retain the original page boundary', () async {
    final scene = image.Image(width: 600, height: 800);
    image.fill(scene, color: image.ColorRgb8(45, 45, 45));
    image.fillRect(
      scene,
      x1: 90,
      y1: 70,
      x2: 510,
      y2: 730,
      color: image.ColorRgb8(245, 245, 245),
    );
    image.fillRect(
      scene,
      x1: 485,
      y1: 290,
      x2: 520,
      y2: 370,
      color: image.ColorRgb8(45, 45, 45),
    );
    for (final config in [
      EdgeDetectionConfig.fast,
      EdgeDetectionConfig.accurate,
    ]) {
      final frame = await detectEdgesFromImageBytes(
        _png(scene),
        config: config,
      );
      expect(frame, isNotNull);
      final expected = [
        const Offset(90, 70),
        const Offset(510, 70),
        const Offset(510, 730),
        const Offset(90, 730),
      ];
      final actual = [
        frame!.topLeft,
        frame.topRight,
        frame.bottomRight,
        frame.bottomLeft,
      ];
      for (var i = 0; i < 4; i++) {
        expect((actual[i] - expected[i]).distance, lessThan(20));
      }
    }
  });
  test(
    'blank scenes and round objects do not produce document corners',
    () async {
      final scene = image.Image(width: 600, height: 800);
      image.fill(scene, color: image.ColorRgb8(90, 90, 90));
      expect(await detectEdgesFromImageBytes(_png(scene)), isNull);
      image.fillCircle(
        scene,
        x: 300,
        y: 400,
        radius: 180,
        color: image.ColorRgb8(245, 245, 245),
      );
      expect(await detectEdgesFromImageBytes(_png(scene)), isNull);
    },
  );
  test(
    'clutter and shapes without four supported sides are rejected',
    () async {
      for (final config in [
        EdgeDetectionConfig.fast,
        EdgeDetectionConfig.accurate,
      ]) {
        final scene = image.Image(width: 600, height: 800);
        final background = image.ColorRgb8(45, 45, 45);
        final foreground = image.ColorRgb8(245, 245, 245);
        image.fill(scene, color: background);
        image.fillPolygon(
          scene,
          vertices: [
            image.Point(90, 700),
            image.Point(300, 70),
            image.Point(510, 700),
          ],
          color: foreground,
        );
        expect(
          await detectEdgesFromImageBytes(_png(scene), config: config),
          isNull,
        );
        image.fill(scene, color: background);
        for (var y = 100; y <= 700; y += 150) {
          for (var x = 100; x <= 500; x += 200) {
            image.fillCircle(scene, x: x, y: y, radius: 35, color: foreground);
          }
        }
        expect(
          await detectEdgesFromImageBytes(_png(scene), config: config),
          isNull,
        );
      }
    },
  );
  test(
    'shadow grades and hard boundaries retain ink and faint signatures',
    () async {
      for (final loss in [0.0, .05, .15, .35, .6, .8]) {
        for (final hard in [false, true]) {
          final result = image.decodePng(
            await autoEnhance(_png(_shadow(_page(), loss, hard: hard))),
          )!;
          final blank = [
            for (final p in [(30, 150), (550, 150), (30, 740), (550, 740)])
              _luma(result, p.$1, p.$2),
          ];
          if (loss <= .6) {
            expect(
              blank.reduce(math.min),
              greaterThan(242),
              reason: 'loss=$loss hard=$hard',
            );
            expect(
              blank.reduce(math.max) - blank.reduce(math.min),
              lessThan(12),
            );
          } else {
            expect(blank.reduce(math.min), greaterThan(150));
          }
          expect(_darkest(result, 60, 200, 320, 224), lessThan(90));
          expect(_darkest(result, 300, 685, 400, 730), lessThan(230));
        }
      }
    },
  );
  test('printed gray fills and colored panels survive enhancement', () async {
    final page = _page();
    image.fillRect(
      page,
      x1: 100,
      y1: 250,
      x2: 250,
      y2: 400,
      color: image.ColorRgb8(240, 240, 240),
    );
    image.fillRect(
      page,
      x1: 350,
      y1: 250,
      x2: 500,
      y2: 400,
      color: image.ColorRgb8(50, 100, 180),
    );
    image.fillRect(
      page,
      x1: 100,
      y1: 450,
      x2: 250,
      y2: 560,
      color: image.ColorRgb8(160, 160, 160),
    );
    final output = image.decodePng(await autoEnhance(_png(page)))!;
    expect(_luma(output, 170, 320), lessThan(247));
    expect(_luma(output, 170, 500), lessThan(180));
    final blue = output.getPixel(420, 320);
    expect(blue.b - blue.r, greaterThan(80));
    expect(_luma(output, 420, 320), lessThan(180));
  });
  test('compressed blue text leaves neutral paper between lines', () async {
    final page = _page();
    for (var y = 240; y <= 420; y += 30) {
      image.drawString(
        page,
        'Colored text and readable fine print',
        font: image.arial24,
        x: 60,
        y: y,
        color: image.ColorRgb8(45, 100, 175),
      );
    }
    final shaded = _shadow(page, .55);
    final source = image.decodeJpg(image.encodeJpg(shaded, quality: 78))!;
    final output = image.decodePng(await autoEnhance(_png(source)))!;
    var total = 0.0, chroma = 0.0, samples = 0;
    for (var y = 220; y < 445; y++) {
      for (var x = 55; x < 530; x++) {
        var paper = true;
        for (var dy = -2; dy <= 2 && paper; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final p = page.getPixel(x + dx, y + dy);
            if (p.r != 250 || p.g != 248 || p.b != 245) {
              paper = false;
              break;
            }
          }
        }
        if (!paper) continue;
        final p = output.getPixel(x, y);
        total += _luma(output, x, y);
        chroma +=
            math.max(p.r, math.max(p.g, p.b)) -
            math.min(p.r, math.min(p.g, p.b));
        samples++;
      }
    }
    expect(samples, greaterThan(10000));
    expect(total / samples, greaterThan(252));
    expect(chroma / samples, lessThan(2));
    expect(_darkest(output, 60, 240, 400, 264), lessThan(100));
    expect(_darkest(output, 300, 685, 400, 730), lessThan(230));
  });
  test('uniform dark images use the conservative correction', () async {
    final source = image.Image(width: 240, height: 320);
    image.fill(source, color: image.ColorRgb8(35, 35, 35));
    final bytes = _png(source);
    expect(
      await autoEnhance(bytes),
      await autoEnhance(bytes, reduceShadows: false),
    );
  });
  test(
    'cached profile is bounded and agrees across rotation and switching',
    () async {
      final source = _png(_shadow(_page(), .6));
      final before = Uint8List.fromList(source);
      final profile = await analyzeEnhancement(source);
      expect(profile.width, lessThanOrEqualTo(enhancementAnalysisEdge));
      expect(profile.height, lessThanOrEqualTo(enhancementAnalysisEdge));
      final on = await autoEnhance(source, profile: profile);
      final off = await autoEnhance(
        source,
        profile: profile,
        reduceShadows: false,
      );
      final restored = await autoEnhance(source, profile: profile);
      expect(restored, on);
      expect(source, before);
      expect(
        _luma(image.decodePng(on)!, 30, 740) -
            _luma(image.decodePng(off)!, 30, 740),
        greaterThan(50),
      );
      final rotated = image.decodePng(await rotateImage(on, 1))!;
      expect(
        _luma(rotated, 800 - 1 - 740, 30),
        _luma(image.decodePng(on)!, 30, 740),
      );
      final gray = image.decodePng(await toGrayscale(on))!;
      expect(gray.numChannels, 1);
    },
  );
  test('large exports retain size with bounded analysis', () async {
    final large = image.copyResize(
      _shadow(_page(), .6),
      width: 2400,
      height: 3200,
    );
    final bytes = _png(large);
    final watch = Stopwatch()..start();
    final profile = await analyzeEnhancement(bytes);
    expect(math.max(profile.width, profile.height), lessThanOrEqualTo(768));
    final output = image.decodePng(await autoEnhance(bytes, profile: profile))!;
    expect(output.width, 2400);
    expect(output.height, 3200);
    expect(_luma(output, 100, 3000), greaterThan(240));
    debugPrint('7.7MP analysis+render: ${watch.elapsedMilliseconds}ms');
  });
  testWidgets('preview defaults shadows on and persists the disabled choice', (
    tester,
  ) async {
    final bytes = _png(_page());
    ImageEditResult? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: ImageEditView(
          originalImageBytes: bytes,
          originalImageSize: const Size(600, 800),
          initialCropFrame: DocumentFrame(
            topLeft: Offset.zero,
            topRight: const Offset(599, 0),
            bottomRight: const Offset(599, 799),
            bottomLeft: const Offset(0, 799),
          ),
          initialCroppedBytes: bytes,
          onConfirmed: (value) => confirmed = value,
          onCancelled: () {},
          isNewCapture: true,
        ),
      ),
    );
    expect(find.text('Reduce shadows'), findsNothing);
    await tester.tap(find.text('Enhance'));
    // A second input can arrive before the disabled controls have rebuilt.
    await tester.tap(find.text('Enhance'));
    await _waitForProcessing(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('Reduce shadows'));
    await _waitForProcessing(tester);
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(confirmed!.reduceShadows, isFalse);
    expect(confirmed!.enhanced, isTrue);
    final expected = await tester.runAsync(
      () => autoEnhance(bytes, reduceShadows: false),
    );
    expect(confirmed!.editedBytes, expected);
  });
}

Future<void> _waitForProcessing(WidgetTester tester) async {
  await tester.pump();
  for (
    var i = 0;
    i < 750 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
}
