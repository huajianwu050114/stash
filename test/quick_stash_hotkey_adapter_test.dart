import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:stash/features/quick_stash/presentation/quick_stash_hotkey_adapter.dart';

void main() {
  group('Quick Stash hotkey adapter', () {
    final examples =
        <
          ({
            PhysicalKeyboardKey key,
            List<HotKeyModifier> modifiers,
            String label,
          })
        >[
          (
            key: PhysicalKeyboardKey.keyI,
            modifiers: [HotKeyModifier.control],
            label: 'Ctrl + I',
          ),
          (
            key: PhysicalKeyboardKey.keyI,
            modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
            label: 'Ctrl + Shift + I',
          ),
          (
            key: PhysicalKeyboardKey.keyI,
            modifiers: [HotKeyModifier.alt],
            label: 'Alt + I',
          ),
          (key: PhysicalKeyboardKey.f8, modifiers: [], label: 'F8'),
          (key: PhysicalKeyboardKey.f9, modifiers: [], label: 'F9'),
          (
            key: PhysicalKeyboardKey.backquote,
            modifiers: [HotKeyModifier.control],
            label: 'Ctrl + `',
          ),
        ];

    for (final example in examples) {
      test('records ${example.label}', () {
        final shortcut = quickStashShortcutFromHotKey(
          HotKey(key: example.key, modifiers: example.modifiers),
        );

        expect(shortcut.displayLabel, example.label);
        expect(shortcut.isValid, isTrue);
        final roundTrip = quickStashShortcutToHotKey(shortcut);
        expect(roundTrip.physicalKey, example.key);
        expect(roundTrip.modifiers, example.modifiers);
      });
    }

    test('ignores unsupported lock-state modifiers', () {
      final shortcut = quickStashShortcutFromHotKey(
        HotKey(
          key: PhysicalKeyboardKey.keyI,
          modifiers: [HotKeyModifier.capsLock, HotKeyModifier.fn],
        ),
      );

      expect(shortcut.modifiers, isEmpty);
      expect(shortcut.isValid, isFalse);
    });
  });
}
