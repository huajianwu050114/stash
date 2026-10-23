import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/sync_models.dart';

/// Durable queue shared by every syncable entity repository.
///
/// [enqueue] intentionally does not open a transaction. Entity repositories
/// call it from their existing SQLite transaction so the entity change and
/// its mutation are committed atomically.
class SyncOutboxRepository {
  SyncOutboxRepository(this._db, {Uuid? uuid, DateTime Function()? clock})
    : _uuid = uuid ?? Uuid(),
      _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _clock;

  Future<SyncMutation> enqueue({
    required SyncEntityType entityType,
    required String entityId,
    required int baseRevision,
    required SyncOperation operation,
  }) async {
    if (entityId.isEmpty) throw ArgumentError.value(entityId, 'entityId');
    if (baseRevision < 0) {
      throw ArgumentError.value(baseRevision, 'baseRevision');
    }
    final existing = await _entry(entityType, entityId);
    final mutationId = _uuid.v4();
    final createdAt = _clock();
    if (existing == null) {
      await _db
          .into(_db.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              entityType: entityType.wireValue,
              entityId: entityId,
              mutationId: mutationId,
              baseRevision: baseRevision,
              op: operation.wireValue,
              createdAt: createdAt,
            ),
          );
    } else {
      await (_db.update(_db.syncOutbox)..where(
            (row) =>
                row.entityType.equals(entityType.wireValue) &
                row.entityId.equals(entityId),
          ))
          .write(
            SyncOutboxCompanion(
              mutationId: Value(mutationId),
              op: Value(operation.wireValue),
              createdAt: Value(createdAt),
              retryCount: const Value(0),
            ),
          );
    }
    return SyncMutation(
      entity: SyncEntityKey(type: entityType, id: entityId),
      mutationId: mutationId,
      baseRevision: existing?.baseRevision ?? baseRevision,
      operation: operation,
      createdAt: createdAt,
      retryCount: 0,
    );
  }

  Future<List<SyncMutation>> readPending() async {
    final rows = await (_db.select(
      _db.syncOutbox,
    )..orderBy([(row) => OrderingTerm.asc(row.createdAt)])).get();
    return rows.map(_decode).toList(growable: false);
  }

  Future<SyncMutation?> getPending(SyncEntityKey key) async {
    final entry = await _entry(key.type, key.id);
    return entry == null ? null : _decode(entry);
  }

  /// Removes only the exact mutation that was acknowledged. A newer edit for
  /// the same entity therefore cannot be erased by a delayed acknowledgement.
  Future<bool> acknowledge({
    required SyncEntityKey entity,
    required String mutationId,
  }) async {
    final removed =
        await (_db.delete(_db.syncOutbox)..where(
              (row) =>
                  row.entityType.equals(entity.type.wireValue) &
                  row.entityId.equals(entity.id) &
                  row.mutationId.equals(mutationId),
            ))
            .go();
    return removed == 1;
  }

  /// Increments only the exact attempted mutation. Returns false if a newer
  /// local edit already replaced it.
  Future<bool> incrementRetryCount({
    required SyncEntityKey entity,
    required String mutationId,
  }) async {
    final updated = await _db.customUpdate(
      'UPDATE sync_outbox '
      'SET retry_count = retry_count + 1 '
      'WHERE entity_type = ? AND entity_id = ? AND mutation_id = ?',
      variables: [
        Variable(entity.type.wireValue),
        Variable(entity.id),
        Variable(mutationId),
      ],
      updates: {_db.syncOutbox},
    );
    return updated == 1;
  }

  Future<SyncOutboxEntry?> _entry(SyncEntityType entityType, String entityId) =>
      (_db.select(_db.syncOutbox)..where(
            (row) =>
                row.entityType.equals(entityType.wireValue) &
                row.entityId.equals(entityId),
          ))
          .getSingleOrNull();

  static SyncMutation _decode(SyncOutboxEntry entry) => SyncMutation(
    entity: SyncEntityKey(
      type: SyncEntityType.fromWireValue(entry.entityType),
      id: entry.entityId,
    ),
    mutationId: entry.mutationId,
    baseRevision: entry.baseRevision,
    operation: SyncOperation.fromWireValue(entry.op),
    createdAt: entry.createdAt,
    retryCount: entry.retryCount,
  );
}
