import 'dart:convert';

import '../../../core/preferences/profiled_preferences.dart';
import '../domain/quick_stash_settings.dart';

abstract interface class QuickStashPreferenceStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class MemoryQuickStashPreferenceStore implements QuickStashPreferenceStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String value) async {
    _values[key] = value;
  }
}

class SharedPreferencesQuickStashStore implements QuickStashPreferenceStore {
  SharedPreferencesQuickStashStore(this._preferences);

  final ProfiledPreferences _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);
}

class QuickStashSettingsRepository {
  QuickStashSettingsRepository(
    this._store, {
    this.globalShortcutsEnabledByDefault = true,
  });

  static const shortcutKey = 'quick_stash.global_shortcut';
  static const submitModeKey = 'quick_stash.submit_mode';
  static const globalShortcutsEnabledKey =
      'quick_stash.global_shortcuts_enabled';

  final QuickStashPreferenceStore _store;
  final bool globalShortcutsEnabledByDefault;

  Future<QuickStashSettings> load() async {
    var shortcut = QuickStashShortcut.defaultShortcut;
    final shortcutJson = await _store.getString(shortcutKey);
    if (shortcutJson != null) {
      try {
        shortcut = QuickStashShortcut.fromJson(
          jsonDecode(shortcutJson) as Map<String, dynamic>,
        );
        if (!shortcut.isValid || shortcut.physicalKey == null) {
          shortcut = QuickStashShortcut.defaultShortcut;
        }
      } catch (_) {
        shortcut = QuickStashShortcut.defaultShortcut;
      }
    }
    final submitModeName = await _store.getString(submitModeKey);
    final submitMode = QuickCaptureSubmitMode.values.firstWhere(
      (value) => value.name == submitModeName,
      orElse: () => QuickCaptureSubmitMode.enter,
    );
    final enabledValue = await _store.getString(globalShortcutsEnabledKey);
    final globalShortcutsEnabled = switch (enabledValue) {
      'true' => true,
      'false' => false,
      _ => globalShortcutsEnabledByDefault,
    };
    return QuickStashSettings(
      globalShortcut: shortcut,
      submitMode: submitMode,
      globalShortcutsEnabled: globalShortcutsEnabled,
    );
  }

  Future<void> saveShortcut(QuickStashShortcut shortcut) =>
      _store.setString(shortcutKey, jsonEncode(shortcut.toJson()));

  Future<void> saveSubmitMode(QuickCaptureSubmitMode mode) =>
      _store.setString(submitModeKey, mode.name);

  Future<void> saveGlobalShortcutsEnabled(bool enabled) =>
      _store.setString(globalShortcutsEnabledKey, enabled.toString());
}
