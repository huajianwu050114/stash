import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import '../core/database/app_database.dart';
import '../features/attachments/data/attachment_repository.dart';
import '../features/attachments/data/image_import_sources.dart';
import '../features/channels/data/channel_repository.dart';
import '../features/channels/domain/channel.dart';
import '../features/items/data/item_repository.dart';
import '../features/items/domain/item.dart';
import '../features/quick_stash/application/quick_stash_controller.dart';
import '../features/quick_stash/application/quick_stash_settings_controller.dart';
import '../features/quick_stash/data/quick_stash_settings_repository.dart';
import '../platform/desktop_window/desktop_window_service.dart';
import '../platform/global_hotkey/global_hotkey_service.dart';
import 'appearance.dart';

/// The single on-device SQLite database. The database is the source of
/// truth; no additional in-memory copy of items is kept anywhere.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase.open();
  ref.onDispose(() => database.close());
  return database;
});

final itemRepositoryProvider = Provider<ItemRepository>(
  (ref) => ItemRepository(ref.watch(databaseProvider)),
);

final channelRepositoryProvider = Provider<ChannelRepository>(
  (ref) => ChannelRepository(ref.watch(databaseProvider)),
);

final attachmentRepositoryProvider = Provider<AttachmentRepository>(
  (ref) => AttachmentRepository(ref.watch(databaseProvider)),
);

final clipboardReaderProvider = Provider<ClipboardReaderGateway>(
  (ref) => const SystemClipboardReaderGateway(),
);

final imagePickerProvider = Provider<ImagePickerGateway>(
  (ref) => const FilePickerImageGateway(),
);

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
      (ref) => QuickStashSettingsRepository(MemoryQuickStashPreferenceStore()),
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

final appearanceRepositoryProvider = Provider<AppearanceRepository>(
  (ref) => AppearanceRepository(SharedPreferencesAppearancePreferences()),
);

final appearanceProvider =
    AsyncNotifierProvider<AppearanceController, ThemeMode>(
      AppearanceController.new,
    );

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
