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
import 'package:stash/features/attachments/data/image_import_sources.dart';
import 'package:stash/features/attachments/presentation/image_drop_region.dart';
import 'package:stash/features/items/data/item_document_codec.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late Directory supportDirectory;
  late AttachmentRepository attachments;
  late _FakeImagePicker picker;
  late _FakeClipboard clipboard;
  var cleanupRegistered = false;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp(
      'stash-editor-test-',
    );
    attachments = AttachmentRepository(
      db,
      supportDirectory: () async => supportDirectory,
    );
    picker = _FakeImagePicker();
    clipboard = _FakeClipboard();
    cleanupRegistered = false;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    if (!cleanupRegistered) {
      cleanupRegistered = true;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await db.close();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        if (await supportDirectory.exists()) {
          await _deleteDirectoryWithRetry(supportDirectory);
        }
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          attachmentRepositoryProvider.overrideWithValue(attachments),
          imagePickerProvider.overrideWithValue(picker),
          clipboardReaderProvider.overrideWithValue(clipboard),
          appearanceRepositoryProvider.overrideWithValue(
            AppearanceRepository(_MemoryAppearancePreferences()),
          ),
        ],
        child: const StashApp(),
      ),
    );
    await pumpUi(tester);
  }

  testWidgets('editor keeps metadata secondary and reveals formatting', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);

    expect(find.byKey(const Key('title-field')), findsOneWidget);
    expect(find.byKey(const Key('content-field')), findsOneWidget);
    expect(
      find.byKey(const Key('full-editor-image-drop-region')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('details-section')), findsOneWidget);
    expect(find.byKey(const Key('note-field')), findsNothing);
    expect(find.byType(QuillSimpleToolbar), findsNothing);

    await tester.tap(find.byKey(const Key('formatting-toggle')));
    await tester.pump();
    expect(find.byType(QuillSimpleToolbar), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('details-section')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('details-section')));
    await pumpUi(tester);
    expect(find.byKey(const Key('note-field')), findsOneWidget);
    expect(find.byKey(const Key('tags-field')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('fallback image picker saves image-only item across relaunch', (
    tester,
  ) async {
    picker.image = _imageData('picked.png');
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);
    await pressInsertImage(tester);

    expect(picker.calls, 1);
    final attachmentRow = await db.select(db.attachments).getSingle();
    expect(
      find.byKey(Key('attachment-image-${attachmentRow.id}')),
      findsOneWidget,
    );
    expect(_saveButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('save-item-button')));
    await pumpUi(tester);

    final item = await db.select(db.items).getSingle();
    expect(item.content, isEmpty);
    expect(item.documentJson, isNotNull);
    expect(item.documentJson, contains(attachmentRow.id));
    expect(
      item.documentJson,
      isNot(contains(base64Encode(_imageData('x').bytes))),
    );
    expect(find.byKey(Key('item-thumbnail-${item.id}')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(Key('item-thumbnail-${item.id}'))),
      const Size.square(80),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await pumpApp(tester);
    await tester.tap(find.byKey(Key('item-preview-${item.id}')));
    await pumpUi(tester);
    expect(find.byKey(const Key('document-view')), findsOneWidget);
    expect(
      find.byKey(Key('attachment-image-${attachmentRow.id}')),
      findsOneWidget,
    );
    await pumpUi(tester);
    expect(
      find.byKey(Key('attachment-drag-source-${attachmentRow.id}')),
      findsOneWidget,
    );
    final display = tester.widget<ConstrainedBox>(
      find.byKey(Key('attachment-display-${attachmentRow.id}')),
    );
    expect(display.constraints.maxWidth, 420);
    expect(display.constraints.maxHeight, 340);
    await disposeApp(tester);
  });

  testWidgets('clipboard image is preferred over clipboard text', (
    tester,
  ) async {
    clipboard
      ..image = _imageData('clipboard.png')
      ..text = 'must not be inserted';
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);

    await pasteShortcut(tester);
    expect(clipboard.imageReads, 1);
    expect(clipboard.textReads, 0);
    await waitForAttachment(tester, db);

    final row = await db.select(db.attachments).getSingle();
    expect(find.byKey(Key('attachment-image-${row.id}')), findsOneWidget);
    final editor = tester.widget<QuillEditor>(
      find.byKey(const Key('content-field')),
    );
    final snapshot = const ItemDocumentCodec().snapshot(
      editor.controller.document,
    );
    expect(snapshot.imageAttachmentIds, contains(row.id));
    expect(snapshot.plainText, isEmpty);
    await disposeApp(tester);
  });

  testWidgets('clipboard text falls back to normal document insertion', (
    tester,
  ) async {
    clipboard.text = 'pasted normally';
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);

    await pasteShortcut(tester);

    expect(clipboard.imageReads, 1);
    expect(clipboard.textReads, 1);
    expect(await db.select(db.attachments).get(), isEmpty);
    final editor = tester.widget<QuillEditor>(
      find.byKey(const Key('content-field')),
    );
    expect(
      editor.controller.document.toPlainText(),
      contains('pasted normally'),
    );
    await disposeApp(tester);
  });

  testWidgets('dropped text inserts at the caret and focuses the editor', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('new-item-button')));
    await pumpUi(tester);
    final editor = tester.widget<QuillEditor>(
      find.byKey(const Key('content-field')),
    );
    editor.controller.replaceText(
      0,
      editor.controller.document.length - 1,
      'hello world',
      const TextSelection.collapsed(offset: 11),
    );
    editor.controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    final dropRegion = tester.widget<ImageDropRegion>(
      find.byKey(const Key('full-editor-image-drop-region')),
    );

    await Future<void>.sync(() => dropRegion.onTextDropped!(' dropped'));
    await tester.pump();

    expect(editor.controller.document.toPlainText(), 'hello dropped world\n');
    expect(editor.focusNode.hasFocus, isTrue);
    await disposeApp(tester);
  });
}

class _FakeImagePicker implements ImagePickerGateway {
  ImportedImageData? image;
  int calls = 0;

  @override
  Future<ImportedImageData?> pickImage() async {
    calls++;
    return image;
  }
}

class _FakeClipboard implements ClipboardReaderGateway {
  ImportedImageData? image;
  String? text;
  int imageReads = 0;
  int textReads = 0;

  @override
  Future<ImportedImageData?> readImage() async {
    imageReads++;
    return image;
  }

  @override
  Future<String?> readPlainText() async {
    textReads++;
    return text;
  }
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> setString(String key, String value) async {}
}

ImportedImageData _imageData(String fileName) => ImportedImageData(
  bytes: Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  ),
  mimeType: 'image/png',
  fileName: fileName,
);

TextButton _saveButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(const Key('save-item-button')));

Future<void> pasteShortcut(WidgetTester tester) async {
  tester
      .widget<QuillEditor>(find.byKey(const Key('content-field')))
      .focusNode
      .requestFocus();
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await pumpUi(tester);
}

Future<void> pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> pressInsertImage(WidgetTester tester, {bool settle = true}) async {
  final button = tester.widget<IconButton>(
    find.byKey(const Key('insert-image-button')),
  );
  await tester.runAsync(() async {
    await (button.onPressed as dynamic)();
  });
  if (settle) await pumpUi(tester);
}

Future<void> waitForAttachment(WidgetTester tester, AppDatabase db) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    if ((await db.select(db.attachments).get()).isNotEmpty) {
      await pumpUi(tester);
      return;
    }
  }
}

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

Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
}
