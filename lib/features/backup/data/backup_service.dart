import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../../app/app_profile.dart';
import '../../../core/storage/app_storage_paths.dart';
import '../domain/backup_exception.dart';
import '../domain/backup_manifest.dart';
import 'backup_archive.dart';
import 'backup_validator.dart';

enum BackupStage {
  preparingDatabase('Preparing database…'),
  copyingAttachments('Copying attachments…'),
  writingArchive('Writing backup…'),
  verifying('Verifying backup…'),
  complete('Backup complete');

  const BackupStage(this.label);
  final String label;
}

abstract interface class DatabaseSnapshotter {
  Future<void> createSnapshot({required File source, required File target});
}

class SqliteOnlineSnapshotter implements DatabaseSnapshotter {
  const SqliteOnlineSnapshotter();

  @override
  Future<void> createSnapshot({
    required File source,
    required File target,
  }) async {
    if (!await source.exists()) {
      throw FileSystemException('Stash database does not exist.', source.path);
    }
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    final sourceDatabase = sqlite3.open(source.path, mode: OpenMode.readOnly);
    final targetDatabase = sqlite3.open(target.path);
    try {
      await sourceDatabase.backup(targetDatabase, nPage: 64).drain<void>();
    } finally {
      targetDatabase.close();
      sourceDatabase.close();
    }
  }
}

typedef BackupProgress = void Function(BackupStage stage);
typedef StreamFileCopier = Future<void> Function(File source, File target);

class BackupService {
  BackupService({
    required this.profile,
    required this.storage,
    required this.appVersion,
    required this.currentSchemaVersion,
    this.archiveCodec = const ZipBackupArchiveCodec(),
    this.snapshotter = const SqliteOnlineSnapshotter(),
    this.fileCopier = copyFileStreamed,
    DateTime Function()? clock,
    Uuid? uuid,
  }) : _clock = clock ?? DateTime.now,
       _uuid = uuid ?? const Uuid(),
       _validator = BackupValidator(
         archiveCodec: archiveCodec,
         currentSchemaVersion: currentSchemaVersion,
       );

  final AppProfile profile;
  final AppStoragePaths storage;
  final String appVersion;
  final int currentSchemaVersion;
  final BackupArchiveCodec archiveCodec;
  final DatabaseSnapshotter snapshotter;
  final StreamFileCopier fileCopier;
  final DateTime Function() _clock;
  final Uuid _uuid;
  final BackupValidator _validator;

