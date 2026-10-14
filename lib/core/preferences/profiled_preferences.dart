import 'package:shared_preferences/shared_preferences.dart';

abstract interface class PreferenceBackend {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
  Future<double?> getDouble(String key);
  Future<void> setDouble(String key, double value);
}

class SharedPreferencesBackend implements PreferenceBackend {
  SharedPreferencesBackend([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await _preferences.setString(key, value);
  }

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

class MemoryPreferenceBackend implements PreferenceBackend {
  final Map<String, Object> values = {};

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async {
    values[key] = value;
  }
}

/// The only production boundary allowed to add an application profile to a
/// device preference key.
class ProfiledPreferences {
  factory ProfiledPreferences({
    required String namespace,
    required PreferenceBackend backend,
  }) => ProfiledPreferences._(namespace, backend);

  ProfiledPreferences._(this._namespace, this._backend);

  final String _namespace;
  final PreferenceBackend _backend;

  String namespacedKey(String key) => '$_namespace.$key';

  Future<String?> getString(String key) =>
      _backend.getString(namespacedKey(key));

  Future<void> setString(String key, String value) =>
      _backend.setString(namespacedKey(key), value);

  Future<bool?> getBool(String key) => _backend.getBool(namespacedKey(key));

  Future<void> setBool(String key, bool value) =>
      _backend.setBool(namespacedKey(key), value);

  Future<double?> getDouble(String key) =>
      _backend.getDouble(namespacedKey(key));

  Future<void> setDouble(String key, double value) =>
      _backend.setDouble(namespacedKey(key), value);
}
