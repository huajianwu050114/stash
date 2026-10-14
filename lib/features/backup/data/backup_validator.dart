import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../domain/backup_exception.dart';
import '../domain/backup_manifest.dart';
import 'backup_archive.dart';

class SnapshotAttachment {
  const SnapshotAttachment({
    required this.id,
    required this.relativePath,
    required this.byteSize,
  });

  final String id;
  final String relativePath;
  final int? byteSize;
}

class BackupDatabaseCatalog {
  BackupDatabaseCatalog._(this.database);

  factory BackupDatabaseCatalog.open(File file) =>
      BackupDatabaseCatalog._(sqlite3.open(file.path, mode: OpenMode.readOnly));

  final Database database;

  int get schemaVersion => database.userVersion;

  bool get isIntegrityValid {
    final rows = database.select('PRAGMA integrity_check');
    return rows.length == 1 && rows.first.values.first == 'ok';
  }

  int countRows(String table) {
    if (!_hasTable(table)) return 0;
    final rows = database.select('SELECT COUNT(*) AS total FROM "$table"');
    return rows.first['total'] as int;
  }

  List<SnapshotAttachment> attachments() {
    if (!_hasTable('attachments')) return const [];
    final rows = database.select(
      'SELECT id, relative_path, byte_size FROM attachments '
      'WHERE deleted_at IS NULL ORDER BY id',
    );
    return rows
        .map(
          (row) => SnapshotAttachment(
            id: row['id'] as String,
            relativePath: row['relative_path'] as String,
            byteSize: row['byte_size'] as int?,
          ),
        )
        .toList(growable: false);
  }

  bool _hasTable(String name) => database.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    [name],
  ).isNotEmpty;

  void close() => database.close();
}

class ValidatedBackup {
  const ValidatedBackup({required this.manifest, required this.dataRoot});

  final BackupManifest manifest;
  final Directory dataRoot;
}

class BackupValidator {
  const BackupValidator({
    required this.archiveCodec,
    required this.currentSchemaVersion,
  });

  final BackupArchiveCodec archiveCodec;
  final int currentSchemaVersion;

  Future<ValidatedBackup> validateArchive({
    required File archiveFile,
    required Directory extractionDirectory,
  }) async {
    if (!await archiveFile.exists()) {
      throw const BackupException(
        BackupFailure.corrupted,
        'The selected backup does not exist.',
      );
    }
    if (await extractionDirectory.exists()) {
      await extractionDirectory.delete(recursive: true);
    }
    await archiveCodec.extract(
      archiveFile: archiveFile,
      destination: extractionDirectory,
    );
    return validateDirectory(
      dataRoot: extractionDirectory,
      manifestFile: File(path.join(extractionDirectory.path, 'manifest.json')),
    );
  }

  Future<ValidatedBackup> validateDirectory({
    required Directory dataRoot,
    required File manifestFile,
  }) async {
    try {
      if (!await manifestFile.exists()) {
        throw const BackupException(
          BackupFailure.corrupted,
          'manifest.json is missing.',
        );
      }
      final manifest = BackupManifest.decode(await manifestFile.readAsString());
      _validateManifestHeader(manifest);

      final databaseFile = File(
        path.join(dataRoot.path, 'database', 'stash.sqlite'),
      );
      if (!await databaseFile.exists()) {
        throw const BackupException(
          BackupFailure.corrupted,
          'database/stash.sqlite is missing.',
        );
      }
      if (await sha256File(databaseFile) != manifest.databaseSha256) {
        throw const BackupException(
          BackupFailure.corrupted,
          'Database checksum mismatch.',
        );
      }

      final catalog = BackupDatabaseCatalog.open(databaseFile);
      try {
        if (!catalog.isIntegrityValid) {
          throw const BackupException(
            BackupFailure.corrupted,
            'SQLite integrity_check failed.',
          );
        }
        final schema = catalog.schemaVersion;
        if (schema != manifest.databaseSchemaVersion || schema <= 0) {
          throw const BackupException(
            BackupFailure.corrupted,
            'Database schema does not match the manifest.',
          );
        }
        if (schema > currentSchemaVersion) {
          throw const BackupException(
            BackupFailure.newerSchema,
            'Backup schema is newer than this app.',
          );
        }
        if (catalog.countRows('items') != manifest.itemCount ||
            catalog.countRows('channels') != manifest.channelCount) {
          throw const BackupException(
            BackupFailure.corrupted,
            'Database counts do not match the manifest.',
          );
        }
        final attachments = catalog.attachments();
        if (attachments.length != manifest.attachmentCount) {
          throw const BackupException(
            BackupFailure.corrupted,
            'Attachment count does not match the manifest.',
          );
        }
        await _validateAttachments(dataRoot, attachments, manifest.files);
      } finally {
        catalog.close();
      }
      await _rejectUnexpectedFiles(dataRoot, manifest);
      return ValidatedBackup(manifest: manifest, dataRoot: dataRoot);
    } on BackupException {
      rethrow;
    } on FormatException catch (error) {
      throw BackupException(
        BackupFailure.corrupted,
        'The backup manifest is invalid.',
        error,
      );
    } on SqliteException catch (error) {
      throw BackupException(
        BackupFailure.corrupted,
        'The backup database could not be opened.',
        error,
      );
    } catch (error) {
      throw BackupException(
        BackupFailure.corrupted,
        'Backup validation failed.',
        error,
      );
    }
  }

