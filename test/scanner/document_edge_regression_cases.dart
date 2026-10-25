import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:paperless_mobile_document_scanner/models/debug_stage.dart';
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/models/edge_detection_config.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile_document_scanner/processing/edge_detection_isolate.dart';

image.Image _nestedScene({
  int cut = 100,
  Rect background = const Rect.fromLTRB(18, 18, 582, 782),
  Rect page = const Rect.fromLTRB(170, 220, 440, 670),
}) {
  final scene = image.Image(width: 600, height: 800);
  image.fill(scene, color: image.ColorRgb8(30, 30, 30));
  image.fillPolygon(
    scene,
    vertices: [
      image.Point(background.left.toInt(), background.top.toInt()),
      image.Point(background.right.toInt() - cut, background.top.toInt()),
      image.Point(background.right.toInt(), background.top.toInt() + cut),
      image.Point(background.right.toInt(), background.bottom.toInt()),
      image.Point(background.left.toInt(), background.bottom.toInt()),
    ],
    color: image.ColorRgb8(100, 100, 100),
  );
  image.fillRect(
    scene,
    x1: page.left.toInt(),
    y1: page.top.toInt(),
    x2: page.right.toInt(),
    y2: page.bottom.toInt(),
    color: image.ColorRgb8(240, 240, 240),
  );
  return scene;
}

List<Offset> _corners(DocumentFrame frame) => [
  frame.topLeft,
  frame.topRight,
  frame.bottomRight,
  frame.bottomLeft,
];

void _expectPage(DocumentFrame? frame, Rect page, String reason) {
  expect(frame, isNotNull, reason: reason);
  final expected = [
    page.topLeft,
    page.topRight,
    page.bottomRight,
    page.bottomLeft,
  ];
  final actual = _corners(frame!);
  for (var i = 0; i < 4; i++) {
    expect(
      (actual[i] - expected[i]).distance,
      lessThan(20),
      reason: '$reason corner=$i actual=$frame',
    );
  }
}

Future<DocumentFrame?> _live(
  image.Image scene,
  EdgeDetectionConfig config,
) async {
  final rgba = cv.Mat.fromList(
    scene.height,
    scene.width,
    cv.MatType.CV_8UC4,
    scene.getBytes(order: image.ChannelOrder.rgba),
  );
  try {
    final (frame, debug) = await detectDocumentEdges(rgba, config: config);
    debug?.dispose();
    return frame;
  } finally {
    rgba.dispose();
  }
}

image.Image _foldedScene({
  int corner = 3,
  double fold = .28,
  bool shadow = false,
  bool receipt = false,
  bool landscape = false,
}) {
  final points = landscape
      ? [
          const Offset(40, 240),
          const Offset(560, 240),
          const Offset(560, 560),
          const Offset(40, 560),
        ]
      : receipt
      ? [
          const Offset(230, 60),
          const Offset(370, 60),
          const Offset(370, 740),
          const Offset(230, 740),
        ]
      : [
          const Offset(95, 70),
          const Offset(510, 100),
          const Offset(550, 700),
          const Offset(60, 740),
        ];
  final scene = image.Image(width: 600, height: 800);
  image.fill(scene, color: image.ColorRgb8(45, 45, 45));
  image.fillPolygon(
    scene,
    vertices: [
      for (final p in points) image.Point(p.dx.toInt() + 5, p.dy.toInt() + 5),
    ],
    color: image.ColorRgb8(165, 165, 165),
  );
  image.fillPolygon(
    scene,
    vertices: [for (final p in points) image.Point(p.dx.toInt(), p.dy.toInt())],
    color: image.ColorRgb8(245, 245, 245),
  );
  final a = Offset.lerp(points[corner], points[(corner + 3) % 4], fold)!;
  final b = Offset.lerp(points[corner], points[(corner + 1) % 4], fold)!;
  image.fillPolygon(
    scene,
    vertices: [
      image.Point(points[corner].dx.toInt(), points[corner].dy.toInt()),
      image.Point(a.dx.round(), a.dy.round()),
      image.Point(b.dx.round(), b.dy.round()),
    ],
    color: image.ColorRgb8(45, 45, 45),
  );
  if (shadow) {
    for (final p in scene) {
      final distance = p.x / scene.width + .3 * p.y / scene.height - .7;
      final factor = 1 - .25 / (1 + math.exp(distance * 15));
      p.r = (p.r * factor).round();
      p.g = (p.g * factor).round();
      p.b = (p.b * factor).round();
    }
  }
  return scene;
}

