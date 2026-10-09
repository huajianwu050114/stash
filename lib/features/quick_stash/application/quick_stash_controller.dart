import 'package:flutter/foundation.dart';

import '../../../platform/desktop_window/desktop_window_service.dart';

enum StashSurface { full, quick }

class QuickStashController extends ChangeNotifier {
  QuickStashController(this._window) {
    _window.addFocusListener(_handleWindowFocusChanged);
  }

  final DesktopWindowService _window;
  StashSurface _surface = StashSurface.full;
  bool _transitioning = false;
  int _activationGeneration = 0;

  StashSurface get surface => _surface;
  bool get isSupported => _window.isSupported;
  int get activationGeneration => _activationGeneration;

  Future<void> toggleQuick() async {
    if (!_window.isSupported || _transitioning) return;
    _transitioning = true;
    try {
      if (_surface == StashSurface.quick && await _window.isVisible()) {
        if (await _window.isFocused()) {
          await _window.hideQuick();
        } else {
          await _window.focus();
        }
      } else {
        await _setQuickAndShow();
      }
    } finally {
      _transitioning = false;
    }
  }

  Future<void> showQuick() async {
    if (!_window.isSupported || _transitioning) return;
    _transitioning = true;
    try {
      await _setQuickAndShow();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _setQuickAndShow() async {
    if (_surface != StashSurface.quick) {
      _surface = StashSurface.quick;
      notifyListeners();
    }
    await _window.showQuick();
  }

  Future<void> hideQuick() async {
    if (_window.isSupported) await _window.hideQuick();
  }

  Future<void> showFull() async {
    if (_surface != StashSurface.full) {
      _surface = StashSurface.full;
      notifyListeners();
    }
    if (_window.isSupported) await _window.showFull();
  }

  void _handleWindowFocusChanged(bool isFocused) {
    if (!isFocused || _surface != StashSurface.quick) return;
    _activationGeneration++;
    notifyListeners();
  }

  @override
  void dispose() {
    _window.removeFocusListener(_handleWindowFocusChanged);
    super.dispose();
  }
}
