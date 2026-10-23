import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../storage/app_storage_paths.dart';

import 'tables/attachments.dart';
import 'tables/items.dart';
import 'tables/channels.dart';
import 'tables/sync_meta.dart';
import 'tables/sync_outbox.dart';

part 'app_database.g.dart';

/// The on-device SQLite database.
///
/// The database file is a real working copy of the user's data — never a
/// cache — and every operation is fully local. Schema changes must go through
/// stepwise, additive `MigrationStrategy` steps (see [migration]); the
/// database is never recreated or dropped on upgrade.
@DriftDatabase(tables: [Items, Channels, Attachments, SyncOutbox, SyncMeta])
class AppDatabase extends _$AppDatabase {
  static const currentSchemaVersion = 4;

  /// Opens the real on-device database using the best native SQLite backend
  /// available on the current platform (see `package:drift_flutter`).
  AppDatabase.open({required AppStoragePaths storage})
    : super(
        driftDatabase(
          name: 'stash',
          native: DriftNativeOptions(
            databasePath: () async => storage.databaseFile.path,
            tempDirectoryPath: () async => storage.root.path,
          ),
        ),
      );

  /// Direct-executor constructor for tests (e.g. `NativeDatabase.memory()`).
  AppDatabase(super.executor);

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(channels);
        await m.addColumn(items, items.channelId);
      }
      if (from < 3) {
        await m.addColumn(items, items.documentJson);
        await m.createTable(attachments);
      }
      if (from < 4) {
        // Older migrations create missing tables from the current definition,
        // so only tables that already existed at the source version need the
        // additive revision column.
        if (from >= 2) {
          await m.addColumn(channels, channels.serverRevision);
        }
        if (from >= 3) {
          await m.addColumn(attachments, attachments.serverRevision);
        }
        await customStatement(
          'ALTER TABLE sync_outbox RENAME TO sync_outbox_v3',
        );
        await m.createTable(syncOutbox);
        await customStatement('''
          INSERT INTO sync_outbox (
            entity_type,
            entity_id,
            mutation_id,
            base_revision,
            op,
            created_at,
            retry_count
          )
          SELECT
            'item',
            item_id,
            mutation_id,
            base_revision,
            op,
            created_at,
            retry_count
          FROM sync_outbox_v3
        ''');
        await customStatement('DROP TABLE sync_outbox_v3');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
