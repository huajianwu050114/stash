import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_repository.dart';

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

  test('creates items in Inbox and directly inside a channel', () async {
    final channel = await channels.createRootChannel(
      id: 'channel',
      name: 'Channel',
    );
    final inbox = await items.createItem(id: 'inbox', content: 'Inbox');
    final filed = await items.createItem(
      id: 'filed',
      content: 'Filed',
      channelId: channel.id,
    );

    expect(inbox.channelId, isNull);
    expect(filed.channelId, channel.id);
    expect((await items.watchInboxItems().first).single.id, inbox.id);
    expect(
      (await items.watchItemsInChannel(channel.id).first).single.id,
      filed.id,
    );
  });

  test('moves Inbox to channel, between channels, and back to Inbox', () async {
    final first = await channels.createRootChannel(id: 'first', name: 'First');
    final second = await channels.createRootChannel(
      id: 'second',
      name: 'Second',
    );
    final item = await items.createItem(id: 'item', content: 'Move me');

    expect(
      (await items.moveItem(item.id, channelId: first.id)).channelId,
      first.id,
    );
    expect(
      (await items.moveItem(item.id, channelId: second.id)).channelId,
      second.id,
    );
    expect((await items.moveItem(item.id, channelId: null)).channelId, isNull);
  });

  test('rejects missing/deleted targets and tombstoned items', () async {
    final item = await items.createItem(id: 'item', content: 'Move me');
    await expectLater(
      items.moveItem(item.id, channelId: 'missing'),
      throwsStateError,
    );
    final deleted = await channels.createRootChannel(
      id: 'deleted',
      name: 'Deleted',
    );
    await channels.softDeleteChannel(deleted.id);
    await expectLater(
      items.moveItem(item.id, channelId: deleted.id),
      throwsStateError,
    );
    await expectLater(
      items.createItem(content: 'No', channelId: deleted.id),
      throwsStateError,
    );
    await items.softDeleteItem(item.id);
    await expectLater(
      items.moveItem(item.id, channelId: null),
      throwsStateError,
    );
  });

  test('pinning never changes channel location', () async {
    final channel = await channels.createRootChannel(
      id: 'channel',
      name: 'Channel',
    );
    final item = await items.createItem(
      content: 'Pinned',
      channelId: channel.id,
    );
    final pinned = await items.setPinned(item.id, true);
    expect(pinned.channelId, channel.id);
    expect((await items.watchPinnedItems().first).single.channelId, channel.id);
  });

  group('restore location', () {
    test('restoring an Inbox tombstone remains in Inbox', () async {
      final item = await items.createItem(id: 'inbox', content: 'Inbox');
      await items.softDeleteItem(item.id);

      final restored = await items.restoreItem(item.id);

      expect(restored.deletedAt, isNull);
      expect(restored.channelId, isNull);
      expect((await items.watchInboxItems().first).single.id, item.id);
    });

    test('restoring into an active channel preserves channelId', () async {
      final channel = await channels.createRootChannel(
        id: 'active',
        name: 'Active',
      );
      final item = await items.createItem(
        id: 'filed',
        content: 'Filed',
        channelId: channel.id,
      );
      await items.softDeleteItem(item.id);

      final restored = await items.restoreItem(item.id);

      expect(restored.deletedAt, isNull);
      expect(restored.channelId, channel.id);
      expect(
        (await items.watchItemsInChannel(channel.id).first).single.id,
        item.id,
      );
    });

    test(
      'restoring after its channel is deleted moves the item to Inbox',
      () async {
        final channel = await channels.createRootChannel(
          id: 'deleted',
          name: 'Deleted',
        );
        final item = await items.createItem(
          id: 'stranded',
          content: 'Reachable again',
          channelId: channel.id,
        );
        await items.softDeleteItem(item.id);
        await channels.softDeleteChannel(channel.id);

        final restored = await items.restoreItem(item.id);

        expect(restored.deletedAt, isNull);
        expect(restored.channelId, isNull);
        expect((await items.watchInboxItems().first).single.id, item.id);
        expect(await items.watchItemsInChannel(channel.id).first, isEmpty);
        final pending = await (db.select(
          db.syncOutbox,
        )..where((row) => row.itemId.equals(item.id))).getSingle();
        expect(pending.op, 'upsert');
      },
    );
  });
}
