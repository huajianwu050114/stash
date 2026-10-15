import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/providers.dart';

import 'test_database.dart';

void main() {
  test('theme keeps neutral surfaces and green as a restrained accent', () {
    final dark = createStashTheme(Brightness.dark).colorScheme;
    expect(dark.surface, const Color(0xFF151617));
    expect(dark.surfaceContainerLow, const Color(0xFF1B1C1E));
    expect(dark.surfaceContainer, const Color(0xFF202225));
    expect(dark.surfaceContainerHigh, const Color(0xFF27292C));
    expect(dark.surfaceContainerHighest, const Color(0xFF303236));
    expect(dark.outlineVariant, const Color(0xFF45484C));
    expect(dark.primary, const Color(0xFF86B394));
    expect(dark.secondaryContainer, const Color(0xFF2B3730));

    final light = createStashTheme(Brightness.light).colorScheme;
    expect(light.surface, const Color(0xFFFAFBF8));
    expect(light.surfaceContainerLow, const Color(0xFFF5F6F3));
    expect(light.surfaceContainerHighest, const Color(0xFFE3E5E1));
    expect(light.outlineVariant, const Color(0xFFC4C8C3));
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
    await tester.tap(find.byKey(const Key('new-item-button')));
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
