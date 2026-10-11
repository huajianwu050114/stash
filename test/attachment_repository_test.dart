import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
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
