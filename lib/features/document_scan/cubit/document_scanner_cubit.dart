import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/core/bloc/loading_status.dart';
import 'package:paperless_mobile/core/bloc/transient_error.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';
import 'package:paperless_mobile/core/model/info_message_exception.dart';
import 'package:paperless_mobile/core/service/file_service.dart';
import 'package:paperless_mobile/core/store/local_store.dart';
import 'package:paperless_mobile/core/store/slices/local_user_data.dart';
import 'package:paperless_mobile/features/document_scan/service/legacy_scan_recovery.dart';
import 'package:paperless_mobile/features/notifications/services/local_notification_service.dart';
import 'package:path/path.dart';
import 'package:rxdart/rxdart.dart';

part 'document_scanner_cubit.freezed.dart';
part 'document_scanner_state.dart';

const allowedExtensions = ['.jpeg', '.jpg', '.png'];

class DocumentScannerCubit extends Cubit<DocumentScannerState> {
  final LocalNotificationService _notificationService;
  final LocalStore? _localStore;
  LegacyScanRecovery? _legacyRecovery;

  DocumentScannerCubit(this._notificationService, {LocalStore? localStore})
    : _localStore = localStore,
      super(const DocumentScannerState());

  Future<void> initialize() async {
    logger.fd(
      "Restoring scans...",
      className: runtimeType.toString(),
      methodName: "initialize",
    );
    emit(const DocumentScannerState(status: LoadingStatus.loading));
    final tempDir = FileService.instance.temporaryScansDirectory;
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    await _recoverLegacyScans();
    if (isClosed) return;
    final allFiles = await _allScanFiles();
    final scans = allFiles
        .where(
          (event) =>
              allowedExtensions.contains(extension(event.path).toLowerCase()),
        )
        .toList();
    final validScans = await _validateFiles(scans);
    logger.fd(
      "Restored ${validScans.length} scans.",
      className: runtimeType.toString(),
      methodName: "initialize",
    );
    emit(
      validScans.isEmpty
          ? const DocumentScannerState()
          : DocumentScannerState(
              scans: validScans,
              status: LoadingStatus.loaded,
            ),
    );
  }

  Future<void> addScansFromScanner(List<File> files) async {
    final targetDirectory = FileService.instance.temporaryScansDirectory;
    // We copy the files to the scans dir and remove the original copies.
    await Future.wait([
      for (final file in files)
        file.rename('${targetDirectory.path}/${file.uri.pathSegments.last}'),
    ]);
    // Then, we synchronize state with the actual files in the scans directory.
    final syncedScans = await _validateFiles(await _allScanFiles());
    emit(
      DocumentScannerState(status: LoadingStatus.loaded, scans: syncedScans),
    );
  }

  Future<List<File>> _allScanFiles() async => [
    ...await FileService.instance.temporaryScansDirectory
        .list()
        .whereType<File>()
        .toList(),
    ...?await _legacyRecovery?.listRecoveredFiles(),
  ];

  Future<void> _recoverLegacyScans() async {
    final store = _localStore;
    final userId = store?.state.loggedInAppUserId;
    if (store == null || userId == null) return;
    final data = store.state.localUserData[userId];
    if (data == null) return;
    final applicationDirectory = FileService.instance.uploadDirectory.parent;
    final recovery = _legacyRecovery = LegacyScanRecovery(
      sourceRoot: Directory(join(applicationDirectory.path, 'document_scans')),
      destinationRoot: Directory(
        join(applicationDirectory.path, 'recovered_scans'),
      ),
      userId: userId,
    );
    try {
      final result = await recovery.recover(
        documents: data.legacyDocumentScans,
        importedIds: data.recoveredLegacyPageIds,
      );
      if (isClosed) return;
      if (result.importedIds.length != data.recoveredLegacyPageIds.length &&
          store.state.localUserData.containsKey(userId)) {
        store.updateUserData(
          userId,
          (current) => current.copyWith(
            recoveredLegacyPageIds: result.importedIds.toList(),
          ),
        );
      }
      if (result.failures > 0) {
        logger.fw(
          'Could not recover ${result.failures} saved scan entries. Original files and metadata were retained.',
        );
      }
    } catch (error) {
      logger.fw(
        'Saved scan recovery failed; original files and metadata were retained: $error',
      );
    }
  }

  void addScan(File file) async {
    emit(
      DocumentScannerState(
        status: LoadingStatus.loaded,
        scans: [...state.scans, file],
      ),
    );
  }

  Future<void> removeScan(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
      final scans = state.scans.where((f) => f != file).toList();
      emit(
        scans.isEmpty
            ? const DocumentScannerState()
            : DocumentScannerState(status: LoadingStatus.loaded, scans: scans),
      );
    } catch (error, stackTrace) {
      throw InfoMessageException(
        code: ErrorCode.scanRemoveFailed,
        message: error.toString(),
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> reset() async {
    try {
      Future.wait([for (final file in state.scans) file.delete()]);
      imageCache.clear();
    } catch (_) {
      addError(TransientPaperlessApiError(code: ErrorCode.scanRemoveFailed));
    } finally {
      emit(const DocumentScannerState());
    }
  }

  Future<void> saveToFile(
    Uint8List bytes,
    String fileName,
    String locale,
  ) async {
    try {
      var file = await FileService.instance.saveToFile(bytes, fileName);
      _notificationService.notifyFileSaved(
        filename: fileName,
        filePath: file.path,
        finished: true,
        locale: locale,
      );
    } on Exception catch (e) {
      addError(TransientMessageError(message: e.toString()));
    }
  }

  Future<List<File>> _validateFiles(List<File> scans) async {
    final validFiles = <File>[];
    for (final file in scans) {
      final length = await file.length();
      if (length == 0) {
        await file.delete();
        logger.fw(
          'Previous scan ${file.path} was empty and has been deleted.',
          className: runtimeType.toString(),
          methodName: "initialize",
        );
        continue;
      }
      validFiles.add(file);
    }
    return validFiles;
  }
}
