import '../../../core/preferences/profiled_preferences.dart';

class LastBackupStatus {
  const LastBackupStatus({required this.path, required this.createdAt});

  final String path;
  final DateTime createdAt;
}

class BackupPreferences {
  const BackupPreferences(this._preferences);

  static const _lastBackupPath = 'backup.last_successful_path';
  static const _lastBackupTime = 'backup.last_successful_time_utc';
  static const _lastFolder = 'backup.last_folder';

  final ProfiledPreferences _preferences;

  Future<LastBackupStatus?> loadLastBackup() async {
    final backupPath = await _preferences.getString(_lastBackupPath);
    final timestamp = await _preferences.getString(_lastBackupTime);
    if (backupPath == null || timestamp == null) return null;
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null) return null;
    return LastBackupStatus(path: backupPath, createdAt: parsed.toUtc());
  }

  Future<void> saveSuccessfulBackup({
    required String path,
    required DateTime createdAt,
  }) async {
    await _preferences.setString(_lastBackupPath, path);
    await _preferences.setString(
      _lastBackupTime,
      createdAt.toUtc().toIso8601String(),
    );
  }

  Future<String?> loadLastFolder() => _preferences.getString(_lastFolder);

  Future<void> saveLastFolder(String path) =>
      _preferences.setString(_lastFolder, path);
}
