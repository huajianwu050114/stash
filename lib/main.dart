import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/database/app_database.dart';
import 'features/quick_stash/application/quick_stash_controller.dart';
import 'features/quick_stash/data/quick_stash_settings_repository.dart';
import 'features/quick_channel/data/quick_channel_configuration_repository.dart';
import 'platform/desktop_window/desktop_window_service.dart';
import 'platform/desktop_window/window_manager_desktop_window_service.dart';
import 'platform/global_hotkey/global_hotkey_service.dart';
import 'platform/global_hotkey/hotkey_manager_service.dart';
import 'platform/system_tray/desktop_app_lifecycle.dart';
import 'platform/system_tray/desktop_tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final DesktopWindowService window = Platform.isWindows
      ? WindowManagerDesktopWindowService()
      : const NoopDesktopWindowService();
  final GlobalHotkeyService hotkeys = Platform.isWindows
      ? HotkeyManagerService()
      : const NoopGlobalHotkeyService();
  await window.initialize();
  await hotkeys.initialize();
  final database = AppDatabase.open();
  final quickStash = QuickStashController(window);
  final preferences = SharedPreferencesQuickStashStore();
  final quickStashSettings = QuickStashSettingsRepository(preferences);
  final quickChannels = QuickChannelConfigurationRepository(preferences);
  if (Platform.isWindows) {
    final lifecycle = DesktopAppLifecycle(
      window: window,
      tray: TrayManagerDesktopTrayService(),
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
        desktopWindowServiceProvider.overrideWithValue(window),
        globalHotkeyServiceProvider.overrideWithValue(hotkeys),
        databaseProvider.overrideWithValue(database),
        quickStashControllerProvider.overrideWithValue(quickStash),
        quickStashSettingsRepositoryProvider.overrideWithValue(
          quickStashSettings,
        ),
        quickChannelConfigurationRepositoryProvider.overrideWithValue(
          quickChannels,
        ),
      ],
      child: const StashApp(),
    ),
  );
}