  void _validateManifestHeader(BackupManifest manifest) {
    if (manifest.format != BackupManifest.formatName) {
      throw const BackupException(
        BackupFailure.unsupportedFormat,
        'Unknown backup format.',
      );
    }
    if (manifest.formatVersion != BackupManifest.currentFormatVersion) {
      throw const BackupException(
        BackupFailure.unsupportedFormat,
        'Unsupported backup format version.',
      );
    }
    if (manifest.databaseSchemaVersion > currentSchemaVersion) {
      throw const BackupException(
        BackupFailure.newerSchema,
        'Backup schema is newer than this app.',
      );
    }
    if (manifest.databaseSchemaVersion <= 0 ||
        manifest.itemCount < 0 ||
        manifest.channelCount < 0 ||
        manifest.attachmentCount < 0 ||
        !_isSha256(manifest.databaseSha256)) {
      throw const BackupException(
        BackupFailure.corrupted,
        'Manifest values are invalid.',
      );
    }
  }

  Future<void> _validateAttachments(
    Directory dataRoot,
    List<SnapshotAttachment> attachments,
    List<BackupFileEntry> files,
  ) async {
    final manifestFiles = <String, BackupFileEntry>{};
    for (final entry in files) {
      final archivePath = normalizeArchivePath(entry.path);
      if (!archivePath.startsWith('attachments/') ||
          entry.size < 0 ||
          !_isSha256(entry.sha256) ||
          manifestFiles.containsKey(archivePath)) {
        throw const BackupException(
          BackupFailure.corrupted,
          'Manifest attachment entry is invalid.',
        );
      }
      manifestFiles[archivePath] = entry;
    }

    final requiredPaths = <String>{};
    for (final attachment in attachments) {
      final archivePath = normalizeArchivePath(attachment.relativePath);
      if (!archivePath.startsWith('attachments/')) {
        throw const BackupException(
          BackupFailure.corrupted,
          'Attachment path is outside managed storage.',
        );
      }
      requiredPaths.add(archivePath);
      final entry = manifestFiles[archivePath];
      if (entry == null) {
        throw BackupException(
          BackupFailure.missingAttachment,
          'A referenced attachment is missing: ${attachment.id}',
        );
      }
      final file = _resolveDataFile(dataRoot, archivePath);
      if (!await file.exists()) {
        throw BackupException(
          BackupFailure.missingAttachment,
          'A referenced attachment is missing: ${attachment.id}',
        );
      }
      final size = await file.length();
      if (size != entry.size ||
          (attachment.byteSize != null && attachment.byteSize != size) ||
          await sha256File(file) != entry.sha256) {
        throw const BackupException(
          BackupFailure.corrupted,
          'Attachment size or checksum mismatch.',
        );
      }
    }
    if (requiredPaths.length != manifestFiles.length) {
      throw const BackupException(
        BackupFailure.corrupted,
        'Manifest contains unexpected attachment files.',
      );
    }
  }

  Future<void> _rejectUnexpectedFiles(
    Directory dataRoot,
    BackupManifest manifest,
  ) async {
    final expected = <String>{
      'manifest.json',
      'database/stash.sqlite',
      ...manifest.files.map((entry) => normalizeArchivePath(entry.path)),
    };
    await for (final entity in dataRoot.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = normalizeArchivePath(
        path.relative(entity.path, from: dataRoot.path).replaceAll('\\', '/'),
      );
      if (!expected.contains(relative)) {
        throw BackupException(
          BackupFailure.corrupted,
          'Unexpected archive entry: $relative',
        );
      }
    }
  }
}

Future<String> sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

File _resolveDataFile(Directory root, String archivePath) {
  final safePath = normalizeArchivePath(archivePath);
  final resolved = path.normalize(
    path.joinAll([root.path, ...safePath.split('/')]),
  );
  if (!path.isWithin(root.path, resolved)) {
    throw BackupException(
      BackupFailure.invalidPath,
      'Path escapes backup root: $archivePath',
    );
  }
  return File(resolved);
}
