import 'package:drift/drift.dart';

/// Durable pending mutations awaiting a future sync phase.
///
/// Invariants:
///  - At most one entry per entity (the composite primary key): repeated
///    offline edits coalesce instead of accumulating unbounded rows.
///  - Current payloads live in their entity tables; this table never
///    duplicates them.
///  - [baseRevision] records the server revision against which the pending
///    local changes originally diverged, and is preserved across coalescing.
@DataClassName('SyncOutboxEntry')
class SyncOutbox extends Table {
  TextColumn get entityType => text()();

  TextColumn get entityId => text()();

  /// Refreshed on every local edit so a future sync can tell mutations apart.
  TextColumn get mutationId => text()();

  IntColumn get baseRevision => integer()();

  /// Stable wire value: `upsert` or `delete`.
  TextColumn get op => text()();

  DateTimeColumn get createdAt => dateTime()();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}
