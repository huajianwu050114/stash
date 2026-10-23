import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:drift/native.dart';

import '../core/database/app_database.dart';
import '../core/preferences/profiled_preferences.dart';
import '../core/storage/app_storage_paths.dart';
import '../features/attachments/data/attachment_repository.dart';
import '../features/attachments/data/file_import_sources.dart';
import '../features/attachments/data/image_import_sources.dart';
import '../features/backup/data/backup_archive.dart';
import '../features/backup/data/backup_preferences.dart';
import '../features/backup/data/backup_service.dart';
import '../features/backup/data/backup_validator.dart';
import '../features/backup/data/pending_restore_store.dart';
import '../features/backup/data/restore_coordinator.dart';
import '../features/backup/presentation/backup_restore_controller.dart';
import '../features/channels/data/channel_repository.dart';
import '../features/channels/domain/channel.dart';
import '../features/items/data/item_repository.dart';
import '../features/items/domain/item.dart';
import '../features/quick_channel/application/quick_channel_controller.dart';
import '../features/quick_channel/data/quick_channel_configuration_repository.dart';
import '../features/quick_stash/application/quick_stash_controller.dart';
import '../features/quick_stash/application/quick_stash_settings_controller.dart';
import '../features/quick_stash/data/quick_stash_settings_repository.dart';
import '../features/sync/data/sync_outbox_repository.dart';
import '../platform/desktop_window/desktop_window_service.dart';
import '../platform/attachment_file_actions/attachment_file_actions.dart';
import '../platform/backup/backup_platform.dart';
import '../platform/global_hotkey/global_hotkey_service.dart';
import 'appearance.dart';
import 'app_profile.dart';
import 'desktop_shell_preferences.dart';

final appProfileProvider = Provider<AppProfile>((ref) => AppProfile.stable);

/// Production overrides this with a resolved profile root. An unconfigured
/// container (including widget tests) gets an isolated temporary root and can
/// therefore never fall through to Stable or Dev storage.
final appStoragePathsProvider = Provider<AppStoragePaths>((ref) {
  final temporarySupport = Directory.systemTemp.createTempSync(
    'stash-provider-',
  );
  ref.onDispose(() {
    if (temporarySupport.existsSync()) {
      temporarySupport.deleteSync(recursive: true);
    }
  });
  return AppStoragePaths.fromSupportDirectory(
    profile: ref.watch(appProfileProvider),
    supportDirectory: temporarySupport,
  );
});

/// Tests default to an in-memory backend. Production replaces this in
/// [bootstrap] with the profile-scoped SharedPreferences backend.
final profiledPreferencesProvider = Provider<ProfiledPreferences>(
  (ref) => ProfiledPreferences(
    namespace: ref.watch(appProfileProvider).preferenceNamespace,
    backend: MemoryPreferenceBackend(),
  ),
);

/// The single on-device SQLite database. The database is the source of
/// truth; no additional in-memory copy of items is kept anywhere.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(NativeDatabase.memory());
  ref.onDispose(() => database.close());
  return database;
});

final syncOutboxRepositoryProvider = Provider<SyncOutboxRepository>(
  (ref) => SyncOutboxRepository(ref.watch(databaseProvider)),
);

final itemRepositoryProvider = Provider<ItemRepository>(
  (ref) => ItemRepository(
    ref.watch(databaseProvider),
    outbox: ref.watch(syncOutboxRepositoryProvider),
  ),
);

final channelRepositoryProvider = Provider<ChannelRepository>(
  (ref) => ChannelRepository(
    ref.watch(databaseProvider),
    outbox: ref.watch(syncOutboxRepositoryProvider),
  ),
);

final attachmentRepositoryProvider = Provider<AttachmentRepository>((ref) {
  final storage = ref.watch(appStoragePathsProvider);
  return AttachmentRepository(
    ref.watch(databaseProvider),
    storageRoot: storage.root,
  );
});

final clipboardReaderProvider = Provider<ClipboardReaderGateway>(
  (ref) => const SystemClipboardReaderGateway(),
);

final imagePickerProvider = Provider<ImagePickerGateway>(
  (ref) => const FilePickerImageGateway(),
);

final filePickerProvider = Provider<FilePickerGateway>(
  (ref) => const SystemFilePickerGateway(),
);

