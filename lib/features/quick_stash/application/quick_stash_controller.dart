import 'package:flutter/foundation.dart';

import '../../../platform/desktop_window/desktop_window_service.dart';

enum StashSurface { full, quick }

class QuickStashController extends ChangeNotifier {
  QuickStashController(this._window);

  final DesktopWindowService _window;
  StashSurface _surface = StashSurface.full;
  bool _transitioning = false;

  StashSurface get surface => _surface;
  bool get isSupported => _window.isSupported;

  Future<void> toggleQuick() async {
    if (!_window.isSupported || _transitioning) return;
    _transitioning = true;
    try {
      if (_surface == StashSurface.quick && await _window.isVisible()) {
        await _window.hideQuick();
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
}
