import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/desktop_shell_preferences.dart';

void main() {
  test('sidebar defaults expanded and persists collapsed preference', () async {
    final preferences = _MemoryDesktopShellPreferences();
    final repository = DesktopShellPreferencesRepository(preferences);

    expect(await repository.loadSidebarCollapsed(), isFalse);
    await repository.saveSidebarCollapsed(true);
    expect(await repository.loadSidebarCollapsed(), isTrue);
  });
}

class _MemoryDesktopShellPreferences implements DesktopShellPreferences {
  final Map<String, bool> values = {};

  @override
  Future<bool?> getBool(String key) async => values[key];

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }
}
