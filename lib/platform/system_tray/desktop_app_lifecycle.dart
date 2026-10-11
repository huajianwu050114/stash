import '../desktop_window/desktop_window_service.dart';
import '../global_hotkey/global_hotkey_service.dart';
import 'desktop_tray_service.dart';

class DesktopAppLifecycle {
  factory DesktopAppLifecycle({
    required DesktopWindowService window,
    required DesktopTrayService tray,
    required GlobalHotkeyService hotkeys,
    required Future<void> Function() onOpenFull,
    required Future<void> Function() onOpenQuick,
    required Future<void> Function() closeDatabase,
    void Function()? disposeControllers,
  }) => DesktopAppLifecycle._(
    window,
    tray,
    hotkeys,
    onOpenFull,
    onOpenQuick,
    closeDatabase,
    disposeControllers,
  );

  DesktopAppLifecycle._(
    this._window,
    this._tray,
    this._hotkeys,
    this._onOpenFull,
    this._onOpenQuick,
    this._closeDatabase,
    this._disposeControllers,
  );

  final DesktopWindowService _window;
  final DesktopTrayService _tray;
  final GlobalHotkeyService _hotkeys;
  final Future<void> Function() _onOpenFull;
  final Future<void> Function() _onOpenQuick;
  final Future<void> Function() _closeDatabase;
  final void Function()? _disposeControllers;

  bool _exiting = false;

  Future<void> initialize() async {
    await _tray.initialize(
      onOpenFull: _onOpenFull,
      onOpenQuick: _onOpenQuick,
      onExit: exit,
    );
    await _window.setCloseHandler(_window.hide);
  }

  Future<void> exit() async {
    if (_exiting) return;
    _exiting = true;
    await _window.setCloseHandler(null);
    await _hotkeys.shutdown();
    _disposeControllers?.call();
    await _tray.dispose();
    await _closeDatabase();
    await _window.destroy();
  }
}
