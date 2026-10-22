import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/app.dart';
import 'package:stash/app/appearance.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/attachments/data/file_attachment_ingestor.dart';
import 'package:stash/features/attachments/data/file_import_sources.dart';
import 'package:stash/features/attachments/data/image_import_sources.dart';
import 'package:stash/features/attachments/presentation/attachment_drop_region.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/items/domain/item.dart';
import 'package:stash/features/quick_stash/application/quick_stash_controller.dart';
import 'package:stash/features/quick_stash/application/quick_stash_settings_controller.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';
import 'package:stash/platform/desktop_window/desktop_window_service.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late Directory supportDirectory;
  late AttachmentRepository attachments;
  late _FakeWindow window;
  late QuickStashController quickStash;
  late QuickStashSettingsController settings;
  late _FakeImagePicker picker;
  late _FakeFilePicker filePicker;
  late _FakeClipboard clipboard;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp(
      'stash-quick-test-',
    );
    attachments = AttachmentRepository(db, storageRoot: supportDirectory);
    window = _FakeWindow();
    quickStash = QuickStashController(window);
    await quickStash.showQuick();
    settings = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(_MemoryStore()),
      hotkeys: const NoopGlobalHotkeyService(),
      onGlobalShortcut: () {},
    );
    await settings.initialize();
    picker = _FakeImagePicker();
    filePicker = _FakeFilePicker();
    clipboard = _FakeClipboard();
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    ItemRepository? itemRepository,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (itemRepository != null)
          itemRepositoryProvider.overrideWithValue(itemRepository),
        attachmentRepositoryProvider.overrideWithValue(attachments),
        imagePickerProvider.overrideWithValue(picker),
        filePickerProvider.overrideWithValue(filePicker),
        clipboardReaderProvider.overrideWithValue(clipboard),
        quickStashControllerProvider.overrideWithValue(quickStash),
        quickStashSettingsControllerProvider.overrideWithValue(settings),
        appearanceRepositoryProvider.overrideWithValue(
          AppearanceRepository(_MemoryAppearancePreferences()),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      container.dispose();
      await tester.pump(Duration.zero);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await db.close();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (await supportDirectory.exists()) {
        await _deleteDirectoryWithRetry(supportDirectory);
      }
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const StashApp()),
    );
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);
    expect(
      find.byKey(const Key('quick-attachment-drop-region')),
      findsOneWidget,
    );
  }

  testWidgets('text plus Enter saves exactly one item and resets session', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'hello stash');

    await pressKey(tester, LogicalKeyboardKey.enter);

    final items = await db.select(db.items).get();
    expect(items, hasLength(1));
    expect(items.single.content, 'hello stash');
    expect(items.single.channelId, isNull);
    expect(window.hideCalls, 1);
    expect(quickDocument(tester).toPlainText(), '\n');
  });

  testWidgets('new session defaults to Inbox and saves there untouched', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(
      find.descendant(
        of: find.byKey(const Key('quick-location-button')),
        matching: find.text('收件箱'),
      ),
      findsOneWidget,
    );
    enterQuickText(tester, 'zero friction');
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect((await db.select(db.items).getSingle()).channelId, isNull);
  });

  testWidgets('root Channel is selected and written during Item creation', (
    tester,
  ) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '项目');
    await pumpApp(tester);

    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'direct route');
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect((await db.select(db.items).getSingle()).channelId, channel.id);
  });

  testWidgets('nested Channel uses its breadcrumb and receives the Item', (
    tester,
  ) async {
    final channels = ChannelRepository(db);
    final root = await channels.createRootChannel(name: '学习');
    final child = await channels.createChildChannel(
      name: '论文',
      parentId: root.id,
    );
    await pumpApp(tester);

    await openQuickLocationPicker(tester);
    expect(find.text('学习 / 论文'), findsOneWidget);
    await tester.tap(find.byKey(Key('quick-location-${child.id}')));
    await pumpUi(tester);
    expect(find.text('学习 / 论文'), findsOneWidget);
    enterQuickText(tester, 'nested route');
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect((await db.select(db.items).getSingle()).channelId, child.id);
  });

  testWidgets('destination resets to Inbox after save and discard', (
    tester,
  ) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '临时');
    await pumpApp(tester);

    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'save me');
    await pressKey(tester, LogicalKeyboardKey.enter);
    expect(find.text('收件箱'), findsOneWidget);

    await quickStash.showQuick();
    await pumpUi(tester);
    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'discard me');
    await tester.tap(find.byKey(const Key('quick-close')));
    await pumpUi(tester);
    expect(find.text('收件箱'), findsOneWidget);
  });

  testWidgets('picker search matches breadcrumb and keeps Inbox available', (
    tester,
  ) async {
    final channels = ChannelRepository(db);
    final root = await channels.createRootChannel(name: '学习');
    final paper = await channels.createChildChannel(
      name: '论文',
      parentId: root.id,
    );
    final memes = await channels.createRootChannel(name: '表情包');
    await pumpApp(tester);
    await openQuickLocationPicker(tester);

    await tester.enterText(
      find.byKey(const Key('quick-location-search')),
      '学习 / 论文',
    );
    await tester.pump();

    expect(find.byKey(Key('quick-location-${paper.id}')), findsOneWidget);
    expect(find.byKey(Key('quick-location-${memes.id}')), findsNothing);
    expect(find.byKey(const Key('quick-location-inbox')), findsOneWidget);
    await pressKey(tester, LogicalKeyboardKey.escape);
  });

  testWidgets(
    'Ctrl+K keyboard selection does not submit and restores focus and caret',
    (tester) async {
      final channel = await ChannelRepository(db)
          .createRootChannel(name: 'Alpha');
      await pumpApp(tester);
      enterQuickText(tester, 'draft');
      final editor = quickEditor(tester);
      editor.controller.updateSelection(
        const TextSelection.collapsed(offset: 2),
        ChangeSource.local,
      );

      await pressKey(tester, LogicalKeyboardKey.keyK, control: true);
      expect(find.byKey(const Key('quick-location-picker')), findsOneWidget);
      await pressKey(tester, LogicalKeyboardKey.arrowDown);
      await pressKey(tester, LogicalKeyboardKey.enter);

      expect(find.byKey(const Key('quick-location-picker')), findsNothing);
      expect(await db.select(db.items).get(), isEmpty);
      expect(window.hideCalls, 0);
      expect(find.text('Alpha'), findsOneWidget);
      expect(editor.focusNode.hasFocus, isTrue);
      expect(
        editor.controller.selection,
        const TextSelection.collapsed(offset: 2),
      );

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect((await db.select(db.items).getSingle()).channelId, channel.id);
    },
  );

  testWidgets('picker Escape closes only picker; next Escape discards', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'keep while picker closes');

    await pressKey(tester, LogicalKeyboardKey.keyK, control: true);
    await pressKey(tester, LogicalKeyboardKey.escape);

    expect(find.byKey(const Key('quick-location-picker')), findsNothing);
    expect(window.hideCalls, 0);
    expect(quickDocument(tester).toPlainText(), 'keep while picker closes\n');
    expect(quickEditor(tester).focusNode.hasFocus, isTrue);

    await pressKey(tester, LogicalKeyboardKey.escape);
    expect(window.hideCalls, 1);
  });

  testWidgets('picker creates a root Channel and selects it', (tester) async {
    await pumpApp(tester);
    await openQuickLocationPicker(tester);

    await tester.tap(find.byKey(const Key('quick-create-channel')));
    await pumpUi(tester);
    await tester.enterText(
      find.byKey(const Key('quick-channel-name-field')),
      '旅行',
    );
    await tester.tap(find.byKey(const Key('quick-save-channel')));
    await pumpUi(tester);

    final channel = (await ChannelRepository(db).getActiveChannels()).single;
    expect(channel.name, '旅行');
    expect(channel.parentId, isNull);
    expect(find.text('旅行'), findsOneWidget);
    expect(quickEditor(tester).focusNode.hasFocus, isTrue);
    enterQuickText(tester, 'new destination');
    await pressKey(tester, LogicalKeyboardKey.enter);
    expect((await db.select(db.items).getSingle()).channelId, channel.id);
  });

  testWidgets('deleted destination falls back safely to Inbox', (tester) async {
    final channels = ChannelRepository(db);
    final channel = await channels.createRootChannel(name: '短期');
    await pumpApp(tester);
    await selectQuickLocation(tester, channel.id);
    await channels.softDeleteChannel(channel.id);
    enterQuickText(tester, 'still save this');

    await pressKey(tester, LogicalKeyboardKey.enter);

    expect((await db.select(db.items).getSingle()).channelId, isNull);
    await quickStash.showQuick();
    await pumpUi(tester);
    await openQuickLocationPicker(tester);
    expect(find.byKey(Key('quick-location-${channel.id}')), findsNothing);
    await pressKey(tester, LogicalKeyboardKey.escape);
  });

  testWidgets('save failure preserves content and selected destination', (
    tester,
  ) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '可靠');
    await pumpApp(tester, itemRepository: _FailingItemRepository(db));
    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'retry later');

    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(await db.select(db.items).get(), isEmpty);
    expect(window.hideCalls, 0);
    expect(quickDocument(tester).toPlainText(), 'retry later\n');
    expect(find.text('可靠'), findsOneWidget);
    expect(find.text('Could not save this item.'), findsOneWidget);
  });

  testWidgets('Shift+Enter inserts newline without creating an item', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'line one');

    await pressKey(tester, LogicalKeyboardKey.enter, shift: true);

    expect(await db.select(db.items).get(), isEmpty);
    expect(quickDocument(tester).toPlainText(), contains('\n\n'));
    expect(window.hideCalls, 0);
  });

  testWidgets('blank Enter stays open and does not create an item', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, '   ');

    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(await db.select(db.items).get(), isEmpty);
    expect(window.hideCalls, 0);
    expect(
      find.text('Add text or an attachment before saving.'),
      findsOneWidget,
    );
  });

  testWidgets('image-only Enter saves an Inbox item', (tester) async {
    picker.image = imageData('screenshot.png');
    await pumpApp(tester);
    await tapInsertImage(tester);
    final attachment = await db.select(db.attachments).getSingle();

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.content, isEmpty);
    expect(item.channelId, isNull);
    expect(item.documentJson, contains(attachment.id));
    expect(window.hideCalls, 1);
  });

  testWidgets('image-only capture saves directly to a Channel', (tester) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '图片');
    picker.image = imageData('direct.png');
    await pumpApp(tester);
    await selectQuickLocation(tester, channel.id);
    await tapInsertImage(tester);

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.channelId, channel.id);
    expect(item.documentJson, contains('stash-image'));
  });

  testWidgets('dropped PDF plus Enter saves a file-only Inbox item', (
    tester,
  ) async {
    final source = File(
      '${supportDirectory.path}${Platform.pathSeparator}quick-paper.pdf',
    );
    source.writeAsBytesSync([1, 2, 3]);
    await pumpApp(tester);
    final dropRegion = tester.widget<AttachmentDropRegion>(
      find.byKey(const Key('quick-attachment-drop-region')),
    );

    await tester.runAsync(
      () => dropRegion.onFilesDropped([
        ImportedFileData.localFile(source, fileName: 'paper.pdf'),
      ]),
    );
    await pumpUi(tester);
    final attachment = await db.select(db.attachments).getSingle();
    expect(find.byKey(Key('attachment-file-${attachment.id}')), findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.content, isEmpty);
    expect(item.documentJson, contains(attachment.id));
    expect(window.hideCalls, 1);
  });

  testWidgets('PDF-only capture saves directly to a Channel', (tester) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '论文');
    final source = File(
      '${supportDirectory.path}${Platform.pathSeparator}direct-paper.pdf',
    );
    source.writeAsBytesSync([1, 2, 3]);
    await pumpApp(tester);
    await selectQuickLocation(tester, channel.id);
    final dropRegion = tester.widget<AttachmentDropRegion>(
      find.byKey(const Key('quick-attachment-drop-region')),
    );
    await tester.runAsync(
      () => dropRegion.onFilesDropped([
        ImportedFileData.localFile(source, fileName: 'direct-paper.pdf'),
      ]),
    );
    await pumpUi(tester);

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.channelId, channel.id);
    expect(item.documentJson, contains('stash-file'));
  });

  testWidgets('mixed text, image, and file capture keeps direct routing', (
    tester,
  ) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '项目');
    final source = File(
      '${supportDirectory.path}${Platform.pathSeparator}archive.zip',
    );
    source.writeAsBytesSync([4, 5, 6]);
    picker.image = imageData('diagram.png');
    await pumpApp(tester);
    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'supporting material');
    await tapInsertImage(tester);
    final dropRegion = tester.widget<AttachmentDropRegion>(
      find.byKey(const Key('quick-attachment-drop-region')),
    );
    await tester.runAsync(
      () => dropRegion.onFilesDropped([
        ImportedFileData.localFile(source, fileName: 'archive.zip'),
      ]),
    );
    await pumpUi(tester);

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.channelId, channel.id);
    expect(item.content, 'supporting material');
    final document = const ItemDocumentCodec().decode(
      documentJson: item.documentJson,
      legacyText: item.content,
    );
    final snapshot = const ItemDocumentCodec().snapshot(document);
    expect(snapshot.imageAttachmentIds, hasLength(1));
    expect(snapshot.fileAttachmentIds, hasLength(1));
  });

  testWidgets('multiple dropped files keep focus and coexist with text', (
    tester,
  ) async {
    final first = File(
      '${supportDirectory.path}${Platform.pathSeparator}first.docx',
    );
    final second = File(
      '${supportDirectory.path}${Platform.pathSeparator}second.zip',
    );
    first.writeAsBytesSync([1]);
    second.writeAsBytesSync([2]);
    await pumpApp(tester);
    enterQuickText(tester, 'references');
    final dropRegion = tester.widget<AttachmentDropRegion>(
      find.byKey(const Key('quick-attachment-drop-region')),
    );

    await tester.runAsync(
      () => dropRegion.onFilesDropped([
        ImportedFileData.localFile(first, fileName: 'first.docx'),
        ImportedFileData.localFile(second, fileName: 'second.zip'),
      ]),
    );
    await pumpUi(tester);

    expect(quickEditor(tester).focusNode.hasFocus, isTrue);
    expect(await db.select(db.attachments).get(), hasLength(2));
    await pressKey(tester, LogicalKeyboardKey.enter);
    final item = await db.select(db.items).getSingle();
    expect(item.content, 'references');
    final document = const ItemDocumentCodec().decode(
      documentJson: item.documentJson,
      legacyText: item.content,
    );
    expect(
      const ItemDocumentCodec().snapshot(document).fileAttachmentIds,
      hasLength(2),
    );
  });

  testWidgets('text paste restores focus and Enter submits without repair', (
    tester,
  ) async {
    clipboard
      ..text = ' world'
      ..dropFocusOnRead = true;
    await pumpApp(tester);
    enterQuickText(tester, 'hello');
    final editor = quickEditor(tester);
    clipboard.onFocusDropped = () => editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    expect(editor.focusNode.hasFocus, isTrue);

    await pressKey(tester, LogicalKeyboardKey.keyV, control: true);

    expect(editor.focusNode.hasFocus, isTrue);
    insertQuickTextAtCaret(tester, '!');
    await pumpUi(tester);
    expect(quickDocument(tester).toPlainText(), 'hello world!\n');

    await pressKey(tester, LogicalKeyboardKey.enter);

    expect((await db.select(db.items).get()).single.content, 'hello world!');
    expect(window.hideCalls, 1);
  });

  testWidgets('dropped text inserts at the caret and keeps Quick focused', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'hello world');
    final editor = quickEditor(tester);
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    final dropRegion = tester.widget<AttachmentDropRegion>(
      find.byKey(const Key('quick-attachment-drop-region')),
    );

    await Future<void>.sync(() => dropRegion.onTextDropped!(' dropped'));
    await pumpUi(tester);

    expect(quickDocument(tester).toPlainText(), 'hello dropped world\n');
    expect(editor.focusNode.hasFocus, isTrue);
  });

  testWidgets('image paste restores focus and preserves the embed caret', (
    tester,
  ) async {
    clipboard
      ..image = imageData('clipboard.png')
      ..dropFocusOnRead = true;
    await pumpApp(tester);
    enterQuickText(tester, 'before');
    final editor = quickEditor(tester);
    clipboard.onFocusDropped = () => editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );

    await pressKey(tester, LogicalKeyboardKey.keyV, control: true);
    await waitForAttachmentImport(tester, db);

    final attachment = await db.select(db.attachments).getSingle();
    expect(editor.focusNode.hasFocus, isTrue);
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 7),
    );
    insertQuickTextAtCaret(tester, 'caption');

    await pressKey(tester, LogicalKeyboardKey.enter);

    final item = await db.select(db.items).getSingle();
    expect(item.content, 'beforecaption');
    expect(item.documentJson, contains(attachment.id));
    expect(window.hideCalls, 1);
  });

  testWidgets('image picker restores editor focus after its async boundary', (
    tester,
  ) async {
    picker
      ..image = imageData('picker.png')
      ..dropFocusOnPick = true;
    await pumpApp(tester);
    enterQuickText(tester, 'before');
    final editor = quickEditor(tester);
    picker.onFocusDropped = () => editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );

    await tapInsertImage(tester);

    expect(editor.focusNode.hasFocus, isTrue);
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 7),
    );
  });

  testWidgets('Shift+Enter keeps focus for subsequent input and submit', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'line one');

    await pressKey(tester, LogicalKeyboardKey.enter, shift: true);

    expect(quickEditor(tester).focusNode.hasFocus, isTrue);
    insertQuickTextAtCaret(tester, 'line two');
    await pumpUi(tester);
    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(
      (await db.select(db.items).get()).single.content,
      'line one\nline two',
    );
    expect(window.hideCalls, 1);
  });

  testWidgets('window blur preserves the Quick Stash draft', (tester) async {
    await pumpApp(tester);
    enterQuickText(tester, 'keep this draft');
    final editor = quickEditor(tester);
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );

    editor.focusNode.unfocus();
    window.emitFocus(false);
    await pumpUi(tester);

    expect(quickDocument(tester).toPlainText(), 'keep this draft\n');
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 5),
    );
    expect(await db.select(db.items).get(), isEmpty);
  });

  testWidgets('window focus event restores editor focus and caret', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'hello world');
    final editor = quickEditor(tester);
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    editor.focusNode.unfocus();
    window.emitFocus(false);
    await pumpUi(tester);
    editor.focusNode.unfocus();
    await tester.pump();
    expect(editor.focusNode.hasFocus, isFalse);

    window.emitFocus(true);
    await pumpUi(tester);

    expect(editor.focusNode.hasFocus, isTrue);
    expect(
      editor.controller.selection,
      const TextSelection.collapsed(offset: 5),
    );
    insertQuickTextAtCaret(tester, '!');
    await pressKey(tester, LogicalKeyboardKey.enter);
    expect((await db.select(db.items).get()).single.content, 'hello! world');
  });

  testWidgets('hotkey-style toggle focuses visible unfocused Quick Stash', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'still here');
    final editor = quickEditor(tester);
    editor.focusNode.unfocus();
    window.emitFocus(false);
    await pumpUi(tester);
    editor.focusNode.unfocus();
    await tester.pump();
    expect(editor.focusNode.hasFocus, isFalse);

    await quickStash.toggleQuick();
    await pumpUi(tester);

    expect(window.focusCalls, 1);
    expect(window.hideCalls, 0);
    expect(editor.focusNode.hasFocus, isTrue);
    expect(quickDocument(tester).toPlainText(), 'still here\n');
  });

  testWidgets('blank lower editor surface focuses at the document end', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'abc');
    await pumpUi(tester);
    final editor = quickEditor(tester);
    final surface = find.byKey(const Key('quick-editor-surface'));
    final editorWidget = find.byKey(const Key('quick-content-field'));
    expect(
      tester.getSize(editorWidget).height,
      greaterThanOrEqualTo(tester.getSize(surface).height - 2),
    );
    editor.focusNode.unfocus();
    await tester.pump();
    expect(editor.focusNode.hasFocus, isFalse);

    final surfaceRect = tester.getRect(surface);
    await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.bottom - 16));
    await pumpUi(tester);

    expect(editor.focusNode.hasFocus, isTrue);
    expect(editor.controller.selection.isCollapsed, isTrue);
    expect(
      editor.controller.selection.extentOffset,
      editor.controller.document.length - 1,
    );
  });

  testWidgets('blank surface click preserves draft for continued input', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'abc');
    await pumpUi(tester);
    final editor = quickEditor(tester);
    editor.focusNode.unfocus();
    await tester.pump();

    final surfaceRect = tester.getRect(
      find.byKey(const Key('quick-editor-surface')),
    );
    await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.bottom - 16));
    await pumpUi(tester);
    insertQuickTextAtCaret(tester, 'def');

    expect(editor.focusNode.hasFocus, isTrue);
    expect(quickDocument(tester).toPlainText(), 'abcdef\n');
  });

  testWidgets('surface listener preserves precise Quill caret clicks', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'hello beautiful world');
    await pumpUi(tester);
    final editor = quickEditor(tester);
    final rawEditor = tester.state<QuillRawEditorState>(
      find.byType(QuillRawEditor),
    );
    final caretRect = rawEditor.renderEditor.getLocalRectForCaret(
      const TextPosition(offset: 15),
    );
    final caretPosition = rawEditor.renderEditor.localToGlobal(
      caretRect.centerLeft,
    );
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    await pumpUi(tester);
    editor.focusNode.unfocus();
    await tester.pump();

    await tester.tapAt(caretPosition);
    await pumpUi(tester);

    expect(editor.focusNode.hasFocus, isTrue);
    expect(editor.controller.selection.extentOffset, 15);
  });

  testWidgets('Esc discards text and hides without creating an item', (
    tester,
  ) async {
    await pumpApp(tester);
    enterQuickText(tester, 'temporary');

    await pressKey(tester, LogicalKeyboardKey.escape);

    expect(await db.select(db.items).get(), isEmpty);
    expect(window.hideCalls, 1);
    expect(quickDocument(tester).toPlainText(), '\n');
    expect(
      tester.widget<IconButton>(find.byKey(const Key('quick-close'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('Esc removes staged image attachment before hiding', (
    tester,
  ) async {
    picker.image = imageData('temporary.png');
    await pumpApp(tester);
    await tapInsertImage(tester);
    final attachment = await db.select(db.attachments).getSingle();
    final file = await tester.runAsync(
      () => attachments.resolveAttachmentFile(attachment.id),
    );
    expect(await tester.runAsync(() => file!.exists()), isTrue);

    await pressKey(tester, LogicalKeyboardKey.escape);
    await waitForAttachmentCleanup(tester, db);

    expect(await db.select(db.items).get(), isEmpty);
    expect(find.text('Could not discard this capture.'), findsNothing);
    expect(window.hideCalls, 1);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect(await tester.runAsync(() => file!.exists()), isFalse);
  });

  testWidgets('Ctrl+Enter mode uses Enter for newline and chord for submit', (
    tester,
  ) async {
    await settings.changeSubmitMode(QuickCaptureSubmitMode.controlEnter);
    await pumpApp(tester);
    enterQuickText(tester, 'line one');

    await pressKey(tester, LogicalKeyboardKey.enter);
    expect(await db.select(db.items).get(), isEmpty);
    expect(quickDocument(tester).toPlainText(), contains('\n\n'));

    await pressKey(tester, LogicalKeyboardKey.enter, control: true);
    expect(await db.select(db.items).get(), hasLength(1));
    expect(window.hideCalls, 1);
  });

  testWidgets('Expand auto-saves a meaningful draft then shows Full Stash', (
    tester,
  ) async {
    final channel = await ChannelRepository(db).createRootChannel(name: '展开目标');
    await pumpApp(tester);
    await selectQuickLocation(tester, channel.id);
    enterQuickText(tester, 'keep this draft');

    await tester.tap(find.byKey(const Key('quick-expand')));
    await pumpUi(tester);

    final item = (await db.select(db.items).get()).single;
    expect(item.content, 'keep this draft');
    expect(item.channelId, channel.id);
    expect(quickStash.surface, StashSurface.full);
    expect(window.showFullCalls, 1);
    expect(find.byKey(const Key('root-browser')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
  });
}

Future<void> openQuickLocationPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('quick-location-button')));
  await pumpUi(tester);
  expect(find.byKey(const Key('quick-location-picker')), findsOneWidget);
}

Future<void> selectQuickLocation(WidgetTester tester, String channelId) async {
  await openQuickLocationPicker(tester);
  await tester.tap(find.byKey(Key('quick-location-$channelId')));
  await pumpUi(tester);
  expect(find.byKey(const Key('quick-location-picker')), findsNothing);
}

void enterQuickText(WidgetTester tester, String text) {
  final editor = tester.widget<QuillEditor>(
    find.byKey(const Key('quick-content-field')),
  );
  editor.controller.replaceText(
    0,
    editor.controller.document.length - 1,
    text,
    TextSelection.collapsed(offset: text.length),
  );
  editor.focusNode.requestFocus();
}

Document quickDocument(WidgetTester tester) => tester
    .widget<QuillEditor>(find.byKey(const Key('quick-content-field')))
    .controller
    .document;

QuillEditor quickEditor(WidgetTester tester) =>
    tester.widget<QuillEditor>(find.byKey(const Key('quick-content-field')));

void insertQuickTextAtCaret(WidgetTester tester, String text) {
  final controller = quickEditor(tester).controller;
  final offset = controller.selection.extentOffset;
  controller.replaceText(
    offset,
    0,
    text,
    TextSelection.collapsed(offset: offset + text.length),
  );
}

Future<void> pressKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool control = false,
}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await pumpUi(tester);
}

Future<void> tapInsertImage(WidgetTester tester) async {
  final button = tester.widget<IconButton>(
    find.byKey(const Key('quick-insert-image')),
  );
  await tester.runAsync(() async {
    await (button.onPressed as dynamic)();
  });
  await pumpUi(tester);
}

Future<void> waitForAttachmentCleanup(
  WidgetTester tester,
  AppDatabase db,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if ((await db.select(db.attachments).get()).isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> waitForAttachmentImport(
  WidgetTester tester,
  AppDatabase db,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if ((await db.select(db.attachments).get()).isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 25)),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ImportedImageData imageData(String fileName) => ImportedImageData(
  bytes: Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  ),
  mimeType: 'image/png',
  fileName: fileName,
);

Future<void> _deleteDirectoryWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

class _FakeWindow implements DesktopWindowService {
  final Set<WindowFocusListener> _focusListeners = {};
  bool visible = true;
  bool focused = true;
  int focusCalls = 0;
  int hideCalls = 0;
  int showFullCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<bool> isFocused() async => focused;

  @override
  Future<void> focus() async {
    focusCalls++;
    focused = true;
    emitFocus(true);
  }

  @override
  Future<void> showQuick() async {
    visible = true;
    focused = true;
    emitFocus(true);
  }

  @override
  Future<void> showQuickChannel() => showQuick();

  @override
  Future<void> hideQuick() async {
    visible = false;
    focused = false;
    hideCalls++;
    emitFocus(false);
  }

  @override
  Future<void> showFull() async {
    visible = true;
    focused = true;
    showFullCalls++;
    emitFocus(true);
  }

  @override
  Future<void> hide() => hideQuick();

  @override
  Future<void> setCloseHandler(WindowCloseHandler? handler) async {}

  @override
  Future<void> destroy() async {}

  @override
  void dispose() {}

  @override
  void addFocusListener(WindowFocusListener listener) {
    _focusListeners.add(listener);
  }

  @override
  void removeFocusListener(WindowFocusListener listener) {
    _focusListeners.remove(listener);
  }

  void emitFocus(bool isFocused) {
    focused = isFocused;
    for (final listener in Set<WindowFocusListener>.of(_focusListeners)) {
      listener(isFocused);
    }
  }
}

class _MemoryStore implements QuickStashPreferenceStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

class _FakeImagePicker implements ImagePickerGateway {
  ImportedImageData? image;
  bool dropFocusOnPick = false;
  void Function()? onFocusDropped;

  @override
  Future<ImportedImageData?> pickImage() async {
    if (dropFocusOnPick) {
      FocusManager.instance.primaryFocus?.unfocus();
      onFocusDropped?.call();
    }
    await Future<void>.delayed(Duration.zero);
    return image;
  }
}

class _FakeFilePicker implements FilePickerGateway {
  List<ImportedFileData> files = const [];

  @override
  Future<List<ImportedFileData>> pickFiles() async => files;
}

class _FakeClipboard implements ClipboardReaderGateway {
  ImportedImageData? image;
  String? text;
  bool dropFocusOnRead = false;
  void Function()? onFocusDropped;

  @override
  Future<ImportedImageData?> readImage() async {
    if (dropFocusOnRead) {
      FocusManager.instance.primaryFocus?.unfocus();
      onFocusDropped?.call();
    }
    await Future<void>.delayed(Duration.zero);
    return image;
  }

  @override
  Future<String?> readPlainText() async {
    if (dropFocusOnRead) {
      FocusManager.instance.primaryFocus?.unfocus();
      onFocusDropped?.call();
    }
    await Future<void>.delayed(Duration.zero);
    return text;
  }
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> setString(String key, String value) async {}
}

class _FailingItemRepository extends ItemRepository {
  _FailingItemRepository(super.database);

  @override
  Future<Item> createItem({
    String? id,
    String? title,
    String content = '',
    String? note,
    List<String> tags = const [],
    bool isPinned = false,
    String? channelId,
    ItemDocumentSnapshot? document,
  }) => Future<Item>.error(StateError('simulated save failure'));
}
