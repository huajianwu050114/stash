import 'dart:async';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_window_service.dart';

class WindowManagerDesktopWindowService
    with WindowListener
    implements DesktopWindowService {
  factory WindowManagerDesktopWindowService({required String title}) =>
      WindowManagerDesktopWindowService._(title);

  WindowManagerDesktopWindowService._(this._title);

  static const Size fullSize = Size(960, 660);
  static const Size quickSize = Size(410, 600);
  static const Size quickChannelSize = Size(410, 500);

  final String _title;

  final Set<WindowFocusListener> _focusListeners = {};
  bool _listening = false;
  WindowCloseHandler? _closeHandler;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    if (!_listening) {
      windowManager.addListener(this);
      _listening = true;
    }
    unawaited(
      windowManager.waitUntilReadyToShow(
        WindowOptions(
          size: fullSize,
          center: true,
          title: _title,
          titleBarStyle: TitleBarStyle.normal,
          skipTaskbar: false,
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }

  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<bool> isFocused() => windowManager.isFocused();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  void addFocusListener(WindowFocusListener listener) {
    _focusListeners.add(listener);
  }

  @override
  void removeFocusListener(WindowFocusListener listener) {
    _focusListeners.remove(listener);
  }

  @override
  void onWindowFocus() => _notifyFocusListeners(true);

  @override
  void onWindowBlur() => _notifyFocusListeners(false);

  @override
  Future<void> showQuick() => _showCompact(quickSize);

  @override
  Future<void> showQuickChannel() => _showCompact(quickChannelSize);

  Future<void> _showCompact(Size desiredSize) async {
    final display = await _activeDisplay();
    final origin = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    final bounds = compactBoundsFor(
      visibleOrigin: origin,
      visibleSize: size,
      desiredSize: desiredSize,
    );
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setBounds(bounds);
    await windowManager.show();
    await windowManager.focus();
  }

  static Rect compactBoundsFor({
    required Offset visibleOrigin,
    required Size visibleSize,
    required Size desiredSize,
  }) {
    final width = desiredSize.width.clamp(320, visibleSize.width).toDouble();
    final height = desiredSize.height.clamp(360, visibleSize.height).toDouble();
    return Rect.fromLTWH(
      visibleOrigin.dx + visibleSize.width - width,
      visibleOrigin.dy + (visibleSize.height - height) / 2,
      width,
      height,
    );
  }

  @override
  Future<void> hideQuick() => windowManager.hide();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> showFull() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setSize(fullSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> setCloseHandler(WindowCloseHandler? handler) async {
    _closeHandler = handler;
    await windowManager.setPreventClose(handler != null);
  }

  @override
  void onWindowClose() {
    final handler = _closeHandler;
    if (handler != null) unawaited(handler());
  }

  @override
  Future<void> destroy() async {
    _closeHandler = null;
    await windowManager.setPreventClose(false);
    dispose();
    await windowManager.destroy();
  }

  @override
  void dispose() {
    if (_listening) {
      windowManager.removeListener(this);
      _listening = false;
    }
    _focusListeners.clear();
  }

  Future<Display> _activeDisplay() async {
    final cursor = await screenRetriever.getCursorScreenPoint();
    final displays = await screenRetriever.getAllDisplays();
    for (final display in displays) {
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      if ((origin & size).contains(cursor)) return display;
    }
    return screenRetriever.getPrimaryDisplay();
  }

  void _notifyFocusListeners(bool isFocused) {
    for (final listener in Set<WindowFocusListener>.of(_focusListeners)) {
      listener(isFocused);
    }
  }
}
