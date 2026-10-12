import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/attachments/presentation/stash_file_embed_builder.dart';
import 'package:stash/platform/attachment_file_actions/attachment_file_actions.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late Directory supportDirectory;
  late AttachmentRepository attachments;
  late _FakeFileActions actions;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp(
      'stash-card-test-',
    );
    attachments = AttachmentRepository(db, storageRoot: supportDirectory);
    actions = _FakeFileActions();
  });

  tearDown(() async {
    await db.close();
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  Future<void> pumpCard(WidgetTester tester, String attachmentId) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StashFileCard(
            attachmentId: attachmentId,
            repository: attachments,
            fileActions: actions,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('file card shows PDF filename, type, human size, and icon', (
    tester,
  ) async {
    final source = File(path.join(supportDirectory.path, 'paper.pdf'));
    source.writeAsBytesSync(List<int>.filled(2150400, 1));
    final attachment = (await tester.runAsync(
      () => attachments.importFile(
        itemId: 'item',
        sourceFile: source,
        originalFileName: 'attention_is_all_you_need.pdf',
      ),
    ))!;

    await pumpCard(tester, attachment.id);

    expect(find.text('attention_is_all_you_need.pdf'), findsOneWidget);
    expect(find.text('PDF · 2.1 MB'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    await tester.tap(find.text('attention_is_all_you_need.pdf'));
    await tester.pump();
    expect(actions.opened?.path, endsWith('${attachment.id}.pdf'));
  });

  testWidgets('unknown file uses generic fallback', (tester) async {
    final source = File(path.join(supportDirectory.path, 'payload.odd'));
    source.writeAsBytesSync([1, 2]);
    final attachment = (await tester.runAsync(
      () => attachments.importFile(itemId: 'item', sourceFile: source),
    ))!;

    await pumpCard(tester, attachment.id);

    expect(find.text('payload.odd'), findsOneWidget);
    expect(find.text('ODD · 2 B'), findsOneWidget);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
  });

  testWidgets('missing managed file remains explicit and readable', (
    tester,
  ) async {
    final source = File(path.join(supportDirectory.path, 'missing.pdf'));
    source.writeAsBytesSync([1]);
    final attachment = (await tester.runAsync(
      () => attachments.importFile(
        itemId: 'item',
        sourceFile: source,
        originalFileName: 'report.pdf',
      ),
    ))!;
    final managed = await tester.runAsync(
      () => attachments.resolveAttachmentFile(attachment.id),
    );
    managed!.deleteSync();

    await pumpCard(tester, attachment.id);

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('File unavailable'), findsOneWidget);
    expect(actions.opened, isNull);
  });

  test('human file-size formatter covers KB, MB, and GB', () {
    expect(formatAttachmentByteSize(842 * 1024), '842 KB');
    expect(formatAttachmentByteSize(21 * 1024 * 1024 ~/ 10), '2.1 MB');
    expect(formatAttachmentByteSize(13 * 1024 * 1024 * 1024 ~/ 10), '1.3 GB');
  });
}

class _FakeFileActions implements AttachmentFileActions {
  File? opened;
  File? shown;

  @override
  bool get canShowInFolder => true;

  @override
  Future<void> open(File file) async {
    opened = file;
  }

  @override
  Future<void> showInFolder(File file) async {
    shown = file;
  }
}
