import 'package:drift/drift.dart';

/// Durable key/value store for future non-secret sync metadata.
///
/// Intended keys include `pull_cursor`, `device_id`, and
/// `last_successful_sync`. Server credentials, auth tokens, and other secrets
/// must not be stored here. No sync algorithm uses this table in S1.
@DataClassName('SyncMetaEntry')
class SyncMeta extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