  Future<BackupSummary> createBackup({
    required File destinationFile,
    BackupProgress? onProgress,
  }) async {
    final operationId = _uuid.v4();
    final staging = Directory(
      path.join(storage.backupStagingDirectory.path, operationId),
    );
    final verification = Directory(
      path.join(storage.backupStagingDirectory.path, '$operationId-verify'),
    );
    final finalFile = _withBackupExtension(destinationFile);
    final partialFile = File(
      path.join(
        finalFile.parent.path,
        '.${path.basename(finalFile.path)}.partial-$operationId',
      ),
    );
    File? replacedFile;
    try {
      onProgress?.call(BackupStage.preparingDatabase);
      await staging.create(recursive: true);
      final snapshot = File(
        path.join(staging.path, 'database', 'stash.sqlite'),
      );
      await snapshotter.createSnapshot(
        source: storage.databaseFile,
        target: snapshot,
      );

      final catalog = BackupDatabaseCatalog.open(snapshot);
      late final int schemaVersion;
      late final int itemCount;
      late final int channelCount;
      late final List<SnapshotAttachment> attachments;
      try {
        if (!catalog.isIntegrityValid) {
          throw const BackupException(
            BackupFailure.createFailed,
            'The database snapshot failed integrity validation.',
          );
        }
        schemaVersion = catalog.schemaVersion;
        if (schemaVersion <= 0 || schemaVersion > currentSchemaVersion) {
          throw BackupException(
            BackupFailure.createFailed,
            'Unexpected database schema version: $schemaVersion',
          );
        }
        itemCount = catalog.countRows('items');
        channelCount = catalog.countRows('channels');
        attachments = catalog.attachments();
      } finally {
        catalog.close();
      }

      onProgress?.call(BackupStage.copyingAttachments);
      final fileEntries = <BackupFileEntry>[];
      for (final attachment in attachments) {
        final archivePath = normalizeArchivePath(attachment.relativePath);
        final source = _resolveSourceAttachment(archivePath);
        if (!await source.exists()) {
          throw BackupException(
            BackupFailure.missingAttachment,
            'A referenced attachment is missing: ${attachment.id}',
          );
        }
        final target = _resolveStagingFile(staging, archivePath);
        await target.parent.create(recursive: true);
        await fileCopier(source, target);
        final size = await target.length();
        if (attachment.byteSize != null && attachment.byteSize != size) {
          throw BackupException(
            BackupFailure.createFailed,
            'Attachment size changed while backing up: ${attachment.id}',
          );
        }
        fileEntries.add(
          BackupFileEntry(
            path: archivePath,
            size: size,
            sha256: await sha256File(target),
          ),
        );
      }

      final manifest = BackupManifest(
        format: BackupManifest.formatName,
        formatVersion: BackupManifest.currentFormatVersion,
        createdAtUtc: _clock().toUtc(),
        appVersion: appVersion,
        databaseSchemaVersion: schemaVersion,
        sourceProfile: profile.name,
        itemCount: itemCount,
        channelCount: channelCount,
        attachmentCount: attachments.length,
        databaseSha256: await sha256File(snapshot),
        files: fileEntries,
      );
      await File(path.join(staging.path, 'manifest.json'))
          .writeAsString(manifest.encode(), flush: true);
      await _validator.validateDirectory(
        dataRoot: staging,
        manifestFile: File(path.join(staging.path, 'manifest.json')),
      );

      onProgress?.call(BackupStage.writingArchive);
      await finalFile.parent.create(recursive: true);
      await archiveCodec.create(
        sourceDirectory: staging,
        manifest: manifest,
        outputFile: partialFile,
      );

      onProgress?.call(BackupStage.verifying);
      final validated = await _validator.validateArchive(
        archiveFile: partialFile,
        extractionDirectory: verification,
      );
      if (await finalFile.exists()) {
        replacedFile = File('${finalFile.path}.replaced-$operationId');
        await finalFile.rename(replacedFile.path);
      }
      try {
        await partialFile.rename(finalFile.path);
      } catch (_) {
        if (replacedFile != null && await replacedFile.exists()) {
          await replacedFile.rename(finalFile.path);
        }
        rethrow;
      }
      if (replacedFile != null && await replacedFile.exists()) {
        try {
          await replacedFile.delete();
        } catch (_) {}
      }
      onProgress?.call(BackupStage.complete);
      return BackupSummary(
        manifest: validated.manifest,
        archivePath: finalFile.path,
        archiveSize: await finalFile.length(),
      );
    } on BackupException {
      rethrow;
    } catch (error) {
      throw BackupException(
        BackupFailure.createFailed,
        'Backup creation failed.',
        error,
      );
    } finally {
      await _deleteDirectoryBestEffort(staging);
      await _deleteDirectoryBestEffort(verification);
      if (await partialFile.exists()) {
        try {
          await partialFile.delete();
        } catch (_) {}
      }
    }
  }

  File _resolveSourceAttachment(String archivePath) {
    final resolved = path.normalize(
      path.joinAll([storage.root.path, ...archivePath.split('/')]),
    );
    if (!path.isWithin(storage.root.path, resolved)) {
      throw BackupException(
        BackupFailure.invalidPath,
        'Attachment path escapes the active profile.',
      );
    }
    return File(resolved);
  }

  File _resolveStagingFile(Directory staging, String archivePath) {
    final resolved = path.normalize(
      path.joinAll([staging.path, ...archivePath.split('/')]),
    );
    if (!path.isWithin(staging.path, resolved)) {
      throw BackupException(
        BackupFailure.invalidPath,
        'Attachment path escapes backup staging.',
      );
    }
    return File(resolved);
  }

  File _withBackupExtension(File file) =>
      path.extension(file.path).toLowerCase() == '.stashbackup'
      ? file
      : File('${file.path}.stashbackup');
}

Future<void> copyFileStreamed(File source, File target) async {
  IOSink? sink;
  try {
    sink = target.openWrite(mode: FileMode.writeOnly);
    await sink.addStream(source.openRead());
    await sink.flush();
    await sink.close();
    sink = null;
  } finally {
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
  }
}

Future<void> _deleteDirectoryBestEffort(Directory directory) async {
  if (!await directory.exists()) return;
  try {
    await directory.delete(recursive: true);
  } catch (_) {}
}
