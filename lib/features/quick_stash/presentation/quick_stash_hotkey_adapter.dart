import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../domain/quick_stash_settings.dart';

HotKey quickStashShortcutToHotKey(QuickStashShortcut shortcut) {
  return HotKey(
    key: shortcut.physicalKey ?? PhysicalKeyboardKey.space,
    modifiers: [
      if (shortcut.modifiers.contains(QuickShortcutModifier.control))
        HotKeyModifier.control,
      if (shortcut.modifiers.contains(QuickShortcutModifier.shift))
        HotKeyModifier.shift,
      if (shortcut.modifiers.contains(QuickShortcutModifier.alt))
        HotKeyModifier.alt,
      if (shortcut.modifiers.contains(QuickShortcutModifier.meta))
        HotKeyModifier.meta,
    ],
  );
}

QuickStashShortcut quickStashShortcutFromHotKey(HotKey hotKey) {
  final logicalLabel = hotKey.logicalKey.keyLabel.trim();
  return QuickStashShortcut(
    keyId: hotKey.physicalKey.usbHidUsage,
    keyLabel: logicalLabel.isNotEmpty
        ? logicalLabel
        : hotKey.physicalKey.debugName ?? 'Key',
    modifiers: (hotKey.modifiers ?? const <HotKeyModifier>[])
        .map(_quickModifier)
        .nonNulls
        .toSet(),
  );
}

QuickShortcutModifier? _quickModifier(HotKeyModifier modifier) {
  return switch (modifier) {
    HotKeyModifier.control => QuickShortcutModifier.control,
    HotKeyModifier.shift => QuickShortcutModifier.shift,
    HotKeyModifier.alt => QuickShortcutModifier.alt,
    HotKeyModifier.meta => QuickShortcutModifier.meta,
    HotKeyModifier.capsLock || HotKeyModifier.fn => null,
  };
}
