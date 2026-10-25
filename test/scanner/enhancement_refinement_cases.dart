import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile_document_scanner/processing/color_enhancement.dart';

Uint8List _png(image.Image picture) =>
    Uint8List.fromList(image.encodePng(picture));

double _darkness(image.Pixel pixel) => 255 - (pixel.r + pixel.g + pixel.b) / 3;

EnhancementProfile _withoutCleanup(EnhancementProfile profile) =>
    EnhancementProfile(
      profile.width,
      profile.height,
      profile.paper,
      profile.protection,
      profile.contrast,
    );

image.Image _contentPage() {
  final page = image.Image(width: 480, height: 640);
  image.fill(page, color: image.ColorRgb8(255, 255, 255));
  for (final y in [65, 130, 195]) {
    image.drawString(
      page,
      'Total',
      font: image.arial24,
      x: 38,
      y: y,
      color: image.ColorRgb8(40, 40, 40),
    );
    image.drawString(
      page,
      '123.45,67: !',
      font: image.arial24,
      x: 105,
      y: y,
      color: image.ColorRgb8(223, 223, 223),
    );
  }
  // A pale table crosses its vertical dividers; continuity matters at crossings.
  for (final y in [280, 315, 350]) {
    image.drawLine(
      page,
      x1: 38,
      y1: y,
      x2: 330,
      y2: y,
      color: image.ColorRgb8(228, 228, 228),
    );
  }
  for (final x in [38, 170, 330]) {
    image.drawLine(
      page,
      x1: x,
      y1: 280,
      x2: x,
      y2: 350,
      color: image.ColorRgb8(228, 228, 228),
    );
  }
  // Sparse, curved handwriting is distinct from a filled dirt patch.
  for (var x = 45; x < 285; x++) {
    final y = (430 + 9 * math.sin(x / 11) + 4 * math.sin(x / 3)).round();
    image.drawLine(
      page,
      x1: x,
      y1: y,
      x2: x + 1,
      y2: (430 + 9 * math.sin((x + 1) / 11) + 4 * math.sin((x + 1) / 3))
          .round(),
      color: image.ColorRgb8(224, 224, 224),
    );
  }
  return page;
}

