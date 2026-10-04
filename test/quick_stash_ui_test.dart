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

Future<void> pressKey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool control = false,
}) async {
  final editor = tester.widget<QuillEditor>(
    find.byKey(const Key('quick-content-field')),
  );
  editor.focusNode.requestFocus();
  await tester.pump();
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
  bool visible = true;
  int hideCalls = 0;
  int showFullCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> showQuick() async => visible = true;

  @override
  Future<void> hideQuick() async {
    visible = false;
    hideCalls++;
  }

  @override
  Future<void> showFull() async {
    visible = true;
    showFullCalls++;
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

  @override
  Future<ImportedImageData?> pickImage() async => image;
}

class _FakeClipboard implements ClipboardReaderGateway {
  ImportedImageData? image;
  String? text;

  @override
  Future<ImportedImageData?> readImage() async => image;

  @override
  Future<String?> readPlainText() async => text;
}

class _MemoryAppearancePreferences implements AppearancePreferences {
  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> setString(String key, String value) async {}
}
