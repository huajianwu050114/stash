import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/quick_stash/application/quick_stash_settings_controller.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';

void main() {
  test(
    'quick stash preferences save and load shortcut and submit mode',
    () async {
      final store = _MemoryStore();
      final repository = QuickStashSettingsRepository(store);
      const shortcut = QuickStashShortcut(keyId: 0x0007003d, keyLabel: 'F4');

      await repository.saveShortcut(shortcut);
      await repository.saveSubmitMode(QuickCaptureSubmitMode.controlEnter);

      final restored = await repository.load();
      expect(restored.globalShortcut, shortcut);
      expect(restored.submitMode, QuickCaptureSubmitMode.controlEnter);
    },
  );

  test('shortcut change registers live and persists after success', () async {
    final store = _MemoryStore();
    final repository = QuickStashSettingsRepository(store);
    final hotkeys = _FakeHotkeys();
    var triggered = 0;
    final controller = QuickStashSettingsController(
      repository: repository,
      hotkeys: hotkeys,
      onGlobalShortcut: () => triggered++,
    );
    await controller.initialize();
    const replacement = QuickStashShortcut(keyId: 0x00070041, keyLabel: 'F8');

    expect(await controller.changeShortcut(replacement), isTrue);
    expect(hotkeys.registered, [
      QuickStashShortcut.defaultShortcut,
      replacement,
    ]);
    expect(hotkeys.unregistered, [QuickStashShortcut.defaultShortcut]);
    expect((await repository.load()).globalShortcut, replacement);
    hotkeys.handlers[replacement]!();
    expect(triggered, 1);
  });

  test(
    'failed registration keeps previous shortcut active and persisted',
    () async {
      final store = _MemoryStore();
      final repository = QuickStashSettingsRepository(store);
      final hotkeys = _FakeHotkeys();
      final controller = QuickStashSettingsController(
        repository: repository,
        hotkeys: hotkeys,
        onGlobalShortcut: () {},
      );
      await controller.initialize();
      const unavailable = QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9');
      hotkeys.failFor = unavailable;

      expect(await controller.changeShortcut(unavailable), isFalse);
      expect(
        controller.settings.globalShortcut,
        QuickStashShortcut.defaultShortcut,
      );
      expect(controller.shortcutError, 'This shortcut is unavailable.');
      expect(hotkeys.unregistered, isEmpty);
      expect(
        (await repository.load()).globalShortcut,
        QuickStashShortcut.defaultShortcut,
      );
    },
  );

  test('ordinary unmodified key is rejected before registration', () async {
    final hotkeys = _FakeHotkeys();
    final controller = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(_MemoryStore()),
      hotkeys: hotkeys,
      onGlobalShortcut: () {},
    );
    await controller.initialize();
    const letter = QuickStashShortcut(keyId: 0x00070004, keyLabel: 'A');

    expect(await controller.changeShortcut(letter), isFalse);
    expect(hotkeys.registered, [QuickStashShortcut.defaultShortcut]);
    expect(
      controller.shortcutError,
      'Use a modifier combination or a function key.',
    );
  });
}

class _MemoryStore implements QuickStashPreferenceStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

class _FakeHotkeys implements GlobalHotkeyService {
  final List<QuickStashShortcut> registered = [];
  final List<QuickStashShortcut> unregistered = [];
  final Map<QuickStashShortcut, void Function()> handlers = {};
  QuickStashShortcut? failFor;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {
    if (shortcut == failFor) throw StateError('unavailable');
    registered.add(shortcut);
    handlers[shortcut] = onPressed;
  }

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {
    unregistered.add(shortcut);
    handlers.remove(shortcut);
  }

  @override
  Future<void> shutdown() async {
    handlers.clear();
  }
}
