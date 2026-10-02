import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/providers.dart';
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

  Future<void> pumpApp(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const StashApp(),
      ),
    );
    await pumpUi(tester);
  }

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await db.close();
  }

  testWidgets(
    'narrow root creates and browses nested channels with breadcrumbs',
    (tester) async {
      await pumpApp(tester, size: const Size(430, 800));
      expect(find.byKey(const Key('new-item-button')), findsOneWidget);
      expect(find.byKey(const Key('empty-add-item')), findsOneWidget);

      await tester.tap(find.byKey(const Key('new-root-channel')));
      await pumpUi(tester);
      await tester.enterText(
        find.byKey(const Key('channel-name-field')),
        'Network',
      );
      await tester.tap(find.byKey(const Key('save-channel')));
      await pumpUi(tester);
      final root = (await channels.getActiveChannels()).single;

      await tester.tap(find.byKey(Key('channel-${root.id}')));
      await pumpUi(tester);
      expect(find.byKey(Key('breadcrumb-${root.id}')), findsOneWidget);

      await tester.tap(find.byKey(const Key('new-subchannel')));
      await pumpUi(tester);
      await tester.enterText(
        find.byKey(const Key('channel-name-field')),
        'WiFi',
      );
      await tester.tap(find.byKey(const Key('save-channel')));
      await pumpUi(tester);
      final child = (await channels.getActiveChannels()).singleWhere(
        (value) => value.parentId == root.id,
      );
      await tester.tap(find.byKey(Key('channel-${child.id}')));
      await pumpUi(tester);

      expect(find.byKey(Key('breadcrumb-${root.id}')), findsOneWidget);
      expect(find.byKey(Key('breadcrumb-${child.id}')), findsOneWidget);
      await tester.tap(find.byKey(const Key('channel-up')));
      await pumpUi(tester);
      expect(find.text('Network'), findsWidgets);
      expect(find.byKey(Key('breadcrumb-${child.id}')), findsNothing);
      await disposeApp(tester);
    },
  );

  testWidgets('item captured inside a channel stays there', (tester) async {
    final channel = await channels.createRootChannel(id: 'work', name: 'Work');
    await pumpApp(tester, size: const Size(430, 800));
    await tester.tap(find.byKey(Key('channel-${channel.id}')));
    await pumpUi(tester);
    await tester.tap(find.byKey(const Key('add-channel-item')));
    await pumpUi(tester);
    await enterDocumentText(tester, 'Channel item');
    await tester.tap(find.byKey(const Key('save-item-button')));
    await pumpUi(tester);

    expect(find.text('Channel item'), findsOneWidget);
    final stored = await db.select(db.items).getSingle();
    expect(stored.channelId, channel.id);
    await disposeApp(tester);
  });

  testWidgets('root quick capture creates an Inbox item', (tester) async {
    await pumpApp(tester, size: const Size(430, 800));
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);
    await enterDocumentText(tester, 'Inbox item');
    await tester.tap(find.byKey(const Key('save-item-button')));
    await pumpUi(tester);
    expect((await db.select(db.items).getSingle()).channelId, isNull);
    await disposeApp(tester);
  });

  testWidgets('detail moves an item and pinned view spans channels', (
    tester,
  ) async {
    final first = await channels.createRootChannel(id: 'first', name: 'First');
    final second = await channels.createRootChannel(
      id: 'second',
      name: 'Second',
    );
    final item = await items.createItem(
      id: 'move-me',
      content: 'Move me',
      channelId: first.id,
      isPinned: true,
    );
    await pumpApp(tester, size: const Size(430, 800));
    await tester.tap(find.byKey(const Key('open-pinned')));
    await pumpUi(tester);
    expect(find.byKey(Key('item-preview-${item.id}')), findsOneWidget);
    await tester.tap(find.byKey(Key('item-preview-${item.id}')));
    await pumpUi(tester);
    await tester.tap(find.byKey(const Key('move-item-button')));
    await pumpUi(tester);
    await tester.tap(find.byKey(Key('location-${second.id}')));
    await pumpUi(tester);

    expect((await items.getItemById(item.id))!.channelId, second.id);
    expect(find.text('Location: Second'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('wide layout uses two panes with a visible capture action', (
    tester,
  ) async {
    final channel = await channels.createRootChannel(id: 'wide', name: 'Wide');
    await pumpApp(tester, size: const Size(1200, 800));
    expect(find.byKey(const Key('wide-browser')), findsOneWidget);
    expect(find.byKey(const Key('new-item-button')), findsOneWidget);
    expect(find.text('Inbox'), findsWidgets);

    await tester.tap(find.byKey(Key('channel-${channel.id}')));
    await pumpUi(tester);
    expect(find.byKey(const Key('add-channel-item')), findsOneWidget);
    expect(find.byKey(const Key('new-subchannel')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets(
    'channel deletion refuses content and hides tombstoned channels',
    (tester) async {
      final nonEmpty = await channels.createRootChannel(
        id: 'non-empty',
        name: 'Non-empty',
      );
      await items.createItem(content: 'Keep me', channelId: nonEmpty.id);
      final hidden = await channels.createRootChannel(
        id: 'hidden',
        name: 'Hidden',
      );
      await channels.softDeleteChannel(hidden.id);

      await pumpApp(tester, size: const Size(430, 800));
      expect(find.text('Hidden'), findsNothing);
      await tester.tap(find.byKey(Key('channel-${nonEmpty.id}')));
      await pumpUi(tester);
      await tester.tap(find.byKey(const Key('channel-menu')));
      await pumpUi(tester);
      await tester.tap(find.byKey(const Key('delete-channel-action')));
      await pumpUi(tester);
      await tester.tap(find.byKey(const Key('confirm-delete-channel')));
      await pumpUi(tester);

      expect(
        find.text('Move or delete items in this channel first.'),
        findsOneWidget,
      );
      expect((await channels.getChannelById(nonEmpty.id))!.isDeleted, isFalse);
      await disposeApp(tester);
    },
  );
}

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> enterDocumentText(WidgetTester tester, String text) async {
  final editor = tester.widget<QuillEditor>(
    find.byKey(const Key('content-field')),
  );
  final replaceLength = editor.controller.document.length - 1;
  editor.controller.replaceText(
    0,
    replaceLength,
    text,
    TextSelection.collapsed(offset: text.length),
  );
  await tester.pump();
}
