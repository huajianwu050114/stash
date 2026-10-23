import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/sync/data/sync_outbox_repository.dart';
import 'package:stash/features/sync/domain/sync_models.dart';

import 'test_database.dart';

void main() {
  test('wire codecs reject unknown entity types and operations', () {
    expect(
      () => SyncEntityType.fromWireValue('unknown'),
      throwsFormatException,
    );
    expect(() => SyncOperation.fromWireValue('merge'), throwsFormatException);
  });

  test(
    'unknown persisted wire values fail instead of silently decoding',
    () async {
      final db = createInMemoryDatabase();
      addTearDown(db.close);
      final outbox = SyncOutboxRepository(db);
      await db.customStatement(
        'INSERT INTO sync_outbox '
        '(entity_type, entity_id, mutation_id, base_revision, op, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'mystery',
          'id',
          'mutation',
          0,
          'upsert',
          DateTime.utc(2026).toIso8601String(),
        ],
      );

      await expectLater(outbox.readPending(), throwsFormatException);
    },
  );

  test(
    'same UUID for Item and Channel has distinct composite identity',
    () async {
      final db = createInMemoryDatabase();
      addTearDown(db.close);
      final outbox = SyncOutboxRepository(db);

      await outbox.enqueue(
        entityType: SyncEntityType.item,
        entityId: 'abc',
        baseRevision: 1,
        operation: SyncOperation.upsert,
      );
      await outbox.enqueue(
        entityType: SyncEntityType.channel,
        entityId: 'abc',
        baseRevision: 2,
        operation: SyncOperation.delete,
      );

      final pending = await outbox.readPending();
      expect(pending, hasLength(2));
      expect(pending.map((mutation) => mutation.entity).toSet(), {
        const SyncEntityKey(type: SyncEntityType.item, id: 'abc'),
        const SyncEntityKey(type: SyncEntityType.channel, id: 'abc'),
      });
    },
  );

  test('new edit coalesces while preserving first base revision', () async {
    final db = createInMemoryDatabase();
    addTearDown(db.close);
    final outbox = SyncOutboxRepository(db);
    const key = SyncEntityKey(type: SyncEntityType.item, id: 'item');

    final first = await outbox.enqueue(
      entityType: key.type,
      entityId: key.id,
      baseRevision: 7,
      operation: SyncOperation.upsert,
    );
    await (db.update(db.syncOutbox)..where(
          (row) => row.entityType.equals('item') & row.entityId.equals('item'),
        ))
        .write(const SyncOutboxCompanion(retryCount: Value(3)));
    final second = await outbox.enqueue(
      entityType: key.type,
      entityId: key.id,
      baseRevision: 99,
      operation: SyncOperation.delete,
    );

    expect(await db.select(db.syncOutbox).get(), hasLength(1));
    expect(second.mutationId, isNot(first.mutationId));
    expect(second.baseRevision, 7);
    expect(second.operation, SyncOperation.delete);
    expect(second.retryCount, 0);
  });

  test('retry and acknowledgement are guarded by mutationId', () async {
    final db = createInMemoryDatabase();
    addTearDown(db.close);
    final outbox = SyncOutboxRepository(db);
    const key = SyncEntityKey(type: SyncEntityType.attachment, id: 'file');
    final mutation = await outbox.enqueue(
      entityType: key.type,
      entityId: key.id,
      baseRevision: 0,
      operation: SyncOperation.upsert,
    );

    expect(
      await outbox.incrementRetryCount(
        entity: key,
        mutationId: mutation.mutationId,
      ),
      isTrue,
    );
    expect((await outbox.getPending(key))!.retryCount, 1);
    expect(
      await outbox.acknowledge(entity: key, mutationId: 'stale-attempt'),
      isFalse,
    );
    expect(await outbox.getPending(key), isNotNull);
    expect(
      await outbox.acknowledge(entity: key, mutationId: mutation.mutationId),
      isTrue,
    );
    expect(await outbox.getPending(key), isNull);
  });
}
