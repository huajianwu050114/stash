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
  late _FakeClipboard clipboard;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp(
      'stash-quick-test-',
    );
    attachments = AttachmentRepository(
      db,
      supportDirectory: () async => supportDirectory,
    );
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
    clipboard = _FakeClipboard();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(Duration.zero);
      await db.close();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      if (await supportDirectory.exists()) {
        await _deleteDirectoryWithRetry(supportDirectory);
      }
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          attachmentRepositoryProvider.overrideWithValue(attachments),
          imagePickerProvider.overrideWithValue(picker),
          clipboardReaderProvider.overrideWithValue(clipboard),
          quickStashControllerProvider.overrideWithValue(quickStash),
          quickStashSettingsControllerProvider.overrideWithValue(settings),
          appearanceRepositoryProvider.overrideWithValue(
            AppearanceRepository(_MemoryAppearancePreferences()),
          ),
        ],
        child: const StashApp(),
      ),
    );
    await pumpUi(tester);
    expect(find.byKey(const Key('quick-content-field')), findsOneWidget);
    expect(find.byKey(const Key('quick-image-drop-region')), findsOneWidget);
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
    expect(find.text('Add text or an image before saving.'), findsOneWidget);
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
    await pumpApp(tester);
    enterQuickText(tester, 'keep this draft');

    await tester.tap(find.byKey(const Key('quick-expand')));
    await pumpUi(tester);

    expect((await db.select(db.items).get()).single.content, 'keep this draft');
    expect(quickStash.surface, StashSurface.full);
    expect(window.showFullCalls, 1);
    expect(find.byKey(const Key('root-browser')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
  });
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
