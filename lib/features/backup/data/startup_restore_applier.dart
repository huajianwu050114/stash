import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_storage_paths.dart';
import '../domain/backup_exception.dart';
import 'backup_validator.dart';
import 'pending_restore_store.dart';

class StartupRestoreNotice {
  const StartupRestoreNotice(this.message);

  final String message;

  static File fileFor(AppStoragePaths storage) => File(
    path.join(
      storage.maintenanceDirectory.path,
      'restore_result_${storage.profile.preferenceNamespace}.json',
    ),
  );

  static Future<StartupRestoreNotice?> consume(AppStoragePaths storage) async {
    final file = fileFor(storage);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final message = (decoded as Map<Object?, Object?>)['message'] as String;
      return StartupRestoreNotice(message);
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

class StartupRestoreSession {
  StartupRestoreSession._({
    required this.storage,
    required this.pendingStore,
    required this.pending,
  });

  final AppStoragePaths storage;
  final PendingRestoreStore pendingStore;
  final PendingRestore pending;
  bool _finished = false;

  Future<void> commit() async {
    if (_finished) return;
    final rollback = pending.rollbackDirectory == null
        ? null
        : Directory(pending.rollbackDirectory!);
    if (rollback != null && await rollback.exists()) {
      await rollback.delete(recursive: true);
    }
    if (await pending.container.exists()) {
      await pending.container.delete(recursive: true);
    }
    await pendingStore.clear();
    await _writeNotice(storage, 'Backup restored successfully.');
    _finished = true;
  }

  Future<void> rollback() async {
    if (_finished) return;
    final rollback = pending.rollbackDirectory == null
        ? null
        : Directory(pending.rollbackDirectory!);
    if (await storage.root.exists()) {
      await storage.root.delete(recursive: true);
    }
    if (pending.hadCurrentRoot == true &&
        rollback != null &&
        await rollback.exists()) {
      await rollback.rename(storage.root.path);
    }
    if (await pending.container.exists()) {
      await pending.container.delete(recursive: true);
    }
    await pendingStore.clear();
    await _writeNotice(storage, 'Restore was rolled back.');
    _finished = true;
  }
}

class StartupRestoreApplier {
  StartupRestoreApplier({
    required this.storage,
    required this.validator,
    required this.pendingStore,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AppStoragePaths storage;
  final BackupValidator validator;
  final PendingRestoreStore pendingStore;
  final Uuid _uuid;

  Future<StartupRestoreSession?> applyPending() async {
    final existing = await pendingStore.read();
    if (existing == null) return null;
    PendingRestore pending = existing;
    try {
      _validateMaintenancePaths(pending);
    } catch (_) {
      await pendingStore.clear();
      await _writeNotice(storage, 'Restore was rolled back.');
      rethrow;
    }
    try {
      if (pending.state == PendingRestoreState.ready) {
        await validator.validateDirectory(
          dataRoot: pending.profileDirectory,
          manifestFile: pending.manifestFile,
        );
        final rollback = Directory(
          path.join(storage.restoreRollbackDirectory.path, _uuid.v4()),
        );
        final hadCurrentRoot = await storage.root.exists();
        pending = pending.copyWith(
          state: PendingRestoreState.switching,
          rollbackDirectory: rollback.path,
          hadCurrentRoot: hadCurrentRoot,
        );
        await pendingStore.write(pending);
        await rollback.parent.create(recursive: true);
        if (hadCurrentRoot) {
          await storage.root.rename(rollback.path);
        }
        try {
          await pending.profileDirectory.rename(storage.root.path);
        } catch (_) {
          if (hadCurrentRoot && await rollback.exists()) {
            await rollback.rename(storage.root.path);
          }
          rethrow;
        }
        pending = pending.copyWith(state: PendingRestoreState.switched);
        await pendingStore.write(pending);
      } else if (pending.state == PendingRestoreState.switching) {
        pending = await _resumeSwitch(pending);
      }

      await validator.validateDirectory(
        dataRoot: storage.root,
        manifestFile: pending.manifestFile,
      );
      return StartupRestoreSession._(
        storage: storage,
        pendingStore: pendingStore,
        pending: pending,
      );
    } catch (error) {
      await _rollbackFailedSwitch(pending);
      throw BackupException(
        BackupFailure.restoreRolledBack,
        'Startup restore failed and the previous profile was restored.',
        error,
      );
    }
  }

  Future<PendingRestore> _resumeSwitch(PendingRestore pending) async {
    final rollback = Directory(pending.rollbackDirectory!);
    final activeExists = await storage.root.exists();
    final stagedExists = await pending.profileDirectory.exists();
    final rollbackExists = await rollback.exists();
    if (activeExists && rollbackExists && !stagedExists) {
      final switched = pending.copyWith(state: PendingRestoreState.switched);
      await pendingStore.write(switched);
      return switched;
    }
    if (!activeExists && rollbackExists && stagedExists) {
      await pending.profileDirectory.rename(storage.root.path);
      final switched = pending.copyWith(state: PendingRestoreState.switched);
      await pendingStore.write(switched);
      return switched;
    }
    throw const BackupException(
      BackupFailure.restoreRolledBack,
      'Interrupted restore state is ambiguous.',
    );
  }

  Future<void> _rollbackFailedSwitch(PendingRestore pending) async {
    final rollbackPath = pending.rollbackDirectory;
    if (rollbackPath != null) {
      final rollback = Directory(rollbackPath);
      if (await rollback.exists()) {
        if (await storage.root.exists()) {
          await storage.root.delete(recursive: true);
        }
        await rollback.rename(storage.root.path);
      } else if (pending.hadCurrentRoot == false &&
          await storage.root.exists()) {
        await storage.root.delete(recursive: true);
      }
    }
    if (await pending.container.exists()) {
      await pending.container.delete(recursive: true);
    }
    await pendingStore.clear();
    await _writeNotice(storage, 'Restore was rolled back.');
  }

  void _validateMaintenancePaths(PendingRestore pending) {
    final stagingRoot = path.normalize(storage.restoreStagingDirectory.path);
    final container = path.normalize(pending.container.path);
    final manifest = path.normalize(pending.manifestFile.path);
    if (!path.isWithin(stagingRoot, container) ||
        !path.isWithin(container, manifest)) {
      throw const BackupException(
        BackupFailure.restorePreparationFailed,
        'Pending restore paths are outside profile maintenance storage.',
      );
    }
    final rollback = pending.rollbackDirectory;
    if (rollback != null &&
        !path.isWithin(
          path.normalize(storage.restoreRollbackDirectory.path),
          path.normalize(rollback),
        )) {
      throw const BackupException(
        BackupFailure.restorePreparationFailed,
        'Pending rollback path is outside profile maintenance storage.',
      );
    }
  }
}

Future<void> _writeNotice(AppStoragePaths storage, String message) async {
  final file = StartupRestoreNotice.fileFor(storage);
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode({'message': message}), flush: true);
}
