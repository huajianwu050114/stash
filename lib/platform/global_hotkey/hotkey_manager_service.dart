import 'package:hotkey_manager/hotkey_manager.dart';

import '../../features/quick_stash/domain/quick_stash_settings.dart';
import 'global_hotkey_service.dart';

class HotkeyManagerService implements GlobalHotkeyService {
  final Map<QuickStashShortcut, HotKey> _registered = {};

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() => hotKeyManager.unregisterAll();

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {
    final key = shortcut.physicalKey;
    if (key == null || !shortcut.isValid) {
      throw ArgumentError.value(shortcut, 'shortcut', 'Invalid shortcut.');
    }
    final hotKey = HotKey(
      key: key,
      modifiers: shortcut.modifiers.map(_modifier).toList(),
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(hotKey, keyDownHandler: (_) => onPressed());
    _registered[shortcut] = hotKey;
  }

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {
    final hotKey = _registered.remove(shortcut);
    if (hotKey != null) await hotKeyManager.unregister(hotKey);
  }

  @override
  Future<void> shutdown() async {
    _registered.clear();
    await hotKeyManager.unregisterAll();
  }

  HotKeyModifier _modifier(QuickShortcutModifier modifier) =>
      switch (modifier) {
        QuickShortcutModifier.control => HotKeyModifier.control,
        QuickShortcutModifier.shift => HotKeyModifier.shift,
        QuickShortcutModifier.alt => HotKeyModifier.alt,
        QuickShortcutModifier.meta => HotKeyModifier.meta,
      };
}
