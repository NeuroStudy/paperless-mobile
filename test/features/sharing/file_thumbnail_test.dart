import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/sharing/view/widgets/file_thumbnail.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrintingPlatform originalPrinting;
  late _FakePrintingPlatform printing;
  late Directory tempDirectory;
  late Map<String, Uint8List> images;
  late Uint8List pdfBytes;

  setUpAll(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'file_thumbnail_test_',
    );
    final image = img.Image(width: 2, height: 2);
    images = {
      'png': Uint8List.fromList(img.encodePng(image)),
      'jpg': Uint8List.fromList(img.encodeJpg(image)),
    };
    final document = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.SizedBox()));
    pdfBytes = await document.save();
    for (final entry in images.entries) {
      await File(
        '${tempDirectory.path}/scan.${entry.key}',
      ).writeAsBytes(entry.value);
    }
    await File('${tempDirectory.path}/notes.txt').writeAsString('Scan notes');
    await File('${tempDirectory.path}/unknown.bin').writeAsBytes([1, 2, 3]);
  });

  tearDownAll(() async {
    await tempDirectory.delete(recursive: true);
  });

  setUp(() {
    originalPrinting = PrintingPlatform.instance;
    printing = _FakePrintingPlatform(images['png']!);
    PrintingPlatform.instance = printing;
  });

  tearDown(() {
    PrintingPlatform.instance = originalPrinting;
  });

  for (final extension in ['png', 'jpg']) {
    for (final fromFile in [false, true]) {
      testWidgets(
        '$extension ${fromFile ? 'file' : 'bytes'} display without invoking Printing',
        (tester) async {
          if (fromFile) {
            await tester.pumpWidget(const MaterialApp(home: SizedBox()));
            await tester.runAsync(
              () => precacheImage(
                FileImage(File('${tempDirectory.path}/scan.$extension')),
                tester.element(find.byType(SizedBox)),
              ),
            );
          }
          await _pumpThumbnail(
            tester,
            fromFile
                ? FileThumbnail(
                    file: File('${tempDirectory.path}/scan.$extension'),
                  )
                : FileThumbnail(bytes: images[extension]!),
          );

          expect(find.byType(Image), findsOneWidget);
          final image = tester.widget<Image>(find.byType(Image));
          await tester.runAsync(
            () =>
                precacheImage(image.image, tester.element(find.byType(Image))),
          );
          await tester.pumpAndSettle();
          expect(find.byType(RawImage), findsOneWidget);
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
          expect(printing.infoCalls, 0);
          expect(printing.rasterCalls, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final filename in ['notes.txt', 'unknown.bin']) {
    testWidgets('$filename file does not invoke Printing', (tester) async {
      await _pumpThumbnail(
        tester,
        FileThumbnail(file: File('${tempDirectory.path}/$filename')),
      );

      expect(printing.infoCalls, 0);
      expect(printing.rasterCalls, 0);
      expect(find.byType(Image), findsNothing);
      expect(
        filename.endsWith('.txt')
            ? find.text('.txt')
            : find.byIcon(Icons.file_present_outlined),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unknown bytes do not invoke Printing', (tester) async {
    await _pumpThumbnail(
      tester,
      FileThumbnail(bytes: Uint8List.fromList([1, 2, 3])),
    );

    expect(printing.infoCalls, 0);
    expect(printing.rasterCalls, 0);
    expect(find.byIcon(Icons.file_present_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final fromFile in [false, true]) {
    testWidgets(
      'PDF ${fromFile ? 'file' : 'bytes'} render page zero at 72 DPI',
      (tester) async {
        await _pumpThumbnail(
          tester,
          fromFile
              ? FileThumbnail(file: _PdfFile(pdfBytes))
              : FileThumbnail(bytes: pdfBytes),
        );
        await tester.pumpAndSettle();

        expect(printing.infoCalls, 1);
        expect(printing.rasterCalls, 1);
        expect(printing.document, orderedEquals(pdfBytes));
        expect(printing.pages, [0]);
        expect(printing.dpi, 72);
        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('PDF thumbnail stays empty while loading', (tester) async {
    final info = Completer<PrintingInfo>();
    printing.loadInfo = () => info.future;
    await _pumpThumbnail(tester, FileThumbnail(bytes: pdfBytes));

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.file_present_outlined), findsNothing);
    info.complete(const PrintingInfo(canRaster: true));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final failure in [
    'unsupported',
    'info error',
    'raster error',
    'empty',
  ]) {
    testWidgets('PDF $failure shows fallback without an exception', (
      tester,
    ) async {
      switch (failure) {
        case 'unsupported':
          printing.loadInfo = () async => const PrintingInfo(canRaster: false);
        case 'info error':
          printing.loadInfo = () async => throw PlatformException(code: 'info');
        case 'raster error':
          // Native raster errors can be strings rather than Exceptions.
          printing.rasters = () =>
              Stream<PdfRaster>.error('Unable to load the document!');
        case 'empty':
          printing.rasters = () => const Stream<PdfRaster>.empty();
      }
      await _pumpThumbnail(tester, FileThumbnail(bytes: pdfBytes));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.file_present_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(
        printing.rasterCalls,
        failure == 'unsupported' || failure == 'info error' ? 0 : 1,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pumpThumbnail(
  WidgetTester tester,
  FileThumbnail thumbnail,
) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: thumbnail)));
}

class _FakePrintingPlatform extends PrintingPlatform {
  _FakePrintingPlatform(Uint8List pngBytes) {
    rasters = () => Stream.value(_PngRaster(pngBytes));
  }

  Future<PrintingInfo> Function() loadInfo = () async =>
      const PrintingInfo(canRaster: true);
  late Stream<PdfRaster> Function() rasters;
  int infoCalls = 0;
  int rasterCalls = 0;
  Uint8List? document;
  List<int>? pages;
  double? dpi;

  @override
  Future<PrintingInfo> info() {
    infoCalls++;
    return loadInfo();
  }

  @override
  Stream<PdfRaster> raster(Uint8List document, List<int>? pages, double dpi) {
    rasterCalls++;
    this.document = document;
    this.pages = pages;
    this.dpi = dpi;
    return rasters();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PngRaster extends PdfRaster {
  _PngRaster(this.pngBytes) : super(1, 1, Uint8List(4));

  final Uint8List pngBytes;

  @override
  Future<Uint8List> toPng() async => pngBytes;
}

// Keep the PDF file-input test independent of real filesystem scheduling.
class _PdfFile extends Fake implements File {
  _PdfFile(this.bytes);

  final Uint8List bytes;

  @override
  String get path => 'scan.pdf';

  @override
  Future<Uint8List> readAsBytes() async => bytes;
}
