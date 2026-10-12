import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/attachments/data/file_attachment_ingestor.dart';
import 'package:stash/features/attachments/data/image_attachment_ingestor.dart';
import 'package:stash/features/attachments/data/image_import_sources.dart';
import 'package:stash/features/attachments/presentation/stash_image_drag_source.dart';
import 'package:stash/features/items/data/item_repository.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late Directory supportDirectory;
  late AttachmentRepository attachments;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp('stash-test-');
    attachments = AttachmentRepository(db, storageRoot: supportDirectory);
  });

  tearDown(() async {
    await db.close();
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test(
    'image import stores bytes in managed storage and relative metadata',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final attachment = await attachments.importImage(
        id: 'stable-id',
        itemId: 'future-item',
        bytes: bytes,
        mimeType: 'image/png',
        originalFileName: 'shot.png',
      );

      expect(attachment.id, 'stable-id');
      expect(path.isAbsolute(attachment.relativePath), isFalse);
      expect(
        attachment.relativePath,
        path.join('attachments', 'stable-id.png'),
      );
      final file = await attachments.resolveAttachmentFile(attachment.id);
      expect(await file!.readAsBytes(), bytes);
      final row = await db.select(db.attachments).getSingle();
      expect(row.relativePath, attachment.relativePath);
      expect(row.byteSize, bytes.length);
    },
  );

  test('staged cleanup removes only requested metadata and file', () async {
    final attachment = await attachments.importImage(
      itemId: 'future-item',
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );
    final file = await attachments.resolveAttachmentFile(attachment.id);

    await attachments.cleanupStagedAttachments([attachment.id]);

    expect(await file!.exists(), isFalse);
    expect(await db.select(db.attachments).get(), isEmpty);
  });

  test(
    'imports PDF and DOCX with streamed copies and relative paths',
    () async {
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'stash-sources-',
      );
      addTearDown(() async {
        if (await sourceDirectory.exists()) {
          await sourceDirectory.delete(recursive: true);
        }
      });
      final pdf = File(path.join(sourceDirectory.path, 'report.pdf'));
      final docx = File(path.join(sourceDirectory.path, 'notes.docx'));
      await pdf.writeAsBytes([1, 2, 3]);
      await docx.writeAsBytes([4, 5]);

      final first = await attachments.importFile(
        id: 'pdf-id',
        itemId: 'future-item',
        sourceFile: pdf,
      );
      final second = await attachments.importFile(
        id: 'docx-id',
        itemId: 'future-item',
        sourceFile: docx,
      );

      expect(first.mimeType, 'application/pdf');
      expect(first.relativePath, path.join('attachments', 'pdf-id.pdf'));
      expect(second.mimeType, contains('wordprocessingml'));
      expect(second.relativePath, path.join('attachments', 'docx-id.docx'));
      expect(await pdf.readAsBytes(), [1, 2, 3]);
      expect(await docx.readAsBytes(), [4, 5]);
    },
  );

  test('unknown extension is preserved with octet-stream fallback', () async {
    final source = File(path.join(supportDirectory.path, 'source.weird'));
    await source.writeAsBytes([8, 9]);

    final attachment = await attachments.importFile(
      id: 'unknown-id',
      itemId: 'future-item',
      sourceFile: source,
      originalFileName: r'unsafe\folder\payload.weird',
    );

    expect(attachment.originalFileName, 'payload.weird');
    expect(attachment.mimeType, 'application/octet-stream');
    expect(
      attachment.relativePath,
      path.join('attachments', 'unknown-id.weird'),
    );
  });

  test('same original filename twice never collides', () async {
    final firstSource = File(path.join(supportDirectory.path, 'first.pdf'));
    final secondSource = File(path.join(supportDirectory.path, 'second.pdf'));
    await firstSource.writeAsBytes([1]);
    await secondSource.writeAsBytes([2]);

    final first = await attachments.importFile(
      itemId: 'future-item',
      sourceFile: firstSource,
      originalFileName: 'report.pdf',
    );
    final second = await attachments.importFile(
      itemId: 'future-item',
      sourceFile: secondSource,
      originalFileName: 'report.pdf',
    );

    expect(first.originalFileName, second.originalFileName);
    expect(first.relativePath, isNot(second.relativePath));
    expect(
      await (await attachments.resolveAttachmentFile(first.id))!.readAsBytes(),
      [1],
    );
    expect(
      await (await attachments.resolveAttachmentFile(second.id))!.readAsBytes(),
      [2],
    );
  });

  test('copy failure leaves no managed file or metadata', () async {
    final missing = File(path.join(supportDirectory.path, 'missing.pdf'));

    await expectLater(
      attachments.importFile(itemId: 'future-item', sourceFile: missing),
      throwsA(isA<FileSystemException>()),
    );

    expect(await db.select(db.attachments).get(), isEmpty);
    final managed = Directory(path.join(supportDirectory.path, 'attachments'));
    expect(await managed.exists(), isFalse);
  });

  test('DB insertion failure removes the copied managed file', () async {
    final source = File(path.join(supportDirectory.path, 'trigger.pdf'));
    await source.writeAsBytes([1, 2, 3]);
    await db.customStatement('''
      CREATE TRIGGER reject_attachment
      BEFORE INSERT ON attachments
      BEGIN
        SELECT RAISE(ABORT, 'injected failure');
      END;
    ''');

    await expectLater(
      attachments.importFile(
        id: 'rejected-id',
        itemId: 'future-item',
        sourceFile: source,
      ),
      throwsA(anything),
    );

    expect(await db.select(db.attachments).get(), isEmpty);
    expect(
      await File(
        path.join(supportDirectory.path, 'attachments', 'rejected-id.pdf'),
      ).exists(),
      isFalse,
    );
    expect(await source.exists(), isTrue);
  });

  test('stream import writes chunks without a whole-file byte value', () async {
    final attachment = await attachments.importFileStream(
      id: 'stream-id',
      itemId: 'future-item',
      stream: Stream<List<int>>.fromIterable([
        [1, 2],
        [3],
        [4, 5],
      ]),
      originalFileName: 'archive.zip',
    );

    expect(attachment.byteSize, 5);
    expect(attachment.mimeType, 'application/zip');
    expect(
      await (await attachments.resolveAttachmentFile(attachment.id))!
          .readAsBytes(),
      [1, 2, 3, 4, 5],
    );
  });

  test(
    'file ingestor rolls back a partially failed multi-file batch',
    () async {
      final valid = File(path.join(supportDirectory.path, 'valid.pdf'));
      final missing = File(path.join(supportDirectory.path, 'missing.docx'));
      await valid.writeAsBytes([1]);
      final ingestor = FileAttachmentIngestor(attachments);

      await expectLater(
        ingestor.importFiles(
          itemId: 'future-item',
          files: [
            ImportedFileData.localFile(valid, fileName: 'valid.pdf'),
            ImportedFileData.localFile(missing, fileName: 'missing.docx'),
          ],
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await db.select(db.attachments).get(), isEmpty);
      final managed = Directory(
        path.join(supportDirectory.path, 'attachments'),
      );
      expect(
        await managed.list().where((entry) => entry is File).toList(),
        isEmpty,
      );
    },
  );

  test('drag item exposes a real file and image representation', () async {
    final attachment = await attachments.importImage(
      id: 'drag-image',
      itemId: 'item',
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
      originalFileName: 'picture.png',
    );

    final item = await StashImageDragItemFactory(attachments)
        .create(attachment.id);

    expect(item, isNotNull);
    expect(item!.suggestedName, 'picture.png');
    expect(item.data, hasLength(2));
    expect(item.localData, {'stashAttachmentId': attachment.id});
  });

  test('drag item is unavailable when its managed file is missing', () async {
    final item = await StashImageDragItemFactory(attachments).create('missing');

    expect(item, isNull);
  });

  test('generic drag item exposes a file URI without image bytes', () async {
    final source = File(path.join(supportDirectory.path, 'paper.pdf'));
    await source.writeAsBytes([1, 2, 3]);
    final attachment = await attachments.importFile(
      id: 'drag-file',
      itemId: 'item',
      sourceFile: source,
    );

    final item = await StashAttachmentDragItemFactory(attachments)
        .create(attachment.id);

    expect(item, isNotNull);
    expect(item!.suggestedName, 'paper.pdf');
    expect(item.data, hasLength(1));
    expect(item.localData, {'stashAttachmentId': attachment.id});
  });

  test('image ingestor imports multiple dropped images in order', () async {
    final ingestor = ImageAttachmentIngestor(attachments);
    final imported = await ingestor.importImages(
      itemId: 'future-item',
      images: [
        ImportedImageData(
          bytes: Uint8List.fromList([1, 2]),
          mimeType: 'image/png',
          fileName: 'first.png',
        ),
        ImportedImageData(
          bytes: Uint8List.fromList([3, 4]),
          mimeType: 'image/jpeg',
          fileName: 'second.jpg',
        ),
      ],
    );

    expect(imported, hasLength(2));
    expect(imported.map((value) => value.originalFileName), [
      'first.png',
      'second.jpg',
    ]);
    expect(await db.select(db.attachments).get(), hasLength(2));
  });

  test('image ingestor rolls back a partially failed batch', () async {
    final ingestor = ImageAttachmentIngestor(attachments);

    await expectLater(
      ingestor.importImages(
        itemId: 'future-item',
        images: [
          ImportedImageData(
            bytes: Uint8List.fromList([1]),
            mimeType: 'image/png',
            fileName: 'first.png',
          ),
          ImportedImageData(
            bytes: Uint8List.fromList([2]),
            mimeType: 'application/octet-stream',
            fileName: 'not-an-image.txt',
          ),
        ],
      ),
      throwsArgumentError,
    );

    expect(await db.select(db.attachments).get(), isEmpty);
  });

  test(
    'orphan cleanup retains attachments owned by tombstoned Items',
    () async {
      final items = ItemRepository(db);
      final item = await items.createItem(id: 'item', content: 'body');
      await items.softDeleteItem(item.id);
      final attachment = await attachments.importImage(
        itemId: item.id,
        bytes: Uint8List.fromList([1]),
        mimeType: 'image/png',
      );

      final removed = await attachments.cleanupOrphans(
        olderThan: DateTime.now().add(const Duration(days: 1)),
      );

      expect(removed, 0);
      expect(await attachments.resolveAttachmentFile(attachment.id), isNotNull);
    },
  );
}
