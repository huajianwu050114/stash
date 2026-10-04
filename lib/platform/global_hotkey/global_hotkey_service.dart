import '../../features/quick_stash/domain/quick_stash_settings.dart';

abstract interface class GlobalHotkeyService {
  bool get isSupported;

  Future<void> initialize();

  Future<void> register(QuickStashShortcut shortcut, void Function() onPressed);

  Future<void> unregister(QuickStashShortcut shortcut);
}

class NoopGlobalHotkeyService implements GlobalHotkeyService {
  const NoopGlobalHotkeyService();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {}

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {}
}
