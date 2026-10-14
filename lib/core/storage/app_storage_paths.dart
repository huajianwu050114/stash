import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../app/app_profile.dart';

class AppStoragePaths {
  AppStoragePaths._({required this.profile, required this.root});

  factory AppStoragePaths.fromSupportDirectory({
    required AppProfile profile,
    required Directory supportDirectory,
  }) => AppStoragePaths._(
    profile: profile,
    root: Directory(
      path.join(supportDirectory.path, profile.storageDirectoryName),
    ),
  );

  static Future<AppStoragePaths> resolve(AppProfile profile) async =>
      AppStoragePaths.fromSupportDirectory(
        profile: profile,
        supportDirectory: await getApplicationSupportDirectory(),
      );

  final AppProfile profile;
  final Directory root;

  Directory get databaseDirectory =>
      Directory(path.join(root.path, 'database'));
  File get databaseFile =>
      File(path.join(databaseDirectory.path, 'stash.sqlite'));
  Directory get attachmentsDirectory =>
      Directory(path.join(root.path, 'attachments'));

  /// Profile-aware maintenance data lives beside, never inside, the active
  /// profile root so a pending restore can replace that root safely.
  Directory get maintenanceDirectory =>
      Directory(path.join(root.parent.path, 'maintenance'));
  File get pendingRestoreFile => File(
    path.join(
      maintenanceDirectory.path,
      'pending_restore_${profile.preferenceNamespace}.json',
    ),
  );
  Directory get restoreStagingDirectory => Directory(
    path.join(
      maintenanceDirectory.path,
      'restore_staging',
      profile.preferenceNamespace,
    ),
  );
  Directory get restoreRollbackDirectory => Directory(
    path.join(
      maintenanceDirectory.path,
      'rollback',
      profile.preferenceNamespace,
    ),
  );
  Directory get backupStagingDirectory => Directory(
    path.join(
      maintenanceDirectory.path,
      'backup_staging',
      profile.preferenceNamespace,
    ),
  );

  Future<void> ensureCreated() async {
    await databaseDirectory.create(recursive: true);
    await attachmentsDirectory.create(recursive: true);
  }
}
