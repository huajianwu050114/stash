import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app_profile.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/features/quick_stash/presentation/quick_stash_settings_screen.dart';

import 'test_database.dart';

void main() {
  testWidgets('Settings exposes restrained content-only backup controls', (
    tester,
  ) async {
    final database = createInMemoryDatabase();
    addTearDown(database.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProfileProvider.overrideWithValue(AppProfile.dev),
          databaseProvider.overrideWithValue(database),
        ],
        child: const MaterialApp(home: QuickStashSettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Backup & Restore'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Backup & Restore'), findsOneWidget);
    expect(find.byKey(const Key('create-backup')), findsOneWidget);
    expect(find.byKey(const Key('restore-backup')), findsOneWidget);
    expect(find.byKey(const Key('open-backup-folder')), findsOneWidget);
    expect(find.text('Last successful backup: Never'), findsOneWidget);
    expect(
      find.textContaining('Device settings and shortcuts are not included.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  });
}