/// Shared by the desktop suite and the Android processing harness.
void registerEnhancementRefinementTests() {
  test(
    'one pixel pale rules crossing dirt retain local contrast after analysis downsampling',
    () async {
      for (final amplitude in [12, 25]) {
        final source = image.Image(width: 1152, height: 1536);
        for (final pixel in source) {
          final dx = (pixel.x - 250) / 100;
          final dy = (pixel.y - 400) / 60;
          final value = (250 - 23 * math.exp(-dx * dx - dy * dy)).round();
          final ink = pixel.y == 400 && pixel.x >= 200 && pixel.x <= 300
              ? amplitude
              : 0;
          pixel.setRgb(value - ink, value - ink, value - ink);
        }
        final bytes = _png(source);
        final profile = await analyzeEnhancement(bytes);
        final before = image.decodePng(
          await enhanceDocument(bytes, profile: _withoutCleanup(profile)),
        )!;
        final after = image.decodePng(
          await enhanceDocument(bytes, profile: profile),
        )!;
        var baselineContrast = 0.0;
        var retainedContrast = 0.0;
        var coverage = 0;
        double localContrast(image.Image picture, int x) =>
            _darkness(picture.getPixel(x, 400)) -
            (_darkness(picture.getPixel(x, 396)) +
                    _darkness(picture.getPixel(x, 404))) /
                2;
        for (var x = 200; x <= 300; x++) {
          final original = localContrast(before, x);
          final actual = localContrast(after, x);
          baselineContrast += original;
          retainedContrast += actual;
          if (actual >= original * .95) coverage++;
        }
        expect(baselineContrast, greaterThan(500));
        expect(
          retainedContrast / baselineContrast,
          greaterThanOrEqualTo(.95),
          reason: 'rule amplitude $amplitude',
        );
        expect(
          coverage / 101,
          greaterThanOrEqualTo(.99),
          reason: 'rule amplitude $amplitude',
        );
      }
    },
  );

  test(
    'cleanup reduces isolated dirt and an irregular fold by at least thirty percent',
    () async {
      final source = _contentPage();
      image.fillCircle(
        source,
        x: 130,
        y: 550,
        radius: 30,
        color: image.ColorRgb8(230, 230, 230),
      );
      for (var y = 385; y <= 600; y++) {
        final center = 380 + (4 * math.sin(y / 17)).round();
        final halfWidth = 15 + (5 * math.sin(y / 11)).round();
        image.drawLine(
          source,
          x1: center - halfWidth,
          y1: y,
          x2: center + halfWidth,
          y2: y,
          color: image.ColorRgb8(225, 225, 225),
        );
      }
      final bytes = _png(source);
      final profile = await analyzeEnhancement(bytes);
      final before = image.decodePng(
        await enhanceDocument(bytes, profile: _withoutCleanup(profile)),
      )!;
      final after = image.decodePng(
        await enhanceDocument(bytes, profile: profile),
      )!;
      for (final region in [(120, 540, 140, 560), (378, 470, 382, 540)]) {
        var initial = 0.0;
        var residual = 0.0;
        for (var y = region.$2; y <= region.$4; y++) {
          for (var x = region.$1; x <= region.$3; x++) {
            initial += _darkness(before.getPixel(x, y));
            residual += _darkness(after.getPixel(x, y));
          }
        }
        expect(initial, greaterThan(1000), reason: 'fixed region $region');
        expect(
          1 - residual / initial,
          greaterThanOrEqualTo(.30),
          reason: '$region',
        );
      }
    },
  );

  test(
    'full resolution cleanup rechecks darkness and color and bounds the lift',
    () async {
      // A deliberately permissive map exercises the renderer's independent guard:
      // downsampling must never permit cleanup of unseen dark or colored pixels.
      final source = image.Image(width: 1001, height: 769);
      final colors = [
        image.ColorRgb8(230, 230, 230),
        image.ColorRgb8(185, 185, 185),
        image.ColorRgb8(235, 200, 200),
        image.ColorRgb8(252, 252, 252),
        image.ColorRgb8(228, 231, 234),
        image.ColorRgb8(210, 210, 210),
      ];
      for (final pixel in source) {
        final color = colors[(pixel.x ~/ 167).clamp(0, 5)];
        pixel.setRgb(color.r, color.g, color.b);
      }
      final bytes = _png(source);
      final paper = Uint8List(12)..fillRange(0, 12, 255);
      final confidence = Uint8List(4)..fillRange(0, 4, 255);
      final base = EnhancementProfile(2, 2, paper, null, 1);
      final cleaned = EnhancementProfile(
        2,
        2,
        paper,
        null,
        1,
        cleanup: confidence,
      );
      final before = image.decodePng(
        await enhanceDocument(bytes, profile: base),
      )!;
      final after = image.decodePng(
        await enhanceDocument(bytes, profile: cleaned),
      )!;
      final neutralBefore = before.getPixel(100, 400);
      final neutralAfter = after.getPixel(100, 400);
      final lift = neutralAfter.r - neutralBefore.r;
      expect(lift, greaterThan(0));
      expect(lift, lessThanOrEqualTo(20));
      expect(lift, lessThanOrEqualTo((255 - neutralBefore.r) * .5 + .5));
      for (final x in [250, 420, 580]) {
        final oldPixel = before.getPixel(x, 400);
        final newPixel = after.getPixel(x, 400);
        expect(newPixel.r, oldPixel.r, reason: 'guarded pixel $x');
        expect(newPixel.g, oldPixel.g);
        expect(newPixel.b, oldPixel.b);
      }
      final cappedLift =
          after.getPixel(920, 400).r - before.getPixel(920, 400).r;
      expect(cappedLift, greaterThan(0));
      expect(cappedLift, lessThanOrEqualTo(20));
      final tintedBefore = before.getPixel(750, 400);
      final tintedAfter = after.getPixel(750, 400);
      final ratios = [
        (255 - tintedAfter.r) / (255 - tintedBefore.r),
        (255 - tintedAfter.g) / (255 - tintedBefore.g),
        (255 - tintedAfter.b) / (255 - tintedBefore.b),
      ];
      expect(ratios.reduce(math.max) - ratios.reduce(math.min), lessThan(.05));
      expect(source.width, greaterThan(enhancementAnalysisEdge));
      expect(source.height, greaterThan(enhancementAnalysisEdge));
    },
  );

  test(
    'thin red strips remain protected at page edges and inset positions',
    () async {
      for (final inset in [0, 23]) {
        for (final compressed in [false, true]) {
          for (final warm in [false, true]) {
            final page = image.Image(width: 480, height: 640);
            image.fill(page, color: image.ColorRgb8(251, 250, 249));
            image.fillRect(
              page,
              x1: 0,
              y1: inset,
              x2: 479,
              y2: inset + 2,
              color: image.ColorRgb8(211, 30, 33),
            );
            image.drawString(
              page,
              'Account 123.45',
              font: image.arial24,
              x: 45,
              y: 90,
              color: image.ColorRgb8(35, 35, 35),
            );
            for (final pixel in page) {
              final loss = .42 / (1 + math.exp((pixel.x / 480 - .5) * 12));
              final shade = 1 - loss;
              pixel.r = (pixel.r * shade * (warm ? 1 : .87)).round();
              pixel.g = (pixel.g * shade * .95).round();
              pixel.b = (pixel.b * shade * (warm ? .87 : 1)).round();
            }
            final bytes = compressed
                ? Uint8List.fromList(image.encodeJpg(page, quality: 76))
                : _png(page);
            final profile = await analyzeEnhancement(bytes);
            final result = image.decodePng(
              await enhanceDocument(bytes, profile: profile),
            )!;
            final reason = 'inset=$inset jpeg=$compressed warm=$warm';
            expect(profile.paper, isNotNull, reason: reason);
            var protected = 0;
            var red = 0;
            for (var x = 20; x < 460; x++) {
              if (profile.protection![(inset + 1) * 480 + x] != 0) protected++;
              final pixel = result.getPixel(x, inset + 1);
              if (pixel.r - math.max(pixel.g, pixel.b) >= 70) red++;
            }
            expect(protected / 440, greaterThanOrEqualTo(.99), reason: reason);
            expect(red / 440, greaterThanOrEqualTo(.99), reason: reason);
          }
        }
      }
    },
  );

  test(
    'cleanup retains faint glyphs, punctuation, signatures and table rules',
    () async {
      final source = _contentPage();
      final bytes = _png(source);
      final profile = await analyzeEnhancement(bytes);
      final before = image.decodePng(
        await enhanceDocument(bytes, profile: _withoutCleanup(profile)),
      )!;
      final after = image.decodePng(
        await enhanceDocument(bytes, profile: profile),
      )!;
      var faintCount = 0;
      var retained = 0;
      var originalContrast = 0.0;
      var actualContrast = 0.0;
      for (final pixel in source) {
        if (pixel.r < 90) {
          final oldPixel = before.getPixel(pixel.x, pixel.y);
          final newPixel = after.getPixel(pixel.x, pixel.y);
          expect(
            newPixel.r,
            oldPixel.r,
            reason: 'dark core ${pixel.x},${pixel.y}',
          );
          expect(newPixel.g, oldPixel.g);
          expect(newPixel.b, oldPixel.b);
        }
        if (pixel.r < 210 || pixel.r > 240) continue;
        final original = _darkness(before.getPixel(pixel.x, pixel.y));
        if (original < 2) continue;
        final actual = _darkness(after.getPixel(pixel.x, pixel.y));
        faintCount++;
        if (actual >= original * .95) retained++;
        originalContrast += original;
        actualContrast += actual;
      }
      expect(faintCount, greaterThan(1000));
      expect(retained / faintCount, greaterThanOrEqualTo(.99));
      expect(actualContrast / originalContrast, greaterThanOrEqualTo(.95));
      // Every rule pixel must survive; aggregate scores cannot hide broken rules.
      for (final y in [280, 315, 350]) {
        for (var x = 38; x <= 330; x++) {
          final old = _darkness(before.getPixel(x, y));
          expect(
            _darkness(after.getPixel(x, y)),
            greaterThanOrEqualTo(old * .95),
          );
        }
      }
    },
  );

  test('cleanup profile reuse preserves toggles and source bytes', () async {
    final source = _png(_contentPage());
    final original = Uint8List.fromList(source);
    final profile = await analyzeEnhancement(source);
    expect(profile.cleanup?.length, profile.width * profile.height);
    final on = await enhanceDocument(source, profile: profile);
    final off = await enhanceDocument(
      source,
      profile: profile,
      reduceShadows: false,
    );
    expect(off, await enhanceDocument(source, reduceShadows: false));
    expect(await enhanceDocument(source, profile: profile), on);
    expect(source, original);
  });
}
