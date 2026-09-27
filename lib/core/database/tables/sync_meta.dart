import 'package:drift/drift.dart';

/// Durable key/value store for future sync metadata (e.g. a last-pulled
/// change sequence cursor). No sync algorithm uses it yet — it exists only
/// to establish a migration-safe schema boundary.
@DataClassName('SyncMetaEntry')
class SyncMeta extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
