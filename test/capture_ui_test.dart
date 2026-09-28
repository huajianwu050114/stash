import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/items/data/item_repository.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late ItemRepository repository;

  setUp(() {
    db = createInMemoryDatabase();
    repository = ItemRepository(db);
  });

  Future<void> pumpApp(WidgetTester tester) async {
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

  testWidgets('content-only capture rejects blank input and appears on home', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('empty-home')), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);

    expect(find.text('New item'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('content-field')), '   ');
    await tester.pump();
    expect(saveButton(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('content-field')),
      'ssh user@example.test -p 2222',
    );
    await tester.pump();
    expect(saveButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('save-item-button')));
    await pumpUi(tester);

    final recentSection = find.byKey(const Key('recent-section'));
    expect(recentSection, findsOneWidget);
    expect(
      find.descendant(
        of: recentSection,
        matching: find.text('ssh user@example.test -p 2222'),
      ),
      findsOneWidget,
    );
    final rows = await db.select(db.items).get();
    expect(rows, hasLength(1));
    expect(rows.single.title, isNull);
    expect(rows.single.note, isNull);
    expect(rows.single.tags, '[]');

    await disposeApp(tester);
  });

  testWidgets(
    'opening shows full content and editing persists cleared fields',
    (tester) async {
      final item = await repository.createItem(
        id: 'editable',
        title: 'Old title',
        content: 'A full value that should be visible in detail.',
        note: 'Old note',
        tags: ['old'],
      );
      await pumpApp(tester);

      await tester.tap(find.byKey(Key('item-preview-${item.id}')));
      await pumpUi(tester);
      expect(
        find.descendant(
          of: find.byType(SelectionArea),
          matching: find.text('A full value that should be visible in detail.'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('copy-item-button')), findsOneWidget);
      expect(find.text('Old note'), findsOneWidget);

      MethodCall? clipboardCall;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        clipboardCall = call;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.byKey(const Key('copy-item-button')));
      await pumpUi(tester);
      expect(clipboardCall?.method, 'Clipboard.setData');
      expect(clipboardCall?.arguments, {'text': item.content});
      expect(find.text('Copied to clipboard'), findsOneWidget);

      await tester.tap(find.byKey(const Key('edit-item-button')));
      await pumpUi(tester);
      await tester.enterText(find.byKey(const Key('title-field')), '');
      await tester.enterText(
        find.byKey(const Key('content-field')),
        'Changed content',
      );
      await tester.ensureVisible(find.byKey(const Key('note-field')));
      await tester.enterText(find.byKey(const Key('note-field')), '');
      await tester.ensureVisible(find.byKey(const Key('tags-field')));
      await tester.enterText(find.byKey(const Key('tags-field')), 'work, cli');
      await tester.tap(find.byKey(const Key('save-item-button')));
      await pumpUi(tester);

      final stored = await repository.getItemById(item.id);
      expect(stored!.content, 'Changed content');
      expect(stored.title, isNull);
      expect(stored.note, isNull);
      expect(stored.tags, ['work', 'cli']);
      expect(
        find.descendant(
          of: find.byType(SelectionArea),
          matching: find.text('Changed content'),
        ),
        findsOneWidget,
      );
      expect(find.text('Old title'), findsNothing);
      expect(find.text('Old note'), findsNothing);

      await disposeApp(tester);
    },
  );

  testWidgets('pinning moves an item to Pinned without duplicating it', (
    tester,
  ) async {
    final pinMe = await repository.createItem(id: 'pin-me', content: 'Pin me');
    final stayRecent = await repository.createItem(
      id: 'stay-recent',
      content: 'Stay recent',
    );
    await pumpApp(tester);

    await tester.tap(find.byKey(Key('item-preview-${pinMe.id}')));
    await pumpUi(tester);
    await tester.tap(find.byKey(const Key('pin-item-button')));
    await pumpUi(tester);
    expect(find.text('Unpin'), findsOneWidget);
    await tester.pageBack();
    await pumpUi(tester);

    final pinnedSection = find.byKey(const Key('pinned-section'));
    final recentSection = find.byKey(const Key('recent-section'));
    final pinnedPreview = find.byKey(Key('item-preview-${pinMe.id}'));
    final recentPreview = find.byKey(Key('item-preview-${stayRecent.id}'));
    expect(pinnedSection, findsOneWidget);
    expect(recentSection, findsOneWidget);
    expect(
      find.descendant(of: pinnedSection, matching: pinnedPreview),
      findsOneWidget,
    );
    expect(
      find.descendant(of: recentSection, matching: pinnedPreview),
      findsNothing,
    );
    expect(
      find.descendant(of: recentSection, matching: recentPreview),
      findsOneWidget,
    );
    expect(pinnedPreview, findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('delete removes the item and tombstones never appear on home', (
    tester,
  ) async {
    final active = await repository.createItem(
      id: 'active',
      content: 'Delete me',
    );
    final alreadyDeleted = await repository.createItem(
      id: 'already-deleted',
      content: 'Hidden tombstone',
    );
    await repository.softDeleteItem(alreadyDeleted.id);
    await pumpApp(tester);

    expect(find.text('Hidden tombstone'), findsNothing);
    await tester.tap(find.byKey(Key('item-preview-${active.id}')));
    await pumpUi(tester);
    await tester.tap(find.byKey(const Key('delete-item-button')));
    await tester.pump();
    expect(find.text('Delete this item?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-button')));
    await pumpUi(tester);

    expect(find.text('Delete me'), findsNothing);
    expect(find.text('Hidden tombstone'), findsNothing);
    expect(find.byKey(const Key('empty-home')), findsOneWidget);
    expect((await repository.getItemById(active.id))!.isDeleted, isTrue);
    final activeRows = (await db.select(db.items).get()).where(
      (row) => row.deletedAt == null,
    );
    expect(activeRows, isEmpty);

    await disposeApp(tester);
  });
}

TextButton saveButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(const Key('save-item-button')));

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
}
