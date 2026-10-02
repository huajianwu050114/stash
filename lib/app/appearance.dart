import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class AppearancePreferences {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class SharedPreferencesAppearancePreferences implements AppearancePreferences {
  SharedPreferencesAppearancePreferences([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _preferences.setString(key, value);
  }
}

class AppearanceRepository {
  AppearanceRepository(this._preferences);

  static const preferenceKey = 'appearance_mode';
  final AppearancePreferences _preferences;

  Future<ThemeMode> load() async {
    return switch (await _preferences.getString(preferenceKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> save(ThemeMode mode) =>
      _preferences.setString(preferenceKey, mode.name);
}
