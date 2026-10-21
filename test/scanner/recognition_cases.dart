import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile_document_scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';

import 'recognition_reference.dart';

Map<String, image.Image> recognitionScenes() {
  final scenes = <String, image.Image>{};
  image.Image scene() {
    final picture = image.Image(width: 1200, height: 1000);
    image.fill(picture, color: image.ColorRgb8(48, 52, 55));
    return picture;
  }

  for (final entry in <String, List<image.Point>>{
    'steep_keystone': [
      image.Point(490, 80),
      image.Point(780, 100),
      image.Point(1100, 900),
      image.Point(80, 850),
    ],
    'rotated_page': [
      image.Point(400, 50),
      image.Point(1100, 450),
      image.Point(800, 950),
      image.Point(100, 550),
    ],
    'reverse_skew': [
      image.Point(100, 260),
      image.Point(1000, 60),
      image.Point(950, 910),
      image.Point(400, 800),
    ],
    'narrow_skewed_receipt': [
      image.Point(510, 55),
      image.Point(690, 100),
      image.Point(850, 940),
      image.Point(490, 900),
    ],
    'off_center_page': [
      image.Point(40, 160),
      image.Point(630, 40),
      image.Point(760, 850),
      image.Point(65, 920),
    ],
  }.entries) {
    final picture = scene();
    image.fillPolygon(
      picture,
      vertices: entry.value,
      color: image.ColorRgb8(238, 235, 228),
    );
    scenes[entry.key] = picture;
  }

  final shaded = image.Image.from(scenes['reverse_skew']!);
  for (final p in shaded) {
    final gain = .5 + .5 * p.x / shaded.width;
    p.r = (p.r * gain).round();
    p.g = (p.g * gain).round();
    p.b = (p.b * gain).round();
  }
  image.fillCircle(
    shaded,
    x: 70,
    y: 60,
    radius: 35,
    color: image.ColorRgb8(245, 245, 245),
  );
  image.fillRect(
    shaded,
    x1: 1070,
    y1: 250,
    x2: 1150,
    y2: 700,
    color: image.ColorRgb8(100, 100, 100),
  );
  scenes['shadow_and_clutter'] = shaded;

  final lowContrast = scene();
  image.fill(lowContrast, color: image.ColorRgb8(193, 193, 193));
  image.fillPolygon(
    lowContrast,
    vertices: [
      image.Point(140, 130),
      image.Point(980, 90),
      image.Point(1080, 900),
      image.Point(80, 840),
    ],
    color: image.ColorRgb8(213, 213, 213),
  );
  scenes['faint_page_edges'] = lowContrast;

  final patches = scene();
  for (final x in [150, 600]) {
    image.fillRect(
      patches,
      x1: x,
      y1: 350,
      x2: x + 220,
      y2: 560,
      color: image.ColorRgb8(220, 220, 220),
    );
  }
  scenes['small_background_patches'] = patches;

  final broken = scene();
  image.drawRect(
    broken,
    x1: 200,
    y1: 170,
    x2: 1000,
    y2: 850,
    thickness: 30,
    color: image.ColorRgb8(235, 235, 235),
  );
  for (final y in [170, 850]) {
    image.fillRect(
      broken,
      x1: 595,
      y1: y - 25,
      x2: 605,
      y2: y + 25,
      color: image.ColorRgb8(48, 52, 55),
    );
  }
  for (final x in [200, 1000]) {
    image.fillRect(
      broken,
      x1: x - 25,
      y1: 505,
      x2: x + 25,
      y2: 515,
      color: image.ColorRgb8(48, 52, 55),
    );
  }
  scenes['disconnected_background_lines'] = broken;

  final texture = scene();
  final random = math.Random(20261021);
  for (final p in texture) {
    final shade = 150 + random.nextInt(81);
    p.r = shade;
    p.g = shade;
    p.b = shade;
  }
  scenes['texture_without_document'] = texture;
  return scenes;
}