final attachmentFileActionsProvider = Provider<AttachmentFileActions>(
  (ref) => const SystemAttachmentFileActions(),
);

final backupArchiveCodecProvider = Provider<BackupArchiveCodec>(
  (ref) => const ZipBackupArchiveCodec(),
);

final backupFilePickerProvider = Provider<BackupFilePicker>(
  (ref) => const SystemBackupFilePicker(),
);

final backupDirectoryResolverProvider = Provider<BackupDirectoryResolver>(
  (ref) => const DocumentsBackupDirectoryResolver(),
);

final backupFolderActionsProvider = Provider<BackupFolderActions>(
  (ref) => const SystemBackupFolderActions(),
);

final backupPreferencesProvider = Provider<BackupPreferences>(
  (ref) => BackupPreferences(ref.watch(profiledPreferencesProvider)),
);

final backupValidatorProvider = Provider<BackupValidator>(
  (ref) => BackupValidator(
    archiveCodec: ref.watch(backupArchiveCodecProvider),
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
  ),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    profile: ref.watch(appProfileProvider),
    storage: ref.watch(appStoragePathsProvider),
    appVersion: '0.5.0+1',
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
    archiveCodec: ref.watch(backupArchiveCodecProvider),
  ),
);

final pendingRestoreStoreProvider = Provider<PendingRestoreStore>(
  (ref) => PendingRestoreStore(storage: ref.watch(appStoragePathsProvider)),
);

final restoreCoordinatorProvider = Provider<RestoreCoordinator>(
  (ref) => RestoreCoordinator(
    storage: ref.watch(appStoragePathsProvider),
    backupService: ref.watch(backupServiceProvider),
    validator: ref.watch(backupValidatorProvider),
    pendingStore: ref.watch(pendingRestoreStoreProvider),
    backupDirectoryResolver: ref.watch(backupDirectoryResolverProvider),
  ),
);

final backupRestoreControllerProvider = Provider<BackupRestoreController>((
  ref,
) {
  final controller = BackupRestoreController(
    backupService: ref.watch(backupServiceProvider),
    restoreCoordinator: ref.watch(restoreCoordinatorProvider),
    preferences: ref.watch(backupPreferencesProvider),
    filePicker: ref.watch(backupFilePickerProvider),
    directoryResolver: ref.watch(backupDirectoryResolverProvider),
    folderActions: ref.watch(backupFolderActionsProvider),
  );
  unawaited(controller.initialize());
  ref.onDispose(controller.dispose);
  return controller;
});

final startupRestoreNoticeProvider = Provider<String?>((ref) => null);

final desktopWindowServiceProvider = Provider<DesktopWindowService>(
  (ref) => const NoopDesktopWindowService(),
);

final globalHotkeyServiceProvider = Provider<GlobalHotkeyService>(
  (ref) => const NoopGlobalHotkeyService(),
);

