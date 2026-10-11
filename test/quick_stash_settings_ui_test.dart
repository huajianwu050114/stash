import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/features/quick_stash/application/quick_stash_settings_controller.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';
import 'package:stash/features/quick_stash/presentation/quick_stash_settings_screen.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';

void main() {
  testWidgets('settings records a real key chord and changes submit mode', (
    tester,
  ) async {
    final hotkeys = _FakeHotkeys();
    final settings = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(
        MemoryQuickStashPreferenceStore(),
      ),
      hotkeys: hotkeys,
      onGlobalShortcut: () {},
    );
    await settings.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          quickStashSettingsControllerProvider.overrideWithValue(settings),
          appearanceRepositoryProvider.overrideWithValue(
            AppearanceRepository(_MemoryAppearancePreferences()),
          ),
        ],
        child: const MaterialApp(home: QuickStashSettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Quick Stash Shortcut'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shortcut-recorder')));
    await tester.pump();
    expect(find.text('Press a shortcut'), findsOneWidget);
    expect(find.byKey(const Key('shortcut-recorder-input')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(Duration.zero);

    expect(find.text('Ctrl + I'), findsOneWidget);
    expect(settings.settings.globalShortcut.keyLabel, 'I');
    expect(settings.settings.globalShortcut.modifiers, {
      QuickShortcutModifier.control,
    });
    expect(hotkeys.registered.last.displayLabel, 'Ctrl + I');

    await tester.tap(find.byKey(const Key('submit-mode-control-enter')));
    await tester.pump();
    await tester.pump(Duration.zero);
    expect(settings.settings.submitMode, QuickCaptureSubmitMode.controlEnter);
  });

  testWidgets('Escape cancels shortcut recording without changing settings', (
    tester,
  ) async {
    final hotkeys = _FakeHotkeys();
    final settings = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(
        MemoryQuickStashPreferenceStore(),
      ),
      hotkeys: hotkeys,
      onGlobalShortcut: () {},
    );
    await settings.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          quickStashSettingsControllerProvider.overrideWithValue(settings),
          appearanceRepositoryProvider.overrideWithValue(
            AppearanceRepository(_MemoryAppearancePreferences()),
          ),
        ],
        child: const MaterialApp(home: QuickStashSettingsScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('shortcut-recorder')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byKey(const Key('shortcut-recorder-input')), findsNothing);
    expect(
      settings.settings.globalShortcut,
      QuickStashShortcut.defaultShortcut,
    );
  });
}

class _FakeHotkeys implements GlobalHotkeyService {
  final List<QuickStashShortcut> registered = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {
    registered.add(shortcut);
  }

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {}
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> setString(String key, String value) async {}
}