void registerRecognitionTests() {
  for (final entry in recognitionScenes().entries) {
    test('native four-point recognition: ${entry.key}', () async {
      final exportDirectory = Platform.environment['SCANNER_FIXTURE_EXPORT'];
      final bytes = image.encodePng(entry.value);
      if (exportDirectory != null) {
        await Directory(exportDirectory).create(recursive: true);
        await File('$exportDirectory/${entry.key}.png').writeAsBytes(bytes);
      }
      if (Platform.environment['SCANNER_FIXTURE_EXPORT_ONLY'] == '1') return;
      final expected = nativeRecognitionCorners[entry.key];
      expect(
        nativeRecognitionCorners.containsKey(entry.key),
        isTrue,
        reason: entry.key,
      );
      final actual = await detectEdgesFromImageBytes(bytes);
      if (expected == null) {
        expect(actual, isNull, reason: entry.key);
      } else {
        expect(actual, isNotNull, reason: entry.key);
        final corners = [
          actual!.topLeft,
          actual.topRight,
          actual.bottomRight,
          actual.bottomLeft,
        ];
        for (var i = 0; i < 4; i++) {
          final reference = Offset(expected[i].dx * 1199, expected[i].dy * 999);
          expect(
            (corners[i] - reference).distance,
            lessThan(3),
            reason: '${entry.key} corner $i',
          );
        }
      }
    });
  }
  test(
    'live recognition keeps the same document and releases it after loss',
    () async {
      image.Image scene({bool target = true, bool distractor = false}) {
        final picture = image.Image(width: 1200, height: 1000);
        image.fill(picture, color: image.ColorRgb8(48, 52, 55));
        if (target) {
          image.fillRect(
            picture,
            x1: 80,
            y1: 180,
            x2: 500,
            y2: 800,
            color: image.ColorRgb8(238, 235, 228),
          );
        }
        if (distractor) {
          image.fillRect(
            picture,
            x1: 650,
            y1: 80,
            x2: 1120,
            y2: 900,
            color: image.ColorRgb8(238, 235, 228),
          );
        }
        return picture;
      }

      final runner = EdgeDetectionRunner();
      await runner.start();
      Future<DetectionOutcome?> detect(
        image.Image picture, {
        int rotation = 0,
      }) => runner.detect(
        rgbaBytes: picture.getBytes(order: image.ChannelOrder.rgba),
        width: picture.width,
        height: picture.height,
        rotationCompensation: rotation,
      );
      try {
        final initial = await detect(scene()) as FrameDetected;
        expect(initial.frame.topLeft.dx, closeTo(80, 3));
        final withClutter =
            await detect(scene(distractor: true)) as FrameDetected;
        expect(withClutter.frame.topLeft.dx, closeTo(80, 3));
        final lost = await detect(scene(target: false));
        expect(lost, isA<FrameNotFound>());
        final afterLoss =
            await detect(scene(distractor: true)) as FrameDetected;
        expect(afterLoss.frame.topLeft.dx, closeTo(650, 3));
        // A moved page must be acquired instead of being locked to old corners.
        final moved = await detect(scene()) as FrameDetected;
        expect(moved.frame.topLeft.dx, closeTo(80, 3));
        final rotated = await detect(scene(), rotation: 90) as FrameDetected;
        expect(rotated.imageSize, const Size(1000, 1200));
        expect(rotated.frame.topLeft.dx, closeTo(199, 4));
        expect(rotated.frame.topLeft.dy, closeTo(80, 4));
      } finally {
        runner.dispose();
      }
    },
  );
  test('luminance extraction excludes camera padding and chroma', () {
    final padded = Uint8List.fromList([
      10,
      99,
      20,
      99,
      30,
      99,
      255,
      255,
      40,
      99,
      50,
      99,
      60,
    ]);
    final before = Uint8List.fromList(padded);
    expect(
      copyCameraLuma(
        padded,
        width: 3,
        height: 2,
        bytesPerRow: 8,
        bytesPerPixel: 2,
      ),
      [10, 20, 30, 40, 50, 60],
    );
    expect(padded, before);
    expect(
      copyCameraLuma(
        Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90]),
        width: 3,
        height: 3,
        bytesPerRow: 4,
      ),
      [10, 20, 30, 40, 50, 60, 70, 80, 90],
    );
  });
  test(
    'invalid luminance planes are skipped instead of manufacturing edges',
    () {
      expect(
        copyCameraLuma(Uint8List(3), width: 3, height: 2, bytesPerRow: 3),
        isNull,
      );
      expect(
        copyCameraLuma(Uint8List(12), width: 4, height: 3, bytesPerRow: 3),
        isNull,
      );
      expect(
        copyCameraLuma(Uint8List(12), width: 0, height: 3, bytesPerRow: 4),
        isNull,
      );
    },
  );
  test(
    'luminance frames retain four corners and rotation through the live worker',
    () async {
      final scene = recognitionScenes()['steep_keystone']!;
      final luma = Uint8List(scene.width * scene.height);
      for (final pixel in scene) {
        luma[pixel.y * scene.width + pixel.x] =
            (pixel.r * .299 + pixel.g * .587 + pixel.b * .114).round();
      }
      final runner = EdgeDetectionRunner();
      await runner.start();
      try {
        final watch = Stopwatch()..start();
        for (var i = 0; i < 5; i++) {
          final outcome = await runner.detect(
            rgbaBytes: luma,
            width: scene.width,
            height: scene.height,
            rotationCompensation: 0,
            channels: 1,
          );
          expect(outcome, isA<FrameDetected>());
          final actual = (outcome as FrameDetected).frame;
          final expected = nativeRecognitionCorners['steep_keystone']!;
          expect(
            (actual.topLeft -
                    Offset(expected[0].dx * 1199, expected[0].dy * 999))
                .distance,
            lessThan(3),
          );
        }
        // Report throughput without imposing a device-dependent timing threshold.
        // ignore: avoid_print
        print(
          '960px live luminance analysis: ${watch.elapsedMilliseconds / 5}ms/frame',
        );
        final invalid = await runner.detect(
          rgbaBytes: Uint8List(3),
          width: 1200,
          height: 1000,
          rotationCompensation: 0,
          channels: 1,
        );
        expect(invalid, isA<FrameNotFound>());
        final rotated = await runner.detect(
          rgbaBytes: luma,
          width: scene.width,
          height: scene.height,
          rotationCompensation: 90,
          channels: 1,
        );
        expect((rotated as FrameDetected).imageSize, const Size(1000, 1200));
      } finally {
        runner.dispose();
      }
    },
  );
}
