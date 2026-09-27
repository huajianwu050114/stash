import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables/items.dart';
import 'tables/sync_meta.dart';
import 'tables/sync_outbox.dart';

part 'app_database.g.dart';

/// The on-device SQLite database.
///
/// The database file is a real working copy of the user's data — never a
/// cache — and every operation is fully local. Schema changes must go through
/// stepwise, additive `MigrationStrategy` steps (see [migration]); the
/// database is never recreated or dropped on upgrade.
@DriftDatabase(tables: [Items, SyncOutbox, SyncMeta])
class AppDatabase extends _$AppDatabase {
  /// Opens the real on-device database using the best native SQLite backend
  /// available on the current platform (see `package:drift_flutter`).
  AppDatabase.open() : super(driftDatabase(name: 'stash'));

  /// Direct-executor constructor for tests (e.g. `NativeDatabase.memory()`).
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Future versions add stepwise, additive-only steps here, e.g.:
      //   if (from < 2) {
      //     await m.addColumn(items, items.someNewColumn);
      //   }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
