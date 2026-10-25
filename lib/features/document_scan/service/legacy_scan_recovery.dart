import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class LegacyScanRecoveryResult {
  final List<File> files;
  final Set<String> importedIds;
  final int failures;

  const LegacyScanRecoveryResult(this.files, this.importedIds, this.failures);
}

/// Copies completed v5 pages into an account-owned Alpha 2 recovery directory.
/// Source originals, edited files and raw metadata are never modified.
class LegacyScanRecovery {
  final Directory sourceRoot;
  final Directory destinationRoot;
  final String userId;

  LegacyScanRecovery({
    required this.sourceRoot,
    required this.destinationRoot,
    required this.userId,
  });

  Directory get directory => Directory(
    p.join(
      destinationRoot.path,
      sha256.convert(utf8.encode(userId)).toString(),
    ),
  );

  Future<LegacyScanRecoveryResult> recover({
    required List<dynamic> documents,
    required Iterable<String> importedIds,
  }) async {
    final completed = importedIds.toSet();
    var failures = 0;
    for (final document in documents) {
      if (document is! Map || !_safeName(document['id'])) {
        failures++;
        continue;
      }
      final pages =
          document['pages'] ??
          (document['page_file_names'] is List
              ? [
                  for (final name in document['page_file_names'])
                    {'editedFileName': name},
                ]
              : null);
      if (pages is! List) {
        failures++;
        continue;
      }
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        final name = page is Map ? page['editedFileName'] : null;
        if (!_safeName(name) || !_imageExtension(name as String)) {
          failures++;
          continue;
        }
        final id = sha256
            .convert(utf8.encode('$userId\n${document['id']}\n$index\n$name'))
            .toString();
        // A deleted recovered page is intentional; do not reimport it.
        if (completed.contains(id)) continue;
        try {
          final folder = Directory(p.join(sourceRoot.path, document['id']));
          var source = File(p.join(folder.path, 'edited', name));
          if (!await source.exists()) {
            // Early v5 drafts kept finished pages directly in their folder.
            source = File(p.join(folder.path, name));
          }
          final actualRoot = await sourceRoot.resolveSymbolicLinks();
          final actualSource = await source.resolveSymbolicLinks();
          if (!p.isWithin(actualRoot, actualSource)) {
            throw const FileSystemException('Scan source escapes app storage');
          }
          final bytes = await source.readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          try {
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
          await directory.create(recursive: true);
          final actualDestinationRoot = await destinationRoot
              .resolveSymbolicLinks();
          final actualDirectory = await directory.resolveSymbolicLinks();
          if (!p.isWithin(actualDestinationRoot, actualDirectory)) {
            throw const FileSystemException(
              'Recovery destination escapes app storage',
            );
          }
          final destination = File(
            p.join(directory.path, '$id${p.extension(name).toLowerCase()}'),
          );
          if (await destination.exists()) {
            final existing = await destination.readAsBytes();
            if (sha256.convert(existing) == sha256.convert(bytes)) {
              completed.add(id);
              continue;
            }
          }
          // The deterministic name makes retry after a partial copy safe.
          final pending = File('${destination.path}.part');
          await pending.writeAsBytes(bytes, flush: true);
          await pending.rename(destination.path);
          completed.add(id);
        } catch (_) {
          failures++;
        }
      }
    }
    final files = await listRecoveredFiles();
    return LegacyScanRecoveryResult(
      List.unmodifiable(files),
      Set.unmodifiable(completed),
      failures,
    );
  }

  Future<List<File>> listRecoveredFiles() async {
    if (!await directory.exists()) return [];
    return directory
        .list(followLinks: false)
        .where((entry) {
          return entry is File &&
              RegExp(
                r'^[a-f0-9]{64}\.(png|jpe?g)$',
              ).hasMatch(p.basename(entry.path));
        })
        .cast<File>()
        .toList();
  }

  static bool _safeName(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains(':') &&
      !p.isAbsolute(value);

  static bool _imageExtension(String name) =>
      ['.png', '.jpg', '.jpeg'].contains(p.extension(name).toLowerCase());
}
