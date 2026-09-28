import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/items/domain/item.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late ItemRepository repository;

  setUp(() {
    db = createInMemoryDatabase();
    repository = ItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<SyncOutboxEntry?> outboxEntry(String itemId) => (db.select(
    db.syncOutbox,
  )..where((t) => t.itemId.equals(itemId))).getSingleOrNull();

  Future<ItemRecord?> itemRecord(String id) =>
      (db.select(db.items)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<SyncOutboxEntry> pendingEntry(String id) async {
    final entry = await outboxEntry(id);
    expect(entry, isNotNull, reason: 'expected a pending outbox entry');
    return entry!;
  }

  /// Simulates a completed sync round trip: the server acknowledges the item
  /// at [revision], so the pending mutation is cleared.
  Future<void> simulateServerAck(String id, int revision) async {
    await (db.update(db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(serverRevision: Value(revision)),
    );
    await (db.delete(db.syncOutbox)..where((t) => t.itemId.equals(id))).go();
  }

  /// Lets pending drift stream emissions and microtasks settle.
  Future<void> settleStreams() => pumpEventQueue();

  final uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  group('item creation', () {
    test('generates a UUIDv4 id and persists content', () async {
      final before = DateTime.now();
      final item = await repository.createItem(content: 'ssh user@host:2222');
      final after = DateTime.now();

      expect(uuidV4Pattern.hasMatch(item.id), isTrue);
      final row = await itemRecord(item.id);
      expect(row, isNotNull);
      expect(row!.content, 'ssh user@host:2222');
      expect(row.createdAt.isBefore(before), isFalse);
      expect(row.updatedAt.isAfter(after), isFalse);
    });

    test('accepts a client-supplied id and keeps it stable', () async {
      const id = '11111111-1111-4111-8111-111111111111';
      final created = await repository.createItem(id: id, content: 'x');
      expect(created.id, id);
      await repository.updateItem(id, content: 'y');
      final updated = await repository.getItemById(id);
      expect(updated!.id, id);
    });

    test('persists optional title and note', () async {
      final item = await repository.createItem(
        content: 'body',
        title: 'the title',
        note: 'the note',
      );
      final stored = await repository.getItemById(item.id);
      expect(stored!.title, 'the title');
      expect(stored.note, 'the note');
    });

    test(
      'defaults title/note to null, tags to empty, isPinned to false',
      () async {
        final item = await repository.createItem(content: 'body');
        final stored = await repository.getItemById(item.id);
        expect(stored!.title, isNull);
        expect(stored.note, isNull);
        expect(stored.tags, isEmpty);
        expect(stored.isPinned, isFalse);
      },
    );

    test('tags round-trip through the database, including unicode', () async {
      final item = await repository.createItem(
        content: 'body',
        tags: ['a', '中文标签', 'cli:git#push!'],
      );
      final stored = await repository.getItemById(item.id);
      expect(stored!.tags, ['a', '中文标签', 'cli:git#push!']);
    });

    test('serverRevision defaults to 0 in the database row', () async {
      final item = await repository.createItem(content: 'body');
      final row = await itemRecord(item.id);
      expect(row!.serverRevision, 0);
    });

    test('rejects blank content', () async {
      await expectLater(
        repository.createItem(content: ''),
        throwsArgumentError,
      );
      await expectLater(
        repository.createItem(content: '   \n'),
        throwsArgumentError,
      );
    });
  });

  group('local CRUD', () {
    test('read returns null for an unknown id', () async {
      expect(await repository.getItemById('nope'), isNull);
    });

    test('update changes fields, bumps updatedAt, keeps createdAt', () async {
      final created = await repository.createItem(content: 'original');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final updated = await repository.updateItem(
        created.id,
        title: const FieldUpdate.set('t'),
        content: 'changed',
        note: const FieldUpdate.set('n'),
        tags: ['x'],
      );

      expect(updated.title, 't');
      expect(updated.content, 'changed');
      expect(updated.note, 'n');
      expect(updated.tags, ['x']);
      expect(updated.createdAt, created.createdAt);
      expect(updated.updatedAt.isAfter(created.updatedAt), isTrue);

      final stored = await repository.getItemById(created.id);
      expect(stored, updated);
    });

    test('partial update leaves other fields unchanged', () async {
      final created = await repository.createItem(
        content: 'c',
        title: 't',
        tags: ['a'],
      );
      final updated = await repository.updateItem(
        created.id,
        note: const FieldUpdate.set('new'),
      );
      expect(updated.title, 't');
      expect(updated.content, 'c');
      expect(updated.note, 'new');
      expect(updated.tags, ['a']);
    });

    test('title can be updated and explicitly cleared', () async {
      final created = await repository.createItem(
        content: 'c',
        title: 'original',
      );

      final updated = await repository.updateItem(
        created.id,
        title: const FieldUpdate.set('updated'),
      );
      expect(updated.title, 'updated');

      final cleared = await repository.updateItem(
        created.id,
        title: const FieldUpdate.set(null),
      );
      expect(cleared.title, isNull);
      expect((await repository.getItemById(created.id))!.title, isNull);
    });

    test('note can be updated and explicitly cleared', () async {
      final created = await repository.createItem(
        content: 'c',
        note: 'original',
      );

      final updated = await repository.updateItem(
        created.id,
        note: const FieldUpdate.set('updated'),
      );
      expect(updated.note, 'updated');

      final cleared = await repository.updateItem(
        created.id,
        note: const FieldUpdate.set(null),
      );
      expect(cleared.note, isNull);
      expect((await repository.getItemById(created.id))!.note, isNull);
    });

    test('omitted title and note remain unchanged', () async {
      final created = await repository.createItem(
        content: 'c',
        title: 'title',
        note: 'note',
      );

      final updated = await repository.updateItem(created.id, tags: ['tag']);

      expect(updated.title, 'title');
      expect(updated.note, 'note');
    });

    test('update rejects blank content and keeps the stored value', () async {
      final created = await repository.createItem(content: 'original');
      await expectLater(
        repository.updateItem(created.id, content: ' '),
        throwsArgumentError,
      );
      expect((await repository.getItemById(created.id))!.content, 'original');
    });

    test('update on an unknown id throws', () async {
      await expectLater(
        repository.updateItem('missing', content: 'x'),
        throwsStateError,
      );
    });

    test('pin and unpin persist', () async {
      final created = await repository.createItem(content: 'c');
      final pinned = await repository.setPinned(created.id, true);
      expect(pinned.isPinned, isTrue);
      final unpinned = await repository.setPinned(created.id, false);
      expect(unpinned.isPinned, isFalse);
      expect((await repository.getItemById(created.id))!.isPinned, isFalse);
    });

    test('watchActiveItems streams items newest-updated first', () async {
      final a = await repository.createItem(content: 'a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final b = await repository.createItem(content: 'b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await repository.updateItem(a.id, content: 'a2');

      final items = await repository.watchActiveItems().first;
      expect(items.map((e) => e.id).toList(), [a.id, b.id]);
    });

    test('watchItemById emits null, then the created item', () async {
      final emissions = <Item?>[];
      final subscription = repository
          .watchItemById('watch-me')
          .listen(emissions.add);
      // Let the stream's initial query run before the item exists.
      await settleStreams();

      await repository.createItem(id: 'watch-me', content: 'hello');
      await settleStreams();
      await subscription.cancel();

      expect(emissions, hasLength(2));
      expect(emissions.first, isNull);
      expect(emissions.last!.content, 'hello');
    });
  });

  group('soft delete', () {
    test('sets deletedAt, bumps updatedAt, retains the database row', () async {
      final created = await repository.createItem(content: 'c');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final deleted = await repository.softDeleteItem(created.id);

      expect(deleted.deletedAt, isNotNull);
      expect(deleted.updatedAt.isAfter(created.updatedAt), isTrue);

      final row = await itemRecord(created.id);
      expect(row, isNotNull, reason: 'delete is a tombstone, not a removal');
      expect(row!.deletedAt, deleted.deletedAt);
    });

    test('deleted items are excluded from active items', () async {
      final keep = await repository.createItem(content: 'keep');
      final remove = await repository.createItem(content: 'remove');
      await repository.softDeleteItem(remove.id);

      final active = await repository.watchActiveItems().first;
      expect(active.map((e) => e.id).toList(), [keep.id]);
    });

    test('getItemById still returns the tombstoned row', () async {
      final created = await repository.createItem(content: 'c');
      await repository.softDeleteItem(created.id);
      final fetched = await repository.getItemById(created.id);
      expect(fetched, isNotNull);
      expect(fetched!.isDeleted, isTrue);
    });

    test('restoreItem clears the tombstone', () async {
      final created = await repository.createItem(content: 'c');
      await repository.softDeleteItem(created.id);
      final restored = await repository.restoreItem(created.id);
      expect(restored.deletedAt, isNull);

      final active = await repository.watchActiveItems().first;
      expect(active.map((e) => e.id).toList(), [created.id]);
    });

    test('soft-deleting an already deleted item is a no-op', () async {
      final created = await repository.createItem(content: 'c');
      final first = await repository.softDeleteItem(created.id);
      final second = await repository.softDeleteItem(created.id);
      expect(second.deletedAt, first.deletedAt);
    });

    test(
      'update rejects a tombstoned item without changing delete state',
      () async {
        final created = await repository.createItem(content: 'c');
        final deleted = await repository.softDeleteItem(created.id);
        final deleteMutation = await pendingEntry(created.id);

        await expectLater(
          repository.updateItem(created.id, content: 'changed'),
          throwsStateError,
        );

        final stored = await repository.getItemById(created.id);
        final pending = await pendingEntry(created.id);
        expect(stored!.content, 'c');
        expect(stored.deletedAt, deleted.deletedAt);
        expect(pending.op, 'delete');
        expect(pending.mutationId, deleteMutation.mutationId);
      },
    );

    test(
      'setPinned rejects a tombstoned item without changing delete state',
      () async {
        final created = await repository.createItem(content: 'c');
        final deleted = await repository.softDeleteItem(created.id);
        final deleteMutation = await pendingEntry(created.id);

        await expectLater(
          repository.setPinned(created.id, true),
          throwsStateError,
        );

        final stored = await repository.getItemById(created.id);
        final pending = await pendingEntry(created.id);
        expect(stored!.isPinned, isFalse);
        expect(stored.deletedAt, deleted.deletedAt);
        expect(pending.op, 'delete');
        expect(pending.mutationId, deleteMutation.mutationId);
      },
    );
  });

  group('outbox durability', () {
    test(
      'create produces a pending upsert entry with baseRevision 0',
      () async {
        final item = await repository.createItem(content: 'c');
        final entry = await pendingEntry(item.id);
        expect(entry.op, 'upsert');
        expect(entry.baseRevision, 0);
        expect(entry.retryCount, 0);
        expect(entry.mutationId, isNotEmpty);
      },
    );

    test(
      'update produces a pending mutation based on serverRevision',
      () async {
        final item = await repository.createItem(content: 'c');
        await simulateServerAck(item.id, 5);

        await repository.updateItem(item.id, content: 'c2');
        final entry = await pendingEntry(item.id);
        expect(entry.op, 'upsert');
        expect(entry.baseRevision, 5);
      },
    );

    test('soft delete produces a pending delete mutation', () async {
      final item = await repository.createItem(content: 'c');
      await simulateServerAck(item.id, 3);
      await repository.softDeleteItem(item.id);
      final entry = await pendingEntry(item.id);
      expect(entry.op, 'delete');
      expect(entry.baseRevision, 3);
    });

    test('restore produces a pending upsert mutation', () async {
      final item = await repository.createItem(content: 'c');
      await simulateServerAck(item.id, 1);
      await repository.softDeleteItem(item.id);
      expect((await pendingEntry(item.id)).op, 'delete');

      await repository.restoreItem(item.id);
      final entry = await pendingEntry(item.id);
      expect(entry.op, 'upsert');
      expect(entry.baseRevision, 1);
    });

    test('pin toggle produces a pending mutation', () async {
      final item = await repository.createItem(content: 'c');
      await simulateServerAck(item.id, 2);
      await repository.setPinned(item.id, true);
      final entry = await pendingEntry(item.id);
      expect(entry.op, 'upsert');
    });

    test('multiple edits coalesce into a single outbox row', () async {
      final item = await repository.createItem(content: 'c');
      final firstMutationId = (await pendingEntry(item.id)).mutationId;

      await repository.updateItem(item.id, content: 'c2');
      await repository.updateItem(item.id, note: const FieldUpdate.set('n'));
      await repository.setPinned(item.id, true);

      final rows = await (db.select(
        db.syncOutbox,
      )..where((t) => t.itemId.equals(item.id))).get();
      expect(
        rows,
        hasLength(1),
        reason: 'repeated offline edits must not accumulate outbox rows',
      );
      expect(rows.single.mutationId, isNot(firstMutationId));
      expect(rows.single.op, 'upsert');
    });

    test('repeated edits do not advance baseRevision', () async {
      final item = await repository.createItem(content: 'c');
      await simulateServerAck(item.id, 5);

      await repository.updateItem(item.id, content: 'c2');
      expect((await pendingEntry(item.id)).baseRevision, 5);

      await repository.updateItem(item.id, note: const FieldUpdate.set('n'));
      await repository.setPinned(item.id, true);
      expect(
        (await pendingEntry(item.id)).baseRevision,
        5,
        reason:
            'baseRevision must reflect the first divergence, '
            'not each local edit',
      );

      final row = await itemRecord(item.id);
      expect(
        row!.serverRevision,
        5,
        reason: 'local edits never touch serverRevision',
      );
    });

    test(
      'delete after pending edits keeps baseRevision and marks delete',
      () async {
        final item = await repository.createItem(content: 'c');
        await simulateServerAck(item.id, 7);

        await repository.updateItem(item.id, content: 'c2');
        await repository.softDeleteItem(item.id);
        final entry = await pendingEntry(item.id);
        expect(entry.baseRevision, 7);
        expect(entry.op, 'delete');
      },
    );

    test('no-op updates do not refresh the pending mutation', () async {
      final item = await repository.createItem(content: 'c');
      final entry = await pendingEntry(item.id);
      await repository.updateItem(item.id); // all fields omitted
      final after = await outboxEntry(item.id);
      expect(after!.mutationId, entry.mutationId);
    });
  });

  group('transaction behavior', () {
    test('a failed create leaves no partial item or outbox state', () async {
      final created = await repository.createItem(
        id: 'dup-id',
        content: 'first',
      );
      final originalEntry = await outboxEntry(created.id);

      await expectLater(
        repository.createItem(id: 'dup-id', content: 'second'),
        throwsA(anything),
      );

      final row = await itemRecord('dup-id');
      expect(
        row!.content,
        'first',
        reason: 'the failed transaction must not modify the item',
      );
      final entry = await outboxEntry('dup-id');
      expect(
        entry!.mutationId,
        originalEntry!.mutationId,
        reason: 'the failed transaction must not replace pending state',
      );
    });

    test('database transactions roll back on error', () async {
      await expectLater(
        () => db.transaction(() async {
          await db
              .into(db.items)
              .insert(
                ItemsCompanion.insert(
                  id: 'rollback',
                  content: 'gone',
                  createdAt: DateTime(2026),
                  updatedAt: DateTime(2026),
                ),
              );
          throw StateError('boom');
        }),
        throwsA(anything),
      );
      expect(await itemRecord('rollback'), isNull);
    });

    test('every committed mutation has a pending outbox entry', () async {
      final created = await repository.createItem(content: 'c');
      await repository.updateItem(created.id, note: const FieldUpdate.set('n'));
      await repository.setPinned(created.id, true);
      await repository.softDeleteItem(created.id);
      final entry = await pendingEntry(created.id);
      expect(entry.op, 'delete');
      expect(await itemRecord(created.id), isNotNull);
    });
  });
}
