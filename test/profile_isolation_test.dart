import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/app/app_profile.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/desktop_shell_preferences.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/core/preferences/profiled_preferences.dart';
import 'package:stash/core/storage/app_storage_paths.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/quick_channel/data/quick_channel_configuration_repository.dart';
import 'package:stash/features/quick_channel/domain/quick_channel_configuration.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';

void main() {
  late Directory temporarySupport;
  late AppStoragePaths stableStorage;
  late AppStoragePaths devStorage;
  late List<AppDatabase> databases;

  setUp(() async {
    temporarySupport = await Directory.systemTemp.createTemp(
      'stash-profile-isolation-',
    );
    stableStorage = AppStoragePaths.fromSupportDirectory(
      profile: AppProfile.stable,
      supportDirectory: temporarySupport,
    );
    devStorage = AppStoragePaths.fromSupportDirectory(
      profile: AppProfile.dev,
      supportDirectory: temporarySupport,
    );
    await stableStorage.ensureCreated();
    await devStorage.ensureCreated();
    databases = [];
  });

  tearDown(() async {
    for (final database in databases.reversed) {
      await database.close();
    }
    if (await temporarySupport.exists()) {
      await temporarySupport.delete(recursive: true);
    }
  });

  test('database files and Items remain profile-specific', () async {
    final stableDatabase = AppDatabase.open(storage: stableStorage);
    final devDatabase = AppDatabase.open(storage: devStorage);
    databases.addAll([stableDatabase, devDatabase]);
    final stableItems = ItemRepository(stableDatabase);
    final devItems = ItemRepository(devDatabase);

    await stableItems.createItem(id: 'stable', content: 'ONLY-STABLE');
    expect(await devDatabase.select(devDatabase.items).get(), isEmpty);

    await devItems.createItem(id: 'dev', content: 'ONLY-DEV');
    expect(
      (await stableDatabase.select(stableDatabase.items).get()).map(
        (item) => item.content,
      ),
      ['ONLY-STABLE'],
    );
    expect(
      (await devDatabase.select(devDatabase.items).get()).map(
        (item) => item.content,
      ),
      ['ONLY-DEV'],
    );
    expect(await stableStorage.databaseFile.exists(), isTrue);
    expect(await devStorage.databaseFile.exists(), isTrue);
  });

  test('attachments remain under their profile roots', () async {
    final stableDatabase = AppDatabase.open(storage: stableStorage);
    final devDatabase = AppDatabase.open(storage: devStorage);
    databases.addAll([stableDatabase, devDatabase]);
    final stableAttachments = AttachmentRepository(
      stableDatabase,
      storageRoot: stableStorage.root,
    );
    final devAttachments = AttachmentRepository(
      devDatabase,
      storageRoot: devStorage.root,
    );

    final stable = await stableAttachments.importImage(
      id: 'only-stable',
      itemId: 'future-stable-item',
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
    );
    expect(path.isAbsolute(stable.relativePath), isFalse);
    expect(
      File(path.join(stableStorage.root.path, stable.relativePath))
          .existsSync(),
      isTrue,
    );
    expect(devStorage.attachmentsDirectory.listSync(), isEmpty);

    final dev = await devAttachments.importImage(
      id: 'only-dev',
      itemId: 'future-dev-item',
      bytes: Uint8List.fromList([4, 5, 6]),
      mimeType: 'image/png',
    );
    expect(
      File(path.join(devStorage.root.path, dev.relativePath)).existsSync(),
      isTrue,
    );
    expect(
      File(path.join(stableStorage.root.path, dev.relativePath)).existsSync(),
      isFalse,
    );

    final source = File(path.join(temporarySupport.path, 'dev-document.pdf'));
    await source.writeAsBytes([7, 8, 9]);
    final devFile = await devAttachments.importFile(
      id: 'dev-file',
      itemId: 'future-dev-item',
      sourceFile: source,
    );
    expect(
      File(path.join(devStorage.root.path, devFile.relativePath)).existsSync(),
      isTrue,
    );
    expect(
      File(path.join(stableStorage.root.path, devFile.relativePath))
          .existsSync(),
      isFalse,
    );
    expect(await source.exists(), isTrue);
  });

  test('device preferences remain profile-specific after reload', () async {
    final backend = MemoryPreferenceBackend();
    final stable = _preferences(AppProfile.stable, backend);
    final dev = _preferences(AppProfile.dev, backend);

    final stableShell = DesktopShellPreferencesRepository(
      SharedPreferencesDesktopShellPreferences(stable),
    );
    final devShell = DesktopShellPreferencesRepository(
      SharedPreferencesDesktopShellPreferences(dev),
    );
    await stableShell.saveSidebarCollapsed(true);
    await devShell.saveSidebarCollapsed(false);
    await stableShell.saveSidebarExpandedWidth(288);
    await devShell.saveSidebarExpandedWidth(332);
    expect(await stableShell.loadSidebarCollapsed(), isTrue);
    expect(await devShell.loadSidebarCollapsed(), isFalse);
    expect(await stableShell.loadSidebarExpandedWidth(), 288);
    expect(await devShell.loadSidebarExpandedWidth(), 332);

    final stableAppearance = AppearanceRepository(
      SharedPreferencesAppearancePreferences(stable),
    );
    final devAppearance = AppearanceRepository(
      SharedPreferencesAppearancePreferences(dev),
    );
    await stableAppearance.save(ThemeMode.dark);
    await devAppearance.save(ThemeMode.light);
    expect(await stableAppearance.load(), ThemeMode.dark);
    expect(await devAppearance.load(), ThemeMode.light);
  });

  test('Quick Stash settings and Dev hotkey default are isolated', () async {
    final backend = MemoryPreferenceBackend();
    final stableStore = SharedPreferencesQuickStashStore(
      _preferences(AppProfile.stable, backend),
    );
    final devStore = SharedPreferencesQuickStashStore(
      _preferences(AppProfile.dev, backend),
    );
    final stable = QuickStashSettingsRepository(stableStore);
    final dev = QuickStashSettingsRepository(
      devStore,
      globalShortcutsEnabledByDefault: false,
    );
    const stableShortcut = QuickStashShortcut(
      keyId: 0x0007003d,
      keyLabel: 'F4',
    );
    const devShortcut = QuickStashShortcut(keyId: 0x0007003e, keyLabel: 'F5');

    expect((await stable.load()).globalShortcutsEnabled, isTrue);
    expect((await dev.load()).globalShortcutsEnabled, isFalse);
    await stable.saveShortcut(stableShortcut);
    await dev.saveShortcut(devShortcut);
    await dev.saveGlobalShortcutsEnabled(true);

    expect((await stable.load()).globalShortcut, stableShortcut);
    expect((await stable.load()).globalShortcutsEnabled, isTrue);
    expect((await dev.load()).globalShortcut, devShortcut);
    expect((await dev.load()).globalShortcutsEnabled, isTrue);
  });

  test('Quick Channel configurations remain profile-specific', () async {
    final backend = MemoryPreferenceBackend();
    final stable = QuickChannelConfigurationRepository(
      SharedPreferencesQuickStashStore(
        _preferences(AppProfile.stable, backend),
      ),
    );
    final dev = QuickChannelConfigurationRepository(
      SharedPreferencesQuickStashStore(_preferences(AppProfile.dev, backend)),
    );
    const stableConfiguration = QuickChannelConfiguration(
      channelId: 'stable-channel',
      globalShortcut: QuickStashShortcut(keyId: 0x00070041, keyLabel: 'F8'),
    );
    const devConfiguration = QuickChannelConfiguration(
      channelId: 'dev-channel',
      globalShortcut: QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9'),
    );

    await stable.save([stableConfiguration]);
    expect(await dev.load(), isEmpty);
    await dev.save([devConfiguration]);
    expect((await stable.load()).single.channelId, 'stable-channel');
    expect((await dev.load()).single.channelId, 'dev-channel');
  });

  test('resolved profile paths cannot contain each other', () {
    final stableRoot = path.normalize(stableStorage.root.absolute.path);
    final devRoot = path.normalize(devStorage.root.absolute.path);

    expect(stableRoot, isNot(devRoot));
    expect(path.isWithin(stableRoot, devRoot), isFalse);
    expect(path.isWithin(devRoot, stableRoot), isFalse);
    expect(path.isWithin(stableRoot, devStorage.databaseFile.path), isFalse);
    expect(path.isWithin(devRoot, stableStorage.databaseFile.path), isFalse);
    expect(
      path.isWithin(stableRoot, devStorage.attachmentsDirectory.path),
      isFalse,
    );
    expect(
      path.isWithin(devRoot, stableStorage.attachmentsDirectory.path),
      isFalse,
    );
  });
}

ProfiledPreferences _preferences(
  AppProfile profile,
  PreferenceBackend backend,
) => ProfiledPreferences(
  namespace: profile.preferenceNamespace,
  backend: backend,
);
