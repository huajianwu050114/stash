import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/desktop_shell_preferences.dart';

void main() {
  test('sidebar defaults expanded with the standard width', () async {
    final preferences = _MemoryDesktopShellPreferences();
    final repository = DesktopShellPreferencesRepository(preferences);

    expect(await repository.loadSidebarCollapsed(), isFalse);
    expect(
      await repository.loadSidebarExpandedWidth(),
      DesktopSidebarDimensions.defaultExpandedWidth,
    );
  });

  test('sidebar persists collapse and expanded width independently', () async {
    final preferences = _MemoryDesktopShellPreferences();
    final repository = DesktopShellPreferencesRepository(preferences);

    await repository.saveSidebarCollapsed(true);
    await repository.saveSidebarExpandedWidth(304);
    expect(await repository.loadSidebarCollapsed(), isTrue);
    expect(await repository.loadSidebarExpandedWidth(), 304);
  });

  test('sidebar clamps saved and restored widths', () async {
    final preferences = _MemoryDesktopShellPreferences();
    final repository = DesktopShellPreferencesRepository(preferences);

    await repository.saveSidebarExpandedWidth(90);
    expect(
      await repository.loadSidebarExpandedWidth(),
      DesktopSidebarDimensions.minimumExpandedWidth,
    );
    preferences.values[DesktopShellPreferencesRepository
            .sidebarExpandedWidthKey] =
        900.0;
    expect(
      await repository.loadSidebarExpandedWidth(),
      DesktopSidebarDimensions.maximumExpandedWidth,
    );
    preferences.values[DesktopShellPreferencesRepository
            .sidebarExpandedWidthKey] =
        double.nan;
    expect(
      await repository.loadSidebarExpandedWidth(),
      DesktopSidebarDimensions.defaultExpandedWidth,
    );
  });
}

class _MemoryDesktopShellPreferences implements DesktopShellPreferences {
  final Map<String, Object> values = {};

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
