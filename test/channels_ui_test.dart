import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/desktop_shell_preferences.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
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

  Future<void> pumpApp(
    WidgetTester tester, {
    Size? size,
    DesktopShellPreferences? shellPreferences,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (shellPreferences != null)
            desktopShellPreferencesRepositoryProvider.overrideWithValue(
              DesktopShellPreferencesRepository(shellPreferences),
            ),
        ],
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
      expect(find.byKey(const Key('empty-add-item')), findsNothing);
      expect(find.text('暂无频道'), findsOneWidget);
      expect(find.text('暂无条目'), findsOneWidget);

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

  testWidgets('item list shows one bounded thumbnail with an image count', (
    tester,
  ) async {
    const codec = ItemDocumentCodec();
    final document = Document.fromJson([
      {
        'insert': BlockEmbed.custom(const StashImageEmbed('first-image'))
            .toJson(),
      },
      {
        'insert': BlockEmbed.custom(const StashImageEmbed('second-image'))
            .toJson(),
      },
      {'insert': '\n'},
    ]);
    final item = await items.createItem(
      id: 'image-preview',
      document: codec.snapshot(document),
    );

    await pumpApp(tester, size: const Size(430, 800));

    expect(find.text('2 images'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(Key('item-thumbnail-${item.id}'))),
      const Size.square(80),
    );
    expect(find.byKey(Key('item-thumbnail-count-${item.id}')), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('mixed item keeps text, file summary, and image thumbnail', (
    tester,
  ) async {
    const codec = ItemDocumentCodec();
    final snapshot = codec.snapshot(
      Document.fromJson([
        {'insert': 'Mixed body\n'},
        {
          'insert': BlockEmbed.custom(const StashFileEmbed('mixed-file'))
              .toJson(),
        },
        {
          'insert': BlockEmbed.custom(const StashImageEmbed('mixed-image'))
              .toJson(),
        },
        {'insert': '\n'},
      ]),
    );
    final item = await items.createItem(
      id: 'mixed-preview',
      content: snapshot.plainText,
      document: snapshot,
    );

    await pumpApp(tester, size: const Size(1200, 800));

    expect(find.textContaining('Mixed body'), findsOneWidget);
    expect(find.byKey(Key('item-file-summary-${item.id}')), findsOneWidget);
    expect(find.byKey(Key('item-thumbnail-${item.id}')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(Key('item-thumbnail-${item.id}'))),
      const Size.square(80),
    );
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
    expect(find.text('收件箱'), findsWidgets);

    await tester.tap(find.byKey(Key('channel-${channel.id}')));
    await pumpUi(tester);
    expect(find.byKey(const Key('add-channel-item')), findsOneWidget);
    expect(find.byKey(const Key('new-subchannel')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('sidebar uses concise Chinese navigation and empty states', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1200, 800));

    expect(find.text('系统'), findsOneWidget);
    expect(find.text('收件箱'), findsWidgets);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('频道'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('Things you saved without filing'), findsNothing);
    expect(find.text('Important items from everywhere'), findsNothing);

    await tester.tap(find.byKey(const Key('open-pinned')));
    await pumpUi(tester);
    expect(find.text('暂无置顶'), findsOneWidget);
    expect(
      find.text('Pinned items from every channel appear here.'),
      findsNothing,
    );
    await disposeApp(tester);
  });

  testWidgets('empty channel keeps header actions without duplicate copy', (
    tester,
  ) async {
    final channel = await channels.createRootChannel(
      id: 'empty-channel',
      name: '空白频道',
    );
    await pumpApp(tester, size: const Size(1200, 800));

    await tester.tap(find.byKey(Key('channel-${channel.id}')));
    await pumpUi(tester);

    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('Add an item or create a subchannel.'), findsNothing);
    expect(find.byKey(const Key('empty-add-item')), findsNothing);
    expect(find.byKey(const Key('add-channel-item')), findsOneWidget);
    expect(find.text('添加条目'), findsWidgets);
    expect(find.byKey(const Key('new-subchannel')), findsOneWidget);
    expect(find.text('新建子频道'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('desktop sidebar collapses, keeps navigation, and persists', (
    tester,
  ) async {
    final preferences = _MemoryDesktopShellPreferences();
    final channel = await channels.createRootChannel(
      id: 'compact',
      name: 'Compact',
    );
    await pumpApp(
      tester,
      size: const Size(1200, 800),
      shellPreferences: preferences,
    );

    expect(tester.getSize(find.byKey(const Key('desktop-sidebar'))).width, 216);
    await tester.tap(find.byKey(const Key('collapse-sidebar')));
    await pumpUi(tester);

    expect(find.byKey(const Key('collapsed-root-browser')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('desktop-sidebar'))).width, 56);
    expect(find.byKey(Key('channel-${channel.id}')), findsOneWidget);
    expect(await preferences.getBool('desktop_sidebar_collapsed'), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpApp(
      tester,
      size: const Size(1200, 800),
      shellPreferences: preferences,
    );
    expect(find.byKey(const Key('collapsed-root-browser')), findsOneWidget);

    await tester.tap(find.byKey(const Key('expand-sidebar')));
    await pumpUi(tester);
    expect(tester.getSize(find.byKey(const Key('desktop-sidebar'))).width, 216);
    await disposeApp(tester);
  });

  testWidgets(
    'desktop sidebar resizes, persists on drag end, and restores after collapse',
    (tester) async {
      final preferences = _MemoryDesktopShellPreferences();
      await pumpApp(
        tester,
        size: const Size(1200, 800),
        shellPreferences: preferences,
      );

      final handle = find.byKey(const Key('desktop-sidebar-resize-handle'));
      expect(handle, findsOneWidget);
      final mouseRegion = tester.widget<MouseRegion>(
        find.descendant(of: handle, matching: find.byType(MouseRegion)).first,
      );
      expect(mouseRegion.cursor, SystemMouseCursors.resizeColumn);

      final resizeGesture = await tester.startGesture(tester.getCenter(handle));
      await resizeGesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await resizeGesture.moveBy(const Offset(80, 0));
      await tester.pump();
      final resizedWidth = tester
          .getSize(find.byKey(const Key('desktop-sidebar')))
          .width;
      expect(resizedWidth, closeTo(316, 1));
      expect(
        await preferences.getDouble(
          DesktopShellPreferencesRepository.sidebarExpandedWidthKey,
        ),
        isNull,
      );
      await resizeGesture.up();
      await pumpUi(tester);
      expect(
        await preferences.getDouble(
          DesktopShellPreferencesRepository.sidebarExpandedWidthKey,
        ),
        closeTo(resizedWidth, 1),
      );

      await tester.tap(find.byKey(const Key('collapse-sidebar')));
      await pumpUi(tester);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        DesktopSidebarDimensions.collapsedWidth,
      );
      expect(handle, findsNothing);
      await tester.tap(find.byKey(const Key('expand-sidebar')));
      await pumpUi(tester);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        closeTo(resizedWidth, 1),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await pumpApp(
        tester,
        size: const Size(1200, 800),
        shellPreferences: preferences,
      );
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        closeTo(resizedWidth, 1),
      );
      await tester.tap(find.byKey(const Key('desktop-sidebar-resize-handle')));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.byKey(const Key('desktop-sidebar-resize-handle')));
      await pumpUi(tester);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        DesktopSidebarDimensions.defaultExpandedWidth,
      );
      await disposeApp(tester);
    },
  );

  testWidgets('absolute sidebar drag is independent of update count', (
    tester,
  ) async {
    final preferences = _MemoryDesktopShellPreferences();
    await pumpApp(
      tester,
      size: const Size(1200, 800),
      shellPreferences: preferences,
    );

    Future<double> dragSidebar(List<double> movements) async {
      final handle = find.byKey(const Key('desktop-sidebar-resize-handle'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      for (final movement in movements) {
        await gesture.moveBy(Offset(movement, 0));
        await tester.pump();
      }
      await gesture.up();
      await pumpUi(tester);
      return tester.getSize(find.byKey(const Key('desktop-sidebar'))).width;
    }

    final singleUpdateWidth = await dragSidebar(const [50]);
    expect(singleUpdateWidth, closeTo(266, 1));

    await tester.tap(find.byKey(const Key('desktop-sidebar-resize-handle')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byKey(const Key('desktop-sidebar-resize-handle')));
    await pumpUi(tester);
    expect(
      tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
      DesktopSidebarDimensions.defaultExpandedWidth,
    );

    final severalUpdatesWidth = await dragSidebar(const [20, 10, 10, 10]);
    expect(severalUpdatesWidth, closeTo(266, 1));
    expect(severalUpdatesWidth, closeTo(singleUpdateWidth, 0.1));
    await disposeApp(tester);
  });

  testWidgets('desktop sidebar clamps at the responsive threshold', (
    tester,
  ) async {
    final preferences = _MemoryDesktopShellPreferences();
    await preferences.setDouble(
      DesktopShellPreferencesRepository.sidebarExpandedWidthKey,
      900,
    );
    await pumpApp(
      tester,
      size: const Size(900, 700),
      shellPreferences: preferences,
    );

    expect(find.byKey(const Key('wide-browser')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
      DesktopSidebarDimensions.maximumExpandedWidth,
    );
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets(
    'four-item section keeps rounded spacing, click, and whole-row drag',
    (tester) async {
      final channel = await channels.createRootChannel(
        id: 'multi-item-target',
        name: 'Multi-item target',
      );
      final created = <String>[];
      for (var index = 0; index < 4; index++) {
        final item = await items.createItem(
          id: 'surface-$index',
          title: 'Item $index',
          content: 'Body $index',
          tags: index == 0 ? const ['alpha'] : const [],
        );
        created.add(item.id);
      }
      await pumpApp(tester, size: const Size(1200, 800));

      expect(tester.takeException(), isNull);
      final surfaceFinders = created
          .map((id) => find.byKey(Key('item-surface-$id')))
          .toList();
      for (final surfaceFinder in surfaceFinders) {
        expect(surfaceFinder, findsOneWidget);
        final surface = tester.widget<Material>(surfaceFinder);
        expect(surface.clipBehavior, Clip.antiAlias);
        final shape = surface.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, const BorderRadius.all(Radius.circular(10)));
        final ink = tester.widget<InkWell>(
          find.descendant(of: surfaceFinder, matching: find.byType(InkWell)),
        );
        expect(ink.borderRadius, const BorderRadius.all(Radius.circular(10)));
        expect(ink.hoverColor, isNotNull);
        expect(ink.splashColor, isNotNull);
      }
      final surfaceRects = surfaceFinders.map(tester.getRect).toList()
        ..sort((first, second) => first.top.compareTo(second.top));
      for (var index = 1; index < surfaceRects.length; index++) {
        expect(surfaceRects[index].top - surfaceRects[index - 1].bottom, 8);
      }
      expect(
        find.descendant(
          of: find.byKey(const Key('item-list-content')),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
      expect(
        tester.getSize(find.byKey(const Key('item-list-content'))).width,
        860,
      );
      for (final id in created) {
        expect(find.byKey(Key('item-drag-source-$id')), findsOneWidget);
      }

      await tester.tap(find.byKey(Key('item-preview-${created.first}')));
      await pumpUi(tester);
      expect(find.byKey(const Key('move-item-button')), findsOneWidget);
      await tester.pageBack();
      await pumpUi(tester);

      await dragTo(
        tester,
        find.byKey(Key('item-preview-${created.last}')),
        find.byKey(Key('channel-${channel.id}')),
      );
      await pumpUi(tester);
      expect((await items.getItemById(created.last))!.channelId, channel.id);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    },
  );

  testWidgets('item list uses the available width on narrow screens', (
    tester,
  ) async {
    await items.createItem(id: 'narrow-surface', content: 'Narrow body');
    await pumpApp(tester, size: const Size(430, 800));

    expect(
      tester.getSize(find.byKey(const Key('item-list-content'))).width,
      inInclusiveRange(380, 398),
    );
    expect(
      find.byKey(const Key('desktop-sidebar-resize-handle')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('desktop whole-row drag moves an item to a channel and Inbox', (
    tester,
  ) async {
    final channel = await channels.createRootChannel(
      id: 'drop-target',
      name: 'Drop target',
    );
    final item = await items.createItem(id: 'drag-me', content: 'Drag me');
    await pumpApp(tester, size: const Size(1200, 800));

    await dragTo(
      tester,
      find.byKey(Key('item-preview-${item.id}')),
      find.byKey(Key('channel-${channel.id}')),
    );
    await pumpUi(tester);
    expect((await items.getItemById(item.id))!.channelId, channel.id);

    await tester.tap(find.byKey(Key('channel-${channel.id}')));
    await pumpUi(tester);
    expect(find.byKey(Key('item-drag-source-${item.id}')), findsOneWidget);
    expect(find.byKey(Key('item-drag-handle-${item.id}')), findsNothing);
    await dragTo(
      tester,
      find.byKey(Key('item-preview-${item.id}')),
      find.byKey(const Key('open-inbox')),
    );
    await pumpUi(tester);
    expect((await items.getItemById(item.id))!.channelId, isNull);
    await tester.tap(find.byKey(const Key('open-inbox')));
    await pumpUi(tester);
    await tester.tap(find.byKey(Key('item-preview-${item.id}')));
    await pumpUi(tester);
    expect(find.byKey(const Key('move-item-button')), findsOneWidget);
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

class _MemoryDesktopShellPreferences implements DesktopShellPreferences {
  final Map<String, Object> values = {};

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async {
    values[key] = value;
  }
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

Future<void> dragTo(WidgetTester tester, Finder source, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(source));
  await gesture.moveBy(const Offset(12, 0));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 200));
  await gesture.up();
  await tester.pump();
}
