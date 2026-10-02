import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/items/data/item_repository.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late Directory supportDirectory;
  late AttachmentRepository attachments;

  setUp(() async {
    db = createInMemoryDatabase();
    supportDirectory = await Directory.systemTemp.createTemp('stash-test-');
    attachments = AttachmentRepository(
      db,
      supportDirectory: () async => supportDirectory,
    );
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