final quickStashControllerProvider = Provider<QuickStashController>((ref) {
  final controller = QuickStashController(
    ref.watch(desktopWindowServiceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final quickStashSettingsRepositoryProvider =
    Provider<QuickStashSettingsRepository>(
      (ref) => QuickStashSettingsRepository(
        SharedPreferencesQuickStashStore(
          ref.watch(profiledPreferencesProvider),
        ),
        globalShortcutsEnabledByDefault: ref
            .watch(appProfileProvider)
            .globalShortcutsEnabledByDefault,
      ),
    );

final quickStashSettingsControllerProvider =
    Provider<QuickStashSettingsController>((ref) {
      final quickStash = ref.watch(quickStashControllerProvider);
      final controller = QuickStashSettingsController(
        repository: ref.watch(quickStashSettingsRepositoryProvider),
        hotkeys: ref.watch(globalHotkeyServiceProvider),
        onGlobalShortcut: () => unawaited(quickStash.toggleQuick()),
      );
      unawaited(controller.initialize());
      ref.onDispose(controller.dispose);
      return controller;
    });

final quickChannelConfigurationRepositoryProvider =
    Provider<QuickChannelConfigurationRepository>(
      (ref) => QuickChannelConfigurationRepository(
        SharedPreferencesQuickStashStore(
          ref.watch(profiledPreferencesProvider),
        ),
      ),
    );

final quickChannelControllerProvider = Provider<QuickChannelController>((ref) {
  final surface = ref.watch(quickStashControllerProvider);
  final controller = QuickChannelController(
    repository: ref.watch(quickChannelConfigurationRepositoryProvider),
    channels: ref.watch(channelRepositoryProvider),
    hotkeys: ref.watch(globalHotkeyServiceProvider),
    quickStashSettings: ref.watch(quickStashSettingsControllerProvider),
    onGlobalShortcut: (channelId) =>
        unawaited(surface.toggleQuickChannel(channelId)),
  );
  unawaited(controller.initialize());
  ref.onDispose(controller.dispose);
  return controller;
});

final appearanceRepositoryProvider = Provider<AppearanceRepository>(
  (ref) => AppearanceRepository(
    SharedPreferencesAppearancePreferences(
      ref.watch(profiledPreferencesProvider),
    ),
  ),
);

final appearanceProvider =
    AsyncNotifierProvider<AppearanceController, ThemeMode>(
      AppearanceController.new,
    );

final desktopShellPreferencesRepositoryProvider =
    Provider<DesktopShellPreferencesRepository>(
      (ref) => DesktopShellPreferencesRepository(
        SharedPreferencesDesktopShellPreferences(
          ref.watch(profiledPreferencesProvider),
        ),
      ),
    );

final desktopSidebarCollapsedProvider =
    AsyncNotifierProvider<DesktopSidebarController, bool>(
      DesktopSidebarController.new,
    );

final desktopSidebarWidthProvider =
    AsyncNotifierProvider<DesktopSidebarWidthController, double>(
      DesktopSidebarWidthController.new,
    );

class DesktopSidebarController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref
      .watch(desktopShellPreferencesRepositoryProvider)
      .loadSidebarCollapsed();

  Future<void> setCollapsed(bool collapsed) async {
    state = AsyncData(collapsed);
    await ref
        .read(desktopShellPreferencesRepositoryProvider)
        .saveSidebarCollapsed(collapsed);
  }
}

class DesktopSidebarWidthController extends AsyncNotifier<double> {
  @override
  Future<double> build() => ref
      .watch(desktopShellPreferencesRepositoryProvider)
      .loadSidebarExpandedWidth();

  void previewWidth(double width) {
    state = AsyncData(DesktopSidebarDimensions.clampExpandedWidth(width));
  }

  Future<void> persistWidth() async {
    final width = state.value ?? DesktopSidebarDimensions.defaultExpandedWidth;
    await ref
        .read(desktopShellPreferencesRepositoryProvider)
        .saveSidebarExpandedWidth(width);
  }

  Future<void> resetWidth() async {
    previewWidth(DesktopSidebarDimensions.defaultExpandedWidth);
    await persistWidth();
  }
}

class AppearanceController extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() => ref.watch(appearanceRepositoryProvider).load();

  Future<void> setThemeMode(ThemeMode mode) async {
    state = AsyncData(mode);
    await ref.read(appearanceRepositoryProvider).save(mode);
  }
}

/// Reactive view of all non-deleted items, newest-updated first.
final activeItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchActiveItems(),
);

final inboxItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchInboxItems(),
);

final pinnedItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchPinnedItems(),
);

final channelItemsProvider = StreamProvider.family<List<Item>, String>(
  (ref, id) => ref.watch(itemRepositoryProvider).watchItemsInChannel(id),
);

final rootChannelsProvider = StreamProvider<List<Channel>>(
  (ref) => ref.watch(channelRepositoryProvider).watchRootChannels(),
);

final activeChannelsProvider = StreamProvider<List<Channel>>(
  (ref) => ref.watch(channelRepositoryProvider).watchActiveChannels(),
);

final childChannelsProvider = StreamProvider.family<List<Channel>, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).watchChildChannels(id),
);

final channelByIdProvider = StreamProvider.family<Channel?, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).watchChannelById(id),
);

final channelBreadcrumbsProvider = FutureProvider.family<List<Channel>, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).getBreadcrumbs(id),
);

/// Reactive view of one item for detail and edit flows.
final itemByIdProvider = StreamProvider.family<Item?, String>(
  (ref, id) => ref.watch(itemRepositoryProvider).watchItemById(id),
);
