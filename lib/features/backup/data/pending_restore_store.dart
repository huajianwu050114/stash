import 'dart:convert';
import 'dart:io';

import '../../../app/app_profile.dart';
import '../../../core/storage/app_storage_paths.dart';
import '../domain/backup_exception.dart';

enum PendingRestoreState { ready, switching, switched }

class PendingRestore {
  const PendingRestore({
    required this.profile,
    required this.state,
    required this.stagingDirectory,
    required this.manifestPath,
    required this.sourceBackupPath,
    required this.safetyBackupPath,
    required this.createdAtUtc,
    this.rollbackDirectory,
    this.hadCurrentRoot,
  });

  factory PendingRestore.fromJson(Map<String, Object?> json) => PendingRestore(
    profile: AppProfile.values.byName(json['profile']! as String),
    state: PendingRestoreState.values.byName(json['state']! as String),
    stagingDirectory: json['stagingDirectory']! as String,
    manifestPath: json['manifestPath']! as String,
    sourceBackupPath: json['sourceBackupPath']! as String,
    safetyBackupPath: json['safetyBackupPath']! as String,
    createdAtUtc: DateTime.parse(json['createdAtUtc']! as String).toUtc(),
    rollbackDirectory: json['rollbackDirectory'] as String?,
    hadCurrentRoot: json['hadCurrentRoot'] as bool?,
  );

  final AppProfile profile;
  final PendingRestoreState state;
  final String stagingDirectory;
  final String manifestPath;
  final String sourceBackupPath;
  final String safetyBackupPath;
  final DateTime createdAtUtc;
  final String? rollbackDirectory;
  final bool? hadCurrentRoot;

  Directory get container => Directory(stagingDirectory);
  Directory get profileDirectory => Directory('$stagingDirectory/profile');
  File get manifestFile => File(manifestPath);

  PendingRestore copyWith({
    PendingRestoreState? state,
    String? rollbackDirectory,
    bool? hadCurrentRoot,
  }) => PendingRestore(
    profile: profile,
    state: state ?? this.state,
    stagingDirectory: stagingDirectory,
    manifestPath: manifestPath,
    sourceBackupPath: sourceBackupPath,
    safetyBackupPath: safetyBackupPath,
    createdAtUtc: createdAtUtc,
    rollbackDirectory: rollbackDirectory ?? this.rollbackDirectory,
    hadCurrentRoot: hadCurrentRoot ?? this.hadCurrentRoot,
  );

  Map<String, Object?> toJson() => {
    'profile': profile.name,
    'state': state.name,
    'stagingDirectory': stagingDirectory,
    'manifestPath': manifestPath,
    'sourceBackupPath': sourceBackupPath,
    'safetyBackupPath': safetyBackupPath,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'rollbackDirectory': rollbackDirectory,
    'hadCurrentRoot': hadCurrentRoot,
  };
}

class PendingRestoreStore {
  const PendingRestoreStore({required this.storage});

  final AppStoragePaths storage;

  Future<PendingRestore?> read() async {
    final file = storage.pendingRestoreFile;
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final pending = PendingRestore.fromJson(
        (decoded as Map<Object?, Object?>).cast<String, Object?>(),
      );
      if (pending.profile != storage.profile) {
        throw const BackupException(
          BackupFailure.restorePreparationFailed,
          'Pending restore belongs to another profile.',
        );
      }
      return pending;
    } catch (error) {
      if (error is BackupException) rethrow;
      throw BackupException(
        BackupFailure.restorePreparationFailed,
        'Pending restore metadata is invalid.',
        error,
      );
    }
  }

  Future<void> write(PendingRestore pending) async {
    if (pending.profile != storage.profile) {
      throw const BackupException(
        BackupFailure.restorePreparationFailed,
        'Cannot write pending restore for another profile.',
      );
    }
    final file = storage.pendingRestoreFile;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(pending.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> clear() async {
    if (await storage.pendingRestoreFile.exists()) {
      await storage.pendingRestoreFile.delete();
    }
  }
}
