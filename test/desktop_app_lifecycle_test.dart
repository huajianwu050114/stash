import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';
import 'package:stash/platform/desktop_window/desktop_window_service.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';
import 'package:stash/platform/system_tray/desktop_app_lifecycle.dart';
import 'package:stash/platform/system_tray/desktop_tray_service.dart';

void main() {
  test('tray actions open full and Quick surfaces and close hides', () async {
    final log = <String>[];
    final window = _FakeWindow(log);
    final tray = _FakeTray(log);
    final lifecycle = DesktopAppLifecycle(
      window: window,
      tray: tray,
      hotkeys: _FakeHotkeys(log),
      onOpenFull: window.showFull,
      onOpenQuick: window.showQuick,
      closeDatabase: () async => log.add('database.close'),
      disposeServices: () async => log.add('sync.dispose'),
    );

    await lifecycle.initialize();
    await tray.openFull!();
    await tray.openQuick!();
    await window.closeHandler!();

    expect(log, [
      'tray.initialize',
      'window.closeHandler.set',
      'window.showFull',
      'window.showQuick',
      'window.hide',
    ]);
    expect(log, isNot(contains('window.destroy')));
    expect(log, isNot(contains('sync.dispose')));
  });

  test('explicit Exit releases resources in order and only once', () async {
    final log = <String>[];
    final window = _FakeWindow(log);
    final tray = _FakeTray(log);
    final lifecycle = DesktopAppLifecycle(
      window: window,
      tray: tray,
      hotkeys: _FakeHotkeys(log),
      onOpenFull: window.showFull,
      onOpenQuick: window.showQuick,
      closeDatabase: () async => log.add('database.close'),
      disposeControllers: () => log.add('controllers.dispose'),
      disposeServices: () async => log.add('sync.dispose'),
    );
    await lifecycle.initialize();
    log.clear();

    await tray.exit!();
    await lifecycle.exit();

    expect(log, [
      'window.closeHandler.clear',
      'hotkeys.shutdown',
      'controllers.dispose',
      'sync.dispose',
      'tray.dispose',
      'database.close',
      'window.destroy',
    ]);
  });
}

class _FakeTray implements DesktopTrayService {
  _FakeTray(this.log);

  final List<String> log;
  Future<void> Function()? openFull;
  Future<void> Function()? openQuick;
  Future<void> Function()? exit;

  @override
  Future<void> initialize({
    required Future<void> Function() onOpenFull,
    required Future<void> Function() onOpenQuick,
    required Future<void> Function() onExit,
  }) async {
    log.add('tray.initialize');
    openFull = onOpenFull;
    openQuick = onOpenQuick;
    exit = onExit;
  }

  @override
  Future<void> dispose() async {
    log.add('tray.dispose');
  }
}

class _FakeWindow implements DesktopWindowService {
  _FakeWindow(this.log);

  final List<String> log;
  WindowCloseHandler? closeHandler;

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
  Future<void> showQuick() async => log.add('window.showQuick');

  @override
  Future<void> showQuickChannel() async => log.add('window.showQuickChannel');

  @override
  Future<void> hideQuick() => hide();

  @override
  Future<void> showFull() async => log.add('window.showFull');

  @override
  Future<void> hide() async => log.add('window.hide');

  @override
  Future<void> setCloseHandler(WindowCloseHandler? handler) async {
    closeHandler = handler;
    log.add(
      handler == null ? 'window.closeHandler.clear' : 'window.closeHandler.set',
    );
  }

  @override
  Future<void> destroy() async => log.add('window.destroy');

  @override
  void addFocusListener(WindowFocusListener listener) {}

  @override
  void removeFocusListener(WindowFocusListener listener) {}

  @override
  void dispose() {}
}

class _FakeHotkeys implements GlobalHotkeyService {
  _FakeHotkeys(this.log);

  final List<String> log;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {}

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {}

  @override
  Future<void> shutdown() async => log.add('hotkeys.shutdown');
}
