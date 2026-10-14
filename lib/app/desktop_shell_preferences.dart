import '../core/preferences/profiled_preferences.dart';

abstract interface class DesktopShellPreferences {
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
  Future<double?> getDouble(String key);
  Future<void> setDouble(String key, double value);
}

class SharedPreferencesDesktopShellPreferences
    implements DesktopShellPreferences {
  SharedPreferencesDesktopShellPreferences(this._preferences);

  final ProfiledPreferences _preferences;

  @override
  Future<bool?> getBool(String key) => _preferences.getBool(key);

  @override
  Future<void> setBool(String key, bool value) async {
    await _preferences.setBool(key, value);
  }

  @override
  Future<double?> getDouble(String key) => _preferences.getDouble(key);

  @override
  Future<void> setDouble(String key, double value) async {
    await _preferences.setDouble(key, value);
  }
}

abstract final class DesktopSidebarDimensions {
  static const defaultExpandedWidth = 216.0;
  static const minimumExpandedWidth = 180.0;
  static const maximumExpandedWidth = 360.0;
  static const collapsedWidth = 56.0;

  static double clampExpandedWidth(double width) =>
      width.clamp(minimumExpandedWidth, maximumExpandedWidth);
}

class DesktopShellPreferencesRepository {
  DesktopShellPreferencesRepository(this._preferences);

  static const sidebarCollapsedKey = 'desktop_sidebar_collapsed';
  static const sidebarExpandedWidthKey = 'desktop_sidebar_expanded_width';
  final DesktopShellPreferences _preferences;

  Future<bool> loadSidebarCollapsed() async {
    return await _preferences.getBool(sidebarCollapsedKey) ?? false;
  }

  Future<void> saveSidebarCollapsed(bool value) =>
      _preferences.setBool(sidebarCollapsedKey, value);

  Future<double> loadSidebarExpandedWidth() async {
    final saved = await _preferences.getDouble(sidebarExpandedWidthKey);
    if (saved == null || !saved.isFinite) {
      return DesktopSidebarDimensions.defaultExpandedWidth;
    }
    return DesktopSidebarDimensions.clampExpandedWidth(saved);
  }

  Future<void> saveSidebarExpandedWidth(double value) => _preferences.setDouble(
    sidebarExpandedWidthKey,
    DesktopSidebarDimensions.clampExpandedWidth(value),
  );
}
