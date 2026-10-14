import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../../../core/storage/app_storage_paths.dart';
import '../../../platform/backup/backup_platform.dart';
import '../domain/backup_manifest.dart';
import 'backup_service.dart';

class PreMigrationBackupCoordinator {
  const PreMigrationBackupCoordinator({
    required this.storage,
    required this.backupService,
    required this.backupDirectoryResolver,
    required this.currentSchemaVersion,
    required this.clock,
  });

  final AppStoragePaths storage;
  final BackupService backupService;
  final BackupDirectoryResolver backupDirectoryResolver;
  final int currentSchemaVersion;
  final DateTime Function() clock;

  Future<BackupSummary?> createIfNeeded() async {
    final databaseFile = storage.databaseFile;
    if (!await databaseFile.exists()) return null;
    final database = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
    late final int existingVersion;
    try {
      existingVersion = database.userVersion;
    } finally {
      database.close();
    }
    if (existingVersion <= 0 || existingVersion >= currentSchemaVersion) {
      return null;
    }
    final folder = await backupDirectoryResolver.defaultBackupDirectory();
    await folder.create(recursive: true);
    final now = clock().toLocal();
    final destination = File(
      path.join(
        folder.path,
        'Pre-Migration-v$existingVersion-to-v$currentSchemaVersion-'
        '${_timestamp(now)}.stashbackup',
      ),
    );
    return backupService.createBackup(destinationFile: destination);
  }
}

String _timestamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}-'
    '${value.hour.toString().padLeft(2, '0')}'
    '${value.minute.toString().padLeft(2, '0')}'
    '${value.second.toString().padLeft(2, '0')}';
