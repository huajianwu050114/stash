import 'package:shared_preferences/shared_preferences.dart';

abstract interface class DesktopShellPreferences {
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
}

class SharedPreferencesDesktopShellPreferences
    implements DesktopShellPreferences {
  SharedPreferencesDesktopShellPreferences([
    SharedPreferencesAsync? preferences,
  ]) : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<bool?> getBool(String key) => _preferences.getBool(key);

  @override
  Future<void> setBool(String key, bool value) async {
    await _preferences.setBool(key, value);
  }
}

class DesktopShellPreferencesRepository {
  DesktopShellPreferencesRepository(this._preferences);

  static const sidebarCollapsedKey = 'desktop_sidebar_collapsed';
  final DesktopShellPreferences _preferences;

  Future<bool> loadSidebarCollapsed() async {
    return await _preferences.getBool(sidebarCollapsedKey) ?? false;
  }

  Future<void> saveSidebarCollapsed(bool value) =>
      _preferences.setBool(sidebarCollapsedKey, value);
}