void registerDocumentEdgeRegressionTests() {
  test(
    'a shaded landscape fold extends its corner while retaining three anchors',
    () async {
      final scene = _foldedScene(corner: 0, shadow: true, landscape: true);
      final live = await _live(scene, EdgeDetectionConfig.fourPoint);
      final still = await detectEdgesFromImageBytes(
        Uint8List.fromList(image.encodePng(scene)),
      );
      expect(live, isNotNull);
      expect(still, isNotNull);
      for (final i in [1, 2, 3]) {
        expect(_corners(still!)[i], _corners(live!)[i]);
      }
      expect((still!.topLeft - const Offset(40, 240)).distance, lessThan(20));
    },
  );
  test(
    'captured fold repair keeps the other three live corners unchanged',
    () async {
      const expected = [
        Offset(95, 70),
        Offset(510, 100),
        Offset(550, 700),
        Offset(60, 740),
      ];
      for (final config in [
        EdgeDetectionConfig.fourPoint,
        EdgeDetectionConfig.fast,
        EdgeDetectionConfig.accurate,
      ]) {
        for (var corner = 0; corner < 4; corner++) {
          final scene = _foldedScene(corner: corner, fold: .12);
          final live = await _live(scene, config);
          expect(live, isNotNull);
          final still = await detectEdgesFromImageBytes(
            Uint8List.fromList(image.encodePng(scene)),
            config: config,
          );
          expect(still, isNotNull);
          final original = _corners(live!), repaired = _corners(still!);
          for (var i = 0; i < 4; i++) {
            if (i != corner) {
              expect(
                repaired[i],
                original[i],
                reason:
                    'corner=$corner stable=$i preset=${config.resizeThreshold}',
              );
            }
            expect((repaired[i] - expected[i]).distance, lessThan(20));
          }
          if ((original[corner] - expected[corner]).distance >= 20) {
            expect(repaired[corner], isNot(original[corner]));
          }
        }
      }
    },
  );

  test(
    'a folded narrow receipt repairs its corner without moving its anchors',
    () async {
      final scene = _foldedScene(corner: 2, shadow: true, receipt: true);
      final live = await _live(scene, EdgeDetectionConfig.fast);
      final still = await detectEdgesFromImageBytes(
        Uint8List.fromList(image.encodePng(scene)),
        config: EdgeDetectionConfig.fast,
      );
      expect(live, isNotNull);
      expect(still, isNotNull);
      for (final i in [0, 1, 3]) {
        expect(_corners(still!)[i], _corners(live!)[i]);
      }
      expect(
        (still!.bottomRight - const Offset(370, 740)).distance,
        lessThan(20),
      );
    },
  );

  test(
    'a shaded folded still can be recovered after live detection finds nothing',
    () async {
      final scene = _foldedScene(shadow: true);
      expect(await _live(scene, EdgeDetectionConfig.accurate), isNull);
      final still = await detectEdgesFromImageBytes(
        Uint8List.fromList(image.encodePng(scene)),
      );
      expect(still, isNotNull);
      final expected = [
        const Offset(95, 70),
        const Offset(510, 100),
        const Offset(550, 700),
        const Offset(60, 740),
      ];
      for (var i = 0; i < 4; i++) {
        expect((_corners(still!)[i] - expected[i]).distance, lessThan(20));
      }
    },
  );

  test('ambiguous large folds preserve the ordinary result', () async {
    final scene = _foldedScene(corner: 1, fold: .5);
    for (final config in [
      EdgeDetectionConfig.fast,
      EdgeDetectionConfig.accurate,
    ]) {
      final live = await _live(scene, config);
      final still = await detectEdgesFromImageBytes(
        Uint8List.fromList(image.encodePng(scene)),
        config: config,
      );
      expect(
        still == null ? null : _corners(still),
        live == null ? null : _corners(live),
      );
    }
  });
  test(
    'ordinary page wins over a large clipped-corner background in preview and stills',
    () async {
      const page = Rect.fromLTRB(170, 220, 440, 670);
      for (final cut in [60, 100, 140, 180, 220]) {
        final scene = _nestedScene(cut: cut);
        for (final config in [
          EdgeDetectionConfig.fast,
          EdgeDetectionConfig.accurate,
        ]) {
          final reason = 'cut=$cut resolution=${config.resizeThreshold}';
          _expectPage(await _live(scene, config), page, 'live $reason');
          _expectPage(
            await detectEdgesFromImageBytes(
              Uint8List.fromList(image.encodePng(scene)),
              config: config,
            ),
            page,
            'still $reason',
          );
        }
      }
    },
  );

  test('off-center pages retain priority across background sizes', () async {
    for (final (background, page, cut) in [
      (
        const Rect.fromLTRB(8, 8, 592, 792),
        const Rect.fromLTRB(60, 160, 280, 650),
        180,
      ),
      (
        const Rect.fromLTRB(20, 30, 580, 770),
        const Rect.fromLTRB(310, 250, 520, 680),
        180,
      ),
      (
        const Rect.fromLTRB(55, 60, 545, 740),
        const Rect.fromLTRB(185, 240, 410, 600),
        200,
      ),
    ]) {
      final scene = _nestedScene(background: background, page: page, cut: cut);
      for (final config in [
        EdgeDetectionConfig.fourPoint,
        EdgeDetectionConfig.fast,
        EdgeDetectionConfig.accurate,
      ]) {
        final reason =
            'background=$background page=$page resolution=${config.resizeThreshold}';
        _expectPage(await _live(scene, config), page, 'live $reason');
        _expectPage(
          await detectEdgesFromImageBytes(
            Uint8List.fromList(image.encodePng(scene)),
            config: config,
          ),
          page,
          'still $reason',
        );
      }
    }
  });

  test('a genuine page filling most of the frame is retained', () async {
    final scene = image.Image(width: 600, height: 800);
    image.fill(scene, color: image.ColorRgb8(30, 30, 30));
    const page = Rect.fromLTRB(20, 25, 580, 775);
    image.fillRect(
      scene,
      x1: 20,
      y1: 25,
      x2: 580,
      y2: 775,
      color: image.ColorRgb8(240, 240, 240),
    );
    for (final config in [
      EdgeDetectionConfig.fast,
      EdgeDetectionConfig.accurate,
    ]) {
      _expectPage(await _live(scene, config), page, 'large live page');
      _expectPage(
        await detectEdgesFromImageBytes(
          Uint8List.fromList(image.encodePng(scene)),
          config: config,
        ),
        page,
        'large still page',
      );
    }
  });

  testWidgets('default and diagnostic stages select the same ordinary page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final scene = _nestedScene();
      final rgba = cv.Mat.fromList(
        800,
        600,
        cv.MatType.CV_8UC4,
        scene.getBytes(order: image.ChannelOrder.rgba),
      );
      try {
        for (final config in [
          EdgeDetectionConfig.fast,
          EdgeDetectionConfig.accurate,
        ]) {
          List<Offset>? expected;
          for (final stage in DebugStage.values) {
            final (frame, debug) = await detectDocumentEdges(
              rgba,
              config: config,
              debugStage: stage,
            );
            try {
              _expectPage(
                frame,
                const Rect.fromLTRB(170, 220, 440, 670),
                'stage=$stage',
              );
              final corners = _corners(frame!);
              expected ??= corners;
              expect(corners, expected, reason: 'stage=$stage');
            } finally {
              debug?.dispose();
            }
          }
        }
      } finally {
        rgba.dispose();
      }
    });
  });

  test(
    'live worker retains the ordinary page on the competing background',
    () async {
      final scene = _nestedScene();
      final runner = EdgeDetectionRunner();
      try {
        await runner.start();
        final result = await runner.detect(
          rgbaBytes: scene.getBytes(order: image.ChannelOrder.rgba),
          width: 600,
          height: 800,
          rotationCompensation: 0,
        );
        expect(result, isA<FrameDetected>());
        _expectPage(
          (result as FrameDetected).frame,
          const Rect.fromLTRB(170, 220, 440, 670),
          'worker',
        );
      } finally {
        runner.dispose();
      }
    },
  );
}
