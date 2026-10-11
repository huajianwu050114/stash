import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/app_profile.dart';
import 'app/providers.dart';
import 'core/database/app_database.dart';
import 'core/preferences/profiled_preferences.dart';
import 'core/storage/app_storage_paths.dart';
import 'features/quick_stash/application/quick_stash_controller.dart';
import 'platform/desktop_window/desktop_window_service.dart';
import 'platform/desktop_window/window_manager_desktop_window_service.dart';
import 'platform/global_hotkey/global_hotkey_service.dart';
import 'platform/global_hotkey/hotkey_manager_service.dart';
import 'platform/system_tray/desktop_app_lifecycle.dart';
import 'platform/system_tray/desktop_tray_service.dart';

Future<void> bootstrap(AppProfile profile) async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await AppStoragePaths.resolve(profile);
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
  final database = AppDatabase.open(storage: storage);
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
      ],
      child: const StashApp(),
    ),
  );
}
