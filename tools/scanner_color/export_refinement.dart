// Offline lossless export for comparison with dart_reference.py.
// Run from the repository root with the configured Flutter SDK's `dart run`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:paperless_mobile/features/scanner/processing/color_enhancement.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 3 && arguments.first == '--manifest') {
    final manifest = File(arguments[1]);
    final cases = jsonDecode(await manifest.readAsString()) as List<dynamic>;
    for (final item in cases.cast<Map<String, dynamic>>()) {
      final name = item['name'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
        throw FormatException('Invalid fixture name: $name');
      }
      await _export(
        File('${manifest.parent.path}/${item['input']}'),
        Directory('${arguments[2]}/$name'),
      );
    }
    return;
  }
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tools/scanner_color/export_refinement.dart INPUT OUTPUT_DIR\n'
      '   or: dart run tools/scanner_color/export_refinement.dart '
      '--manifest MANIFEST OUTPUT_ROOT',
    );
    exitCode = 64;
    return;
  }
  await _export(File(arguments[0]), Directory(arguments[1]));
}

Future<void> _export(File input, Directory output) async {
  output.createSync(recursive: true);
  final source = await input.readAsBytes();
  final watch = Stopwatch()..start();
  final profile = await analyzeEnhancement(source);
  final analysisMicros = watch.elapsedMicroseconds;
  final rendered = await enhanceDocument(source, profile: profile);
  final renderMicros = watch.elapsedMicroseconds - analysisMicros;
  await File('${output.path}/native-output.png').writeAsBytes(rendered);
  Future<void> writeMap(String name, Uint8List? map) async {
    final file = File('${output.path}/native-$name.bin');
    if (map != null) {
      await file.writeAsBytes(map);
    } else if (await file.exists()) {
      await file.delete();
    }
  }

  await writeMap('paper', profile.paper);
  await writeMap('protection', profile.protection);
  await writeMap('cleanup', profile.cleanup);
  final withoutCleanup = EnhancementProfile(
    profile.width,
    profile.height,
    profile.paper,
    profile.protection,
    profile.contrast,
  );
  await File(
    '${output.path}/native-without-cleanup.png',
  ).writeAsBytes(await enhanceDocument(source, profile: withoutCleanup));
  final metadata = {
    'input': input.absolute.path,
    'width': profile.width,
    'height': profile.height,
    'contrast': profile.contrast,
    'paper_bytes': profile.paper?.length,
    'protection_bytes': profile.protection?.length,
    'cleanup_bytes': profile.cleanup?.length,
    'analysis_ms': analysisMicros / 1000,
    'render_ms': renderMicros / 1000,
  };
  final json = const JsonEncoder.withIndent('  ').convert(metadata);
  await File('${output.path}/profile.json').writeAsString('$json\n');
  stdout.writeln(json);
}
