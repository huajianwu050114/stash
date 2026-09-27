import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/providers.dart';

import 'test_database.dart';

void main() {
  testWidgets('app shell renders against a working in-memory database', (
    tester,
  ) async {
    final db = createInMemoryDatabase();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const StashApp(),
      ),
    );
    // Bounded pumps instead of pumpAndSettle: the widget keeps a live
    // Drift-backed stream open for its whole lifetime.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Stash'), findsOneWidget);
    expect(find.text('Local foundation ready'), findsOneWidget);
    expect(find.text('0 active items'), findsOneWidget);

    // Unmount the tree inside the test body, fire drift's zero-duration
    // teardown timer with a zero-duration pump, then close the database.
    // (Closing before the timer fires deadlocks in fake async, and leaving
    // it pending trips the test binding's pending-timer check.)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await db.close();
  });
}
