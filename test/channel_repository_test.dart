import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/sync/domain/sync_models.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late ChannelRepository channels;
  late ItemRepository items;

  setUp(() {
    db = createInMemoryDatabase();
    channels = ChannelRepository(db);
    items = ItemRepository(db);
  });

  tearDown(() => db.close());

  Future<SyncOutboxEntry> channelMutation(String id) =>
      (db.select(db.syncOutbox)..where(
            (row) => row.entityType.equals('channel') & row.entityId.equals(id),
          ))
          .getSingle();

  test(
    'creates roots and arbitrarily deep children with breadcrumbs',
    () async {
      final root = await channels.createRootChannel(
        id: 'root',
        name: ' Network ',
      );
      var parent = root;
      for (var depth = 0; depth < 12; depth++) {
        parent = await channels.createChildChannel(
          id: 'depth-$depth',
          name: 'Level $depth',
          parentId: parent.id,
        );
      }

      expect(root.name, 'Network');
      expect((await channels.watchRootChannels().first).single.id, root.id);
      expect((await channels.getBreadcrumbs(parent.id)), hasLength(13));
      final pending = await (db.select(
        db.syncOutbox,
      )..where((row) => row.entityType.equals('channel'))).get();
      expect(pending, hasLength(13));
      expect(pending.every((entry) => entry.op == 'upsert'), isTrue);
    },
  );

  test('renames and moves a child to another parent then root', () async {
    final a = await channels.createRootChannel(id: 'a', name: 'A');
    final b = await channels.createRootChannel(id: 'b', name: 'B');
    final child = await channels.createChildChannel(
      id: 'child',
      name: 'Child',
      parentId: a.id,
    );

    expect(
      (await channels.renameChannel(child.id, ' Renamed ')).name,
      'Renamed',
    );
    expect(
      (await channels.moveChannel(child.id, parentId: b.id)).parentId,
      b.id,
    );
    expect(
      (await channels.moveChannel(child.id, parentId: null)).parentId,
      isNull,
    );
  });

  test('rejects self-parent and descendant cycles', () async {
    final root = await channels.createRootChannel(id: 'root', name: 'Root');
    final child = await channels.createChildChannel(
      id: 'child',
      name: 'Child',
      parentId: root.id,
    );

    await expectLater(
      channels.moveChannel(root.id, parentId: root.id),
      throwsA(isA<ChannelRepositoryException>()),
    );
    await expectLater(
      channels.moveChannel(root.id, parentId: child.id),
      throwsA(isA<ChannelRepositoryException>()),
    );
  });

  test('rejects nonexistent and deleted parents', () async {
    await expectLater(
      channels.createChildChannel(name: 'Child', parentId: 'missing'),
      throwsA(isA<ChannelRepositoryException>()),
    );
    final deleted = await channels.createRootChannel(
      id: 'deleted',
      name: 'Deleted',
    );
    await channels.softDeleteChannel(deleted.id);
    await expectLater(
      channels.createChildChannel(name: 'Child', parentId: deleted.id),
      throwsA(isA<ChannelRepositoryException>()),
    );
    final active = await channels.createRootChannel(
      id: 'active',
      name: 'Active',
    );
    await expectLater(
      channels.moveChannel(active.id, parentId: deleted.id),
      throwsA(isA<ChannelRepositoryException>()),
    );
  });

  test(
    'only empty channels can be tombstoned and deleted rows are hidden',
    () async {
      final withChild = await channels.createRootChannel(
        id: 'parent',
        name: 'Parent',
      );
      final child = await channels.createChildChannel(
        id: 'child',
        name: 'Child',
        parentId: withChild.id,
      );
      await expectLater(
        channels.softDeleteChannel(withChild.id),
        throwsA(isA<ChannelRepositoryException>()),
      );

      final withItem = await channels.createRootChannel(
        id: 'items',
        name: 'Items',
      );
      await items.createItem(content: 'kept', channelId: withItem.id);
      await expectLater(
        channels.softDeleteChannel(withItem.id),
        throwsA(isA<ChannelRepositoryException>()),
      );

      final deleted = await channels.softDeleteChannel(child.id);
      expect(deleted.isDeleted, isTrue);
      expect(await channels.watchChildChannels(withChild.id).first, isEmpty);
      expect((await channels.getChannelById(child.id))!.isDeleted, isTrue);
    },
  );

  test('blank names are rejected', () async {
    await expectLater(
      channels.createRootChannel(name: '   '),
      throwsArgumentError,
    );
  });

  test('channel mutations queue and coalesce with no-op suppression', () async {
    final root = await channels.createRootChannel(id: 'root', name: 'Root');
    var mutation = await channelMutation(root.id);
    expect(mutation.op, SyncOperation.upsert.wireValue);
    expect(mutation.baseRevision, 0);

    await (db.update(db.channels)..where((row) => row.id.equals(root.id)))
        .write(const ChannelsCompanion(serverRevision: Value(7)));
    await db.delete(db.syncOutbox).go();

    await channels.renameChannel(root.id, 'Root');
    await channels.moveChannel(root.id, parentId: null);
    expect(await db.select(db.syncOutbox).get(), isEmpty);

    await channels.renameChannel(root.id, 'Renamed');
    final renamed = await channelMutation(root.id);
    expect(renamed.baseRevision, 7);
    await (db.update(db.syncOutbox)..where(
          (row) =>
              row.entityType.equals('channel') & row.entityId.equals(root.id),
        ))
        .write(const SyncOutboxCompanion(retryCount: Value(4)));

    await channels.renameChannel(root.id, 'Renamed');
    mutation = await channelMutation(root.id);
    expect(mutation.mutationId, renamed.mutationId);
    expect(mutation.retryCount, 4);

    await channels.moveChannel(root.id, parentId: null);
    mutation = await channelMutation(root.id);
    expect(mutation.mutationId, renamed.mutationId);

    final parent = await channels.createRootChannel(id: 'parent', name: 'P');
    await channels.moveChannel(root.id, parentId: parent.id);
    final moved = await channelMutation(root.id);
    expect(moved.mutationId, isNot(renamed.mutationId));
    expect(moved.baseRevision, 7);
    expect(moved.retryCount, 0);

    await channels.moveChannel(root.id, parentId: null);
    await channels.softDeleteChannel(root.id);
    final deleted = await channelMutation(root.id);
    expect(deleted.op, SyncOperation.delete.wireValue);
    expect(deleted.baseRevision, 7);
  });
}
