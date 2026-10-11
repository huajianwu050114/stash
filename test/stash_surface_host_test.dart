import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/items/presentation/item_detail_screen.dart';
import 'package:stash/features/quick_stash/application/quick_stash_controller.dart';
import 'package:stash/features/quick_stash/application/quick_stash_settings_controller.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/presentation/quick_stash_settings_screen.dart';
import 'package:stash/platform/desktop_window/desktop_window_service.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';

import 'test_database.dart';

void main() {
  testWidgets('full root switches to Quick Stash and back', (tester) async {
    final harness = await _SurfaceHarness.create(tester);
    await harness.pumpApp(tester);

    expect(find.byKey(const Key('empty-home')), findsOneWidget);

    await harness.controller.showQuick();
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-surface-host')), findsOneWidget);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);
    expect(find.byKey(const Key('empty-home')), findsNothing);

    await harness.controller.showFull();
    await pumpUi(tester);
    expect(find.byKey(const Key('empty-home')), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('a pushed item route switches to Quick Stash and resumes', (
    tester,
  ) async {
    final harness = await _SurfaceHarness.create(tester);
    final item = await ItemRepository(harness.database)
        .createItem(id: 'route-item', content: 'Route item');
    await harness.pumpApp(tester);

    await tester.tap(find.byKey(Key('item-preview-${item.id}')));
    await pumpUi(tester);
    expect(find.byType(ItemDetailScreen), findsOneWidget);

    await harness.controller.showQuick();
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);
    expect(find.byType(ItemDetailScreen), findsNothing);

    await harness.controller.showFull();
    await pumpUi(tester);
    expect(find.byType(ItemDetailScreen), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('settings route switches to Quick Stash and resumes', (
    tester,
  ) async {
    final harness = await _SurfaceHarness.create(tester);
    await harness.pumpApp(tester);

    await tester.tap(find.byKey(const Key('settings-button')));
    await pumpUi(tester);
    expect(find.byType(QuickStashSettingsScreen), findsOneWidget);

    await harness.controller.showQuick();
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);

    await harness.controller.showFull();
    await pumpUi(tester);
    expect(find.byType(QuickStashSettingsScreen), findsOneWidget);
    await harness.dispose(tester);
  });

  testWidgets('Quick Channel switches to Quick Stash and to full', (
    tester,
  ) async {
    final harness = await _SurfaceHarness.create(tester);
    final channel = await ChannelRepository(harness.database)
        .createRootChannel(id: 'quick-channel', name: 'Quick Channel');
    await harness.controller.showQuickChannel(channel.id);
    await harness.pumpApp(tester);

    expect(find.byKey(const Key('quick-channel-surface-host')), findsOneWidget);
    expect(find.byKey(const Key('quick-channel-title')), findsOneWidget);

    await harness.controller.showQuick();
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);
    expect(find.byKey(const Key('quick-channel-title')), findsNothing);

    await harness.controller.showQuickChannel(channel.id);
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-channel-title')), findsOneWidget);

    await harness.controller.showFull();
    await pumpUi(tester);
    expect(find.byKey(const Key('empty-home')), findsOneWidget);
    expect(find.byKey(const Key('quick-channel-title')), findsNothing);
    await harness.dispose(tester);
  });
}

class _SurfaceHarness {
  _SurfaceHarness(this.database, this.controller, this.settings);

  final AppDatabase database;
  final QuickStashController controller;
  final QuickStashSettingsController settings;

  static Future<_SurfaceHarness> create(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 800);
    tester.view.devicePixelRatio = 1;
    final database = createInMemoryDatabase();
    final controller = QuickStashController(_FakeWindow());
    final settings = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(
        MemoryQuickStashPreferenceStore(),
      ),
      hotkeys: const NoopGlobalHotkeyService(),
      onGlobalShortcut: () {},
    );
    await settings.initialize();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return _SurfaceHarness(database, controller, settings);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          quickStashControllerProvider.overrideWithValue(controller),
          quickStashSettingsControllerProvider.overrideWithValue(settings),
          appearanceRepositoryProvider.overrideWithValue(
            AppearanceRepository(_MemoryAppearancePreferences()),
          ),
        ],
        child: const StashApp(),
      ),
    );
    await pumpUi(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    controller.dispose();
    await database.close();
  }
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  String? value;

  @override
  Future<String?> getString(String key) async => value;

  @override
  Future<void> setString(String key, String value) async {
    this.value = value;
  }
}

class _FakeWindow implements DesktopWindowService {
  final Set<WindowFocusListener> _focusListeners = {};

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<bool> isFocused() async => true;

  @override
  Future<void> focus() async {}

  @override
  Future<void> showQuick() async {}

  @override
  Future<void> showQuickChannel() async {}

  @override
  Future<void> hideQuick() async {}

  @override
  Future<void> showFull() async {}

  @override
  Future<void> hide() => hideQuick();

  @override
  Future<void> setCloseHandler(WindowCloseHandler? handler) async {}

  @override
  Future<void> destroy() async {}

  @override
  void dispose() {}

  @override
  void addFocusListener(WindowFocusListener listener) {
    _focusListeners.add(listener);
  }

  @override
  void removeFocusListener(WindowFocusListener listener) {
    _focusListeners.remove(listener);
  }
}

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}
