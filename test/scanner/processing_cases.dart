import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile_document_scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile_document_scanner/models/scan_result.dart';
import 'package:paperless_mobile_document_scanner/processing/color_enhancement.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';
import 'package:paperless_mobile_document_scanner/processing/frame_stability_tracker.dart';
import 'package:paperless_mobile_document_scanner/processing/image_edit.dart';
import 'package:paperless_mobile_document_scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile_document_scanner/view/edge_adjustment_view.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';

class _DelayedImageFile implements File {
  final read = Completer<Uint8List>();
  @override
  Future<Uint8List> readAsBytes() => read.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
            EdgeDetectionConfig.fourPoint,
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
      EdgeDetectionConfig.fourPoint,
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
    'clutter and shapes without four supported sides are rejected',
    () async {
      for (final config in [
        EdgeDetectionConfig.fourPoint,
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
  testWidgets(
    'large cropped edits confirm full-size pixels beside a thumbnail',
    (tester) async {
      final source = image.Image(width: 2160, height: 3840);
      image.fill(source, color: image.ColorRgb8(245, 245, 245));
      image.drawString(
        source,
        'Fine print 0123456789',
        font: image.arial14,
        x: 300,
        y: 400,
        color: image.ColorRgb8(35, 35, 35),
      );
      final original = _png(source);
      final frame = DocumentFrame(
        topLeft: const Offset(100, 200),
        topRight: const Offset(2060, 200),
        bottomRight: const Offset(2060, 3640),
        bottomLeft: const Offset(100, 3640),
      );
      final cropped = (await tester.runAsync(
        () => perspectiveTransform(imageBytes: original, frame: frame),
      ))!;
      ImageEditResult? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: ImageEditView(
            originalImageBytes: original,
            originalImageSize: const Size(2160, 3840),
            initialCropFrame: frame,
            initialCroppedBytes: cropped,
            initialEnhanced: true,
            initialQuarterTurns: 1,
            initialColorFilter: ScanColorFilter.greyscale,
            onConfirmed: (result) => confirmed = result,
            onCancelled: () {},
            isNewCapture: true,
          ),
        ),
      );
      await _waitForProcessing(tester);
      final preview =
          tester.widget<Image>(find.byType(Image)).image as MemoryImage;
      await tester.tap(find.text('Apply'));
      expect(confirmed!.editedBytes, preview.bytes);
      final result = confirmed!;
      final thumbnail = (await tester.runAsync(
        () => generateThumbnail(result.editedBytes),
      ))!;
      final small = image.decodePng(thumbnail)!;
      expect(math.max(small.width, small.height), 200);
      final rendered = image.decodePng(result.editedBytes)!;
      expect((rendered.width, rendered.height), (3441, 1961));
      expect(rendered.numChannels, 1);
      // The 14px text must remain visible after crop, enhancement and rotation.
      expect(_darkest(rendered, 3200, 195, 3250, 365), lessThan(100));
      expect(result.editedBytes, preview.bytes);
      expect(
        (image.decodePng(original)!.width, image.decodePng(original)!.height),
        (2160, 3840),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'closing a re-edit while its file loads ignores late processing',
    (tester) async {
      final file = _DelayedImageFile();
      await tester.pumpWidget(
        MaterialApp(
          home: ImageEditView(
            originalImageFile: file,
            originalImageSize: const Size(600, 800),
            initialCropFrame: DocumentFrame(
              topLeft: Offset.zero,
              topRight: const Offset(599, 0),
              bottomRight: const Offset(599, 799),
              bottomLeft: const Offset(0, 799),
            ),
            initialEnhanced: true,
            onConfirmed: (_) =>
                fail('A closed editor must not confirm an image.'),
            onCancelled: () {},
            isNewCapture: false,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      file.read.complete(_png(_page()));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview defaults shadows on and persists the disabled choice', (
    tester,
  ) async {
    final bytes = _png(_page());
    ImageEditResult? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
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
    await _waitForProcessing(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    final previewRect = tester.getRect(find.byType(Image));
    await tester.tap(find.text('Enhance'));
    await _waitForProcessing(tester);
    expect(find.text('Reduce shadows'), findsNothing);
    expect(tester.getRect(find.byType(Image)), previewRect);
    await tester.tap(find.text('Enhance'));
    // A second input can arrive before the disabled controls have rebuilt.
    await tester.tap(find.text('Enhance'));
    await _waitForProcessing(tester);
    expect(tester.getRect(find.byType(Image)), previewRect);
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
  testWidgets('re-edit restores saved choices and saves the displayed pixels', (
    tester,
  ) async {
    final original = _png(_shadow(_page(), .6));
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('alpha2_reedit_'),
    ))!;
    final file = (await tester.runAsync(
      () => File('${directory.path}/original.png').writeAsBytes(original),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final scan = ScanResult(
      originalFile: file,
      outputFile: File('${directory.path}/edited.png'),
      originalImageSize: const Size(600, 800),
      cropFrame: DocumentFrame(
        topLeft: Offset.zero,
        topRight: const Offset(599, 0),
        bottomRight: const Offset(599, 799),
        bottomLeft: const Offset(0, 799),
      ),
      quarterTurns: 1,
      colorFilter: ScanColorFilter.greyscale,
      bwThreshold: 10,
      enhanced: true,
      reduceShadows: false,
      thumbnailBytes: Uint8List(0),
    );
    ImageEditResult? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ImageEditView(
          originalImageFile: scan.originalFile,
          originalImageSize: scan.originalImageSize,
          initialCropFrame: scan.cropFrame,
          initialQuarterTurns: scan.quarterTurns,
          initialColorFilter: scan.colorFilter,
          initialBwThreshold: scan.bwThreshold,
          initialEnhanced: scan.enhanced,
          initialReduceShadows: scan.reduceShadows,
          onConfirmed: (value) => confirmed = value,
          onCancelled: () {},
          isNewCapture: false,
        ),
      ),
    );
    await _waitForProcessing(tester);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    final preview =
        tester.widget<Image>(find.byType(Image)).image as MemoryImage;
    await tester.tap(find.text('Apply'));
    expect(confirmed!.quarterTurns, 1);
    expect(confirmed!.colorFilter, ScanColorFilter.greyscale);
    expect(confirmed!.enhanced, isTrue);
    expect(confirmed!.reduceShadows, isFalse);
    expect(confirmed!.editedBytes, preview.bytes);
    final rendered = image.decodePng(confirmed!.editedBytes)!;
    expect(rendered.width, 800);
    expect(rendered.height, 600);
    expect(rendered.numChannels, 1);
    expect(await tester.runAsync(file.readAsBytes), original);
  });
  testWidgets('committing a new crop invalidates the shadow analysis', (
    tester,
  ) async {
    final original = _png(_shadow(_page(), .6));
    final initialFrame = DocumentFrame(
      topLeft: Offset.zero,
      topRight: const Offset(599, 0),
      bottomRight: const Offset(599, 799),
      bottomLeft: const Offset(0, 799),
    );
    final newFrame = DocumentFrame(
      topLeft: const Offset(100, 80),
      topRight: const Offset(500, 80),
      bottomRight: const Offset(500, 600),
      bottomLeft: const Offset(100, 600),
    );
    final newCrop = (await tester.runAsync(
      () => perspectiveTransform(imageBytes: original, frame: newFrame),
    ))!;
    final expected = (await tester.runAsync(() => autoEnhance(newCrop)))!;
    final stale = await tester.runAsync(
      () async =>
          autoEnhance(newCrop, profile: await analyzeEnhancement(original)),
    );
    expect(
      stale,
      isNot(expected),
      reason: 'The fixture must expose a stale crop profile.',
    );
    ImageEditResult? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: ImageEditView(
          originalImageBytes: original,
          originalImageSize: const Size(600, 800),
          initialCropFrame: initialFrame,
          initialCroppedBytes: original,
          initialEnhanced: true,
          onConfirmed: (value) => confirmed = value,
          onCancelled: () {},
          isNewCapture: true,
        ),
      ),
    );
    await _waitForProcessing(tester);
    await tester.tap(find.text('Crop'));
    await tester.pumpAndSettle();
    tester
        .widget<EdgeAdjustmentView>(find.byType(EdgeAdjustmentView))
        .onConfirmed(newCrop, newFrame);
    await _waitForProcessing(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    expect(confirmed!.cropFrame, same(newFrame));
    expect(confirmed!.editedBytes, expected);
    expect(confirmed!.reduceShadows, isTrue);
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
