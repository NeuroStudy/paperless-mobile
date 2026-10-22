import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 10),
  writeResponseOnFailure: true,
  responseDataCallback: (report) async {
    if (report == null) throw StateError('Missing capture diagnostic report');
    final device = Platform.environment['SCANNER_DIAGNOSTIC_DEVICE_ID'];
    if (device == null) throw StateError('Set SCANNER_DIAGNOSTIC_DEVICE_ID');
    final sdk =
        Platform.environment['ANDROID_HOME'] ??
        '${Platform.environment['LOCALAPPDATA']}/Android/Sdk';
    final adb = '$sdk/platform-tools/${Platform.isWindows ? 'adb.exe' : 'adb'}';
    Future<String> property(String name) async {
      final result = await Process.run(adb, [
        '-s',
        device,
        'shell',
        'getprop',
        name,
      ]);
      if (result.exitCode != 0) throw StateError('${result.stderr}');
      return '${result.stdout}'.trim();
    }

    report['device'] = {
      'model': await property('ro.product.model'),
      'android': await property('ro.build.version.release'),
      'emulator': await property('ro.kernel.qemu') == '1',
    };
    final output = Directory(
      'build/scanner_capture_diagnostics/${DateTime.now().millisecondsSinceEpoch}',
    );
    await output.create(recursive: true);
    await File(
      '${output.path}/report.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    for (final entry in report['cases'] as List<dynamic>) {
      for (final filename in entry['files'] as List<dynamic>) {
        final process = await Process.start(adb, [
          '-s',
          device,
          'exec-out',
          'run-as',
          'de.astubenbord.paperless_mobile.debug',
          'cat',
          '${report['directory']}/$filename',
        ]);
        final errors = process.stderr.transform(utf8.decoder).join();
        final sink = File('${output.path}/$filename').openWrite();
        await process.stdout.pipe(sink);
        if (await process.exitCode != 0) throw StateError(await errors);
        await errors;
      }
    }
    stdout.writeln('Capture comparison saved to ${output.absolute.path}');
  },
);
