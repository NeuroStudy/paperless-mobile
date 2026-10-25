import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:paperless_mobile/core/store/local_store.dart';
import 'package:paperless_mobile/core/store/slices/global_settings.dart';
import 'package:paperless_mobile/core/store/slices/local_user_data.dart';
import 'package:paperless_mobile/features/document_scan/service/legacy_scan_recovery.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late Directory source;
  late Directory target;
  late Uint8List bytes;
  late List<dynamic> documents;
  late LegacyScanRecovery recovery;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('alpha2-recovery-');
    source = await Directory(p.join(temporary.path, 'document_scans')).create();
    target = Directory(p.join(temporary.path, 'recovered_scans'));
    final picture = image.Image(width: 3, height: 2);
    image.fill(picture, color: image.ColorRgb8(20, 80, 140));
    bytes = Uint8List.fromList(image.encodePng(picture));
    documents = [
      {
        'id': 'draft-a',
        'directory_path': 'obsolete/absolute/path',
        'pages': [
          {'editedFileName': 'page.png', 'originalFileName': 'original.jpg'},
        ],
      },
    ];
    await Directory(
      p.join(source.path, 'draft-a', 'edited'),
    ).create(recursive: true);
    await File(
      p.join(source.path, 'draft-a', 'edited', 'page.png'),
    ).writeAsBytes(bytes);
    recovery = LegacyScanRecovery(
      sourceRoot: source,
      destinationRoot: target,
      userId: 'account-a',
    );
  });
  tearDown(() => temporary.delete(recursive: true));

  for (final version in [2, 3]) {
    test('retains account and scan state from persisted version $version', () {
      final fixture = LocalStoreState(
        version: version,
        loggedInAppUserId: 'account-a',
        readHints: const ['retained-hint'],
        globalSettings: const GlobalSettings(preferredLocaleSubtag: 'de'),
        localUserData: {
          'account-a': LocalUserData(
            userId: 'account-a',
            serverUrl: 'https://example.test',
            username: 'example',
            legacyDocumentScans: documents,
          ),
        },
      ).toJson();
      final restored = LocalStoreState.fromJson(fixture);
      expect(restored.version, version);
      expect(restored.loggedInAppUserId, 'account-a');
      expect(restored.readHints, ['retained-hint']);
      expect(restored.globalSettings.preferredLocaleSubtag, 'de');
      expect(
        restored.localUserData['account-a']!.legacyDocumentScans,
        documents,
      );
      expect(LocalStoreState.fromJson(restored.toJson()).toJson(), fixture);
    });
  }

  test('preserves newer raw metadata during Alpha 2 account round trips', () {
    final account = LocalUserData.fromJson({
      'user_id': 'account-a',
      'server_url': 'https://example.test',
      'username': 'example',
      'document_scans': documents,
    });
    expect(account.legacyDocumentScans, documents);
    expect(account.recoveredLegacyPageIds, isEmpty);
    final updated = account.copyWith(
      username: 'renamed',
      recoveredLegacyPageIds: ['done'],
    );
    expect(updated.toJson()['document_scans'], documents);
    expect(LocalUserData.fromJson(updated.toJson()).recoveredLegacyPageIds, [
      'done',
    ]);
  });

  test(
    'copies edited pixels exactly and leaves source files and metadata intact',
    () async {
      final original = File(p.join(source.path, 'draft-a', 'original.jpg'));
      await original.writeAsString('untouched source');
      final result = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      expect(result.failures, 0);
      expect(result.files, hasLength(1));
      expect(await result.files.single.readAsBytes(), bytes);
      expect(
        await File(
          p.join(source.path, 'draft-a', 'edited', 'page.png'),
        ).readAsBytes(),
        bytes,
      );
      expect(await original.readAsString(), 'untouched source');
      expect(
        (documents.single as Map)['directory_path'],
        'obsolete/absolute/path',
      );
    },
  );

  test(
    'repeated launches do not duplicate or resurrect intentionally deleted pages',
    () async {
      final first = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      final second = await recovery.recover(
        documents: documents,
        importedIds: first.importedIds,
      );
      expect(second.files, hasLength(1));
      expect(second.importedIds, first.importedIds);
      await first.files.single.delete();
      final third = await recovery.recover(
        documents: documents,
        importedIds: second.importedIds,
      );
      expect(third.files, isEmpty);
      expect(third.importedIds, first.importedIds);
    },
  );

  test(
    'retries safely after copying but before the ledger was persisted',
    () async {
      final first = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      final retry = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      expect(retry.files, hasLength(1));
      expect(retry.importedIds, first.importedIds);
      expect(await retry.files.single.readAsBytes(), bytes);
    },
  );

  test(
    'overwrites an interrupted partial copy without exposing it as a page',
    () async {
      final first = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      final destination = first.files.single;
      await destination.delete();
      await File('${destination.path}.part').writeAsString('partial');
      expect(await recovery.listRecoveredFiles(), isEmpty);
      final retry = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      expect(retry.failures, 0);
      expect(await retry.files.single.readAsBytes(), bytes);
      expect(await File('${destination.path}.part').exists(), isFalse);
    },
  );

  test(
    'accounts use separate directories, identities and recovered page lists',
    () async {
      final first = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      final other = LegacyScanRecovery(
        sourceRoot: source,
        destinationRoot: target,
        userId: 'account-b',
      );
      expect(await other.listRecoveredFiles(), isEmpty);
      final second = await other.recover(documents: documents, importedIds: []);
      expect(second.files, hasLength(1));
      expect(second.files.single.path, isNot(first.files.single.path));
      expect(second.importedIds.intersection(first.importedIds), isEmpty);
      expect(await recovery.listRecoveredFiles(), hasLength(1));
    },
  );

  test(
    'missing edited pages are retained for retry and originals are never substituted',
    () async {
      await File(p.join(source.path, 'draft-a', 'edited', 'page.png')).delete();
      final originals = await Directory(
        p.join(source.path, 'draft-a', 'original'),
      ).create();
      await File(p.join(originals.path, 'page.png')).writeAsBytes(bytes);
      final missing = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      expect(missing.failures, 1);
      expect(missing.importedIds, isEmpty);
      expect(missing.files, isEmpty);
      await File(
        p.join(source.path, 'draft-a', 'edited', 'page.png'),
      ).writeAsBytes(bytes);
      final retry = await recovery.recover(
        documents: documents,
        importedIds: missing.importedIds,
      );
      expect(retry.failures, 0);
      expect(retry.files, hasLength(1));
    },
  );

  test(
    'corrupt images fail without marking success or deleting the source',
    () async {
      final file = File(p.join(source.path, 'draft-a', 'edited', 'page.png'));
      await file.writeAsString('corrupted image');
      final result = await recovery.recover(
        documents: documents,
        importedIds: [],
      );
      expect(result.failures, 1);
      expect(result.importedIds, isEmpty);
      expect(await file.readAsString(), 'corrupted image');
    },
  );

  test(
    'legacy root pages are recovered without trusting stored absolute paths',
    () async {
      await File(
        p.join(source.path, 'draft-a', 'edited', 'page.png'),
      ).rename(p.join(source.path, 'draft-a', 'page.png'));
      final result = await recovery.recover(
        documents: [
          {
            'id': 'draft-a',
            'directory_path': '../outside',
            'page_file_names': ['page.png'],
          },
        ],
        importedIds: [],
      );
      expect(result.failures, 0);
      expect(await result.files.single.readAsBytes(), bytes);
    },
  );

  test(
    'invalid entries cannot escape app-owned directories or block valid pages',
    () async {
      final result = await recovery.recover(
        documents: [
          null,
          {'id': '../outside', 'pages': []},
          {
            'id': 'draft-a',
            'pages': [
              {'editedFileName': '../page.png'},
            ],
          },
          {
            'id': 'draft-a',
            'pages': [null],
          },
          ...documents,
        ],
        importedIds: [],
      );
      expect(result.failures, 4);
      expect(result.files, hasLength(1));
      expect(result.importedIds, hasLength(1));
    },
  );
}
