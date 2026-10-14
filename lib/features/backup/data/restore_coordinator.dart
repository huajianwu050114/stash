import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_storage_paths.dart';
import '../../../platform/backup/backup_platform.dart';
import '../domain/backup_exception.dart';
import '../domain/backup_manifest.dart';
import 'backup_service.dart';
import 'backup_validator.dart';
import 'pending_restore_store.dart';

class PreparedRestore {
  const PreparedRestore({
    required this.summary,
    required this.safetyBackupPath,
  });

  final BackupSummary summary;
  final String safetyBackupPath;
}

class RestoreCoordinator {
  RestoreCoordinator({
    required this.storage,
    required this.backupService,
    required this.validator,
    required this.pendingStore,
    required this.backupDirectoryResolver,
    DateTime Function()? clock,
    Uuid? uuid,
  }) : _clock = clock ?? DateTime.now,
       _uuid = uuid ?? const Uuid();

  final AppStoragePaths storage;
  final BackupService backupService;
  final BackupValidator validator;
  final PendingRestoreStore pendingStore;
  final BackupDirectoryResolver backupDirectoryResolver;
  final DateTime Function() _clock;
  final Uuid _uuid;

  Future<BackupSummary> inspectBackup(File archiveFile) async {
    final inspection = Directory(
      path.join(storage.restoreStagingDirectory.path, 'inspect-${_uuid.v4()}'),
    );
    try {
      final validated = await validator.validateArchive(
        archiveFile: archiveFile,
        extractionDirectory: inspection,
      );
      return BackupSummary(
        manifest: validated.manifest,
        archivePath: archiveFile.path,
        archiveSize: await archiveFile.length(),
      );
    } finally {
      await _deleteBestEffort(inspection);
    }
  }

  Future<PreparedRestore> prepareRestore(File archiveFile) async {
    if (await pendingStore.read() != null) {
      throw const BackupException(
        BackupFailure.restorePreparationFailed,
        'A restore is already waiting for restart.',
      );
    }

    // Revalidate the selected source before making the automatic recovery
    // point. This closes the selection/confirmation trust boundary.
    final summary = await inspectBackup(archiveFile);
    final now = _clock().toLocal();
    final backupFolder = await backupDirectoryResolver.defaultBackupDirectory();
    await backupFolder.create(recursive: true);
    final safetyFile = File(
      path.join(
        backupFolder.path,
        'Pre-Restore-${_timestamp(now)}.stashbackup',
      ),
    );
    try {
      await backupService.createBackup(destinationFile: safetyFile);
    } catch (error) {
      throw BackupException(
        BackupFailure.safetyBackupFailed,
        'Automatic pre-restore backup failed.',
        error,
      );
    }

    final container = Directory(
      path.join(storage.restoreStagingDirectory.path, _uuid.v4()),
    );
    final extracted = Directory(path.join(container.path, 'extracted'));
    final stagedProfile = Directory(path.join(container.path, 'profile'));
    final stagedManifest = File(path.join(container.path, 'manifest.json'));
    try {
      final validated = await validator.validateArchive(
        archiveFile: archiveFile,
        extractionDirectory: extracted,
      );
      await stagedProfile.create(recursive: true);
      await Directory(path.join(extracted.path, 'database'))
          .rename(path.join(stagedProfile.path, 'database'));
      final extractedAttachments = Directory(
        path.join(extracted.path, 'attachments'),
      );
      if (await extractedAttachments.exists()) {
        await extractedAttachments.rename(
          path.join(stagedProfile.path, 'attachments'),
        );
      } else {
        await Directory(path.join(stagedProfile.path, 'attachments'))
            .create(recursive: true);
      }
      await File(path.join(extracted.path, 'manifest.json'))
          .rename(stagedManifest.path);
      await _deleteBestEffort(extracted);
      await validator.validateDirectory(
        dataRoot: stagedProfile,
        manifestFile: stagedManifest,
      );
      final pending = PendingRestore(
        profile: storage.profile,
        state: PendingRestoreState.ready,
        stagingDirectory: container.path,
        manifestPath: stagedManifest.path,
        sourceBackupPath: archiveFile.path,
        safetyBackupPath: safetyFile.path,
        createdAtUtc: _clock().toUtc(),
      );
      await pendingStore.write(pending);
      return PreparedRestore(
        summary: BackupSummary(
          manifest: validated.manifest,
          archivePath: archiveFile.path,
          archiveSize: summary.archiveSize,
        ),
        safetyBackupPath: safetyFile.path,
      );
    } on BackupException {
      await _deleteBestEffort(container);
      rethrow;
    } catch (error) {
      await _deleteBestEffort(container);
      throw BackupException(
        BackupFailure.restorePreparationFailed,
        'Restore staging failed.',
        error,
      );
    }
  }
}

String _timestamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}-'
    '${value.hour.toString().padLeft(2, '0')}'
    '${value.minute.toString().padLeft(2, '0')}'
    '${value.second.toString().padLeft(2, '0')}';

Future<void> _deleteBestEffort(Directory directory) async {
  if (!await directory.exists()) return;
  try {
    await directory.delete(recursive: true);
  } catch (_) {}
}
