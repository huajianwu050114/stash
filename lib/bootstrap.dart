import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/app_profile.dart';
import 'app/providers.dart';
import 'core/database/app_database.dart';
import 'core/preferences/profiled_preferences.dart';
import 'core/storage/app_storage_paths.dart';
import 'features/backup/data/backup_archive.dart';
import 'features/backup/data/backup_service.dart';
import 'features/backup/data/backup_validator.dart';
import 'features/backup/data/pending_restore_store.dart';
import 'features/backup/data/pre_migration_backup.dart';
import 'features/backup/data/startup_restore_applier.dart';
import 'features/backup/domain/backup_exception.dart';
import 'features/quick_stash/application/quick_stash_controller.dart';
import 'platform/desktop_window/desktop_window_service.dart';
import 'platform/backup/backup_platform.dart';
import 'platform/desktop_window/window_manager_desktop_window_service.dart';
import 'platform/global_hotkey/global_hotkey_service.dart';
import 'platform/global_hotkey/hotkey_manager_service.dart';
import 'platform/system_tray/desktop_app_lifecycle.dart';
import 'platform/system_tray/desktop_tray_service.dart';

Future<void> bootstrap(AppProfile profile) async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await AppStoragePaths.resolve(profile);
  const backupArchive = ZipBackupArchiveCodec();
  final backupValidator = BackupValidator(
    archiveCodec: backupArchive,
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
  );
  final pendingRestoreStore = PendingRestoreStore(storage: storage);
  final restoreApplier = StartupRestoreApplier(
    storage: storage,
    validator: backupValidator,
    pendingStore: pendingRestoreStore,
  );
  StartupRestoreSession? restoreSession;
  String? startupRestoreError;
  try {
    restoreSession = await restoreApplier.applyPending();
  } on Exception catch (error) {
    startupRestoreError = error is BackupException
        ? error.userMessage
        : 'Restore was rolled back.';
  }
  await storage.ensureCreated();
  final preferences = ProfiledPreferences(
    namespace: profile.preferenceNamespace,
    backend: SharedPreferencesBackend(),
  );
  final DesktopWindowService window = Platform.isWindows
      ? WindowManagerDesktopWindowService(title: profile.displayName)
      : const NoopDesktopWindowService();
  final GlobalHotkeyService hotkeys = Platform.isWindows
      ? HotkeyManagerService()
      : const NoopGlobalHotkeyService();
  await window.initialize();
  await hotkeys.initialize();
  final backupService = BackupService(
    profile: profile,
    storage: storage,
    appVersion: '0.5.0+1',
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
    archiveCodec: backupArchive,
  );
  final preMigrationBackup = PreMigrationBackupCoordinator(
    storage: storage,
    backupService: backupService,
    backupDirectoryResolver: const DocumentsBackupDirectoryResolver(),
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
    clock: DateTime.now,
  );
  AppDatabase? openedDatabase;
  late AppDatabase database;
  try {
    await preMigrationBackup.createIfNeeded();
    openedDatabase = AppDatabase.open(storage: storage);
    await openedDatabase.customSelect('PRAGMA quick_check').get();
    await restoreSession?.commit();
    database = openedDatabase;
  } catch (_) {
    if (restoreSession == null) rethrow;
    await openedDatabase?.close();
    await restoreSession.rollback();
    await storage.ensureCreated();
    database = AppDatabase.open(storage: storage);
    await database.customSelect('PRAGMA quick_check').get();
  }
  final startupNotice =
      (await StartupRestoreNotice.consume(storage))?.message ??
      startupRestoreError;
  final quickStash = QuickStashController(window);
  if (Platform.isWindows) {
    final lifecycle = DesktopAppLifecycle(
      window: window,
      tray: TrayManagerDesktopTrayService(
        label: profile.displayName,
        identifier: profile.trayIdentifier,
      ),
      hotkeys: hotkeys,
      onOpenFull: quickStash.showFull,
      onOpenQuick: quickStash.showQuick,
      closeDatabase: database.close,
      disposeControllers: quickStash.dispose,
    );
    await lifecycle.initialize();
  }
  runApp(
    ProviderScope(
      overrides: [
        appProfileProvider.overrideWithValue(profile),
        appStoragePathsProvider.overrideWithValue(storage),
        profiledPreferencesProvider.overrideWithValue(preferences),
        desktopWindowServiceProvider.overrideWithValue(window),
        globalHotkeyServiceProvider.overrideWithValue(hotkeys),
        databaseProvider.overrideWithValue(database),
        quickStashControllerProvider.overrideWithValue(quickStash),
        startupRestoreNoticeProvider.overrideWithValue(startupNotice),
      ],
      child: const StashApp(),
    ),
  );
}
