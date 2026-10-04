import 'package:flutter/foundation.dart';

import '../../../platform/global_hotkey/global_hotkey_service.dart';
import '../data/quick_stash_settings_repository.dart';
import '../domain/quick_stash_settings.dart';

class QuickStashSettingsController extends ChangeNotifier {
  factory QuickStashSettingsController({
    required QuickStashSettingsRepository repository,
    required GlobalHotkeyService hotkeys,
    required void Function() onGlobalShortcut,
  }) => QuickStashSettingsController._(repository, hotkeys, onGlobalShortcut);

  QuickStashSettingsController._(
    this._repository,
    this._hotkeys,
    this._onGlobalShortcut,
  );

  final QuickStashSettingsRepository _repository;
  final GlobalHotkeyService _hotkeys;
  final void Function() _onGlobalShortcut;

  QuickStashSettings _settings = const QuickStashSettings();
  bool _isLoading = true;
  String? _shortcutError;

  QuickStashSettings get settings => _settings;
  bool get isLoading => _isLoading;
  bool get shortcutSupported => _hotkeys.isSupported;
  String? get shortcutError => _shortcutError;

  Future<void> initialize() async {
    _settings = await _repository.load();
    if (_hotkeys.isSupported) {
      try {
        await _hotkeys.register(_settings.globalShortcut, _onGlobalShortcut);
      } catch (_) {
        _shortcutError = 'The saved shortcut is unavailable.';
      }
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> changeShortcut(QuickStashShortcut shortcut) async {
    if (!shortcut.isValid || shortcut.physicalKey == null) {
      _shortcutError = 'Use a modifier combination or a function key.';
      notifyListeners();
      return false;
    }
    final previous = _settings.globalShortcut;
    if (shortcut == previous) {
      _shortcutError = null;
      notifyListeners();
      return true;
    }
    try {
      if (_hotkeys.isSupported) {
        await _hotkeys.register(shortcut, _onGlobalShortcut);
      }
    } catch (_) {
      _shortcutError = 'This shortcut is unavailable.';
      notifyListeners();
      return false;
    }
    try {
      await _repository.saveShortcut(shortcut);
    } catch (_) {
      if (_hotkeys.isSupported) await _hotkeys.unregister(shortcut);
      _shortcutError = 'The shortcut could not be saved.';
      notifyListeners();
      return false;
    }
    if (_hotkeys.isSupported) await _hotkeys.unregister(previous);
    _settings = _settings.copyWith(globalShortcut: shortcut);
    _shortcutError = null;
    notifyListeners();
    return true;
  }

  Future<void> changeSubmitMode(QuickCaptureSubmitMode mode) async {
    if (mode == _settings.submitMode) return;
    await _repository.saveSubmitMode(mode);
    _settings = _settings.copyWith(submitMode: mode);
    notifyListeners();
  }

  void clearShortcutError() {
    if (_shortcutError == null) return;
    _shortcutError = null;
    notifyListeners();
  }
}
