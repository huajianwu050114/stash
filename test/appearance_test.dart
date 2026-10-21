import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/providers.dart';

import 'test_database.dart';

void main() {
  test('theme uses a neutral palette and explicit Windows typography', () {
    final darkTheme = createStashTheme(Brightness.dark);
    final dark = darkTheme.colorScheme;
    expect(dark.surface, const Color(0xFF151617));
    expect(dark.surfaceContainerLow, const Color(0xFF191A1C));
    expect(dark.surfaceContainer, const Color(0xFF1E2022));
    expect(dark.surfaceContainerHigh, const Color(0xFF25272A));
    expect(dark.surfaceContainerHighest, const Color(0xFF2D3033));
    expect(dark.outlineVariant, const Color(0xFF414448));
    expect(dark.primary, const Color(0xFFE6E8EA));
    expect(dark.primaryContainer, const Color(0xFF34373A));
    expect(dark.secondaryContainer, const Color(0xFF303336));
    expect(dark.error.r, greaterThan(dark.error.g));
    expect(darkTheme.textTheme.bodyMedium?.fontFamily, 'Segoe UI Variable');
    expect(
      darkTheme.textTheme.bodyMedium?.fontFamilyFallback,
      containsAll(['Segoe UI', 'Microsoft YaHei UI', 'Microsoft YaHei']),
    );
    expect(darkTheme.textTheme.titleLarge?.fontWeight, FontWeight.w600);
    expect(darkTheme.textTheme.titleSmall?.fontWeight, FontWeight.w500);
    expect(darkTheme.textTheme.bodyMedium?.fontWeight, FontWeight.w400);

    final light = createStashTheme(Brightness.light).colorScheme;
    expect(light.surface, const Color(0xFFFAFAF9));
    expect(light.primary, const Color(0xFF24272A));
    expect(light.surfaceContainerLow, const Color(0xFFF4F4F2));
    expect(light.surfaceContainerHighest, const Color(0xFFE1E3E1));
    expect(light.outlineVariant, const Color(0xFFC5C8CA));
  });

  test('appearance defaults to system and persists explicit choices', () async {
    final preferences = _MemoryAppearancePreferences();
    final repository = AppearanceRepository(preferences);

    expect(await repository.load(), ThemeMode.system);
    await repository.save(ThemeMode.dark);
    expect(await repository.load(), ThemeMode.dark);
    await repository.save(ThemeMode.light);
    expect(await repository.load(), ThemeMode.light);
  });

  testWidgets('saved appearance is restored and menu changes it', (
    tester,
  ) async {
    final db = createInMemoryDatabase();
    final preferences = _MemoryAppearancePreferences()
      ..values[AppearanceRepository.preferenceKey] = 'dark';
    final repository = AppearanceRepository(preferences);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appearanceRepositoryProvider.overrideWithValue(repository),
        ],
        child: const StashApp(),
      ),
    );
    await _pumpUi(tester);

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      Theme.of(tester.element(find.byKey(const Key('empty-home')))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const Key('global-new-button')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const Key('new-item-action')));
    await _pumpUi(tester);
    final editorContext = tester.element(
      find.byKey(const Key('content-field')),
    );
    expect(Theme.of(editorContext).brightness, Brightness.dark);
    expect(
      Theme.of(editorContext).scaffoldBackgroundColor,
      isNot(Colors.white),
    );
    await tester.tap(find.byKey(const Key('cancel-editor-button')));
    await _pumpUi(tester);

    await tester.tap(find.byKey(const Key('appearance-menu')));
    await _pumpUi(tester);
    await tester.tap(find.byKey(const Key('appearance-light')));
    await _pumpUi(tester);

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    expect(preferences.values[AppearanceRepository.preferenceKey], 'light');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await db.close();
  });
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
