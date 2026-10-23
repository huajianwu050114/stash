import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';

import 'test_database.dart';

void main() {
  const codec = ItemDocumentCodec();
  late AppDatabase db;
  late Directory storage;
  late AttachmentRepository attachments;
  late ItemRepository items;

  setUp(() async {
    db = createInMemoryDatabase();
    storage = await Directory.systemTemp.createTemp('stash-sync-s1-');
    attachments = AttachmentRepository(db, storageRoot: storage);
    items = ItemRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (await storage.exists()) await storage.delete(recursive: true);
  });

  ItemDocumentSnapshot document(String text, Iterable<String> ids) {
    final operations = <Map<String, Object?>>[];
    if (text.isNotEmpty) operations.add({'insert': text});
    for (final id in ids) {
      operations.add({
        'insert': BlockEmbed.custom(StashFileEmbed(id)).toJson(),
      });
    }
    operations.add({'insert': '\n'});
    return codec.snapshot(Document.fromJson(operations));
  }

  Future<List<SyncOutboxEntry>> attachmentMutations() => (db.select(
    db.syncOutbox,
  )..where((row) => row.entityType.equals('attachment'))).get();

  test('staged import and cancellation never enqueue sync', () async {
    final staged = await attachments.importImage(
      id: 'staged',
      itemId: 'future-item',
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
    );

    expect(await attachmentMutations(), isEmpty);
    final file = await attachments.resolveAttachmentFile(staged.id);
    await attachments.cleanupStagedAttachments([staged.id]);

    expect(await attachmentMutations(), isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect(await file!.exists(), isFalse);
  });

  test(
    'committed attachment lifecycle is sync-aware and retains blobs',
    () async {
      final first = await attachments.importImage(
        id: 'first',
        itemId: 'item',
        bytes: Uint8List.fromList([1]),
        mimeType: 'image/png',
      );
      final firstFile = await attachments.resolveAttachmentFile(first.id);

      await items.createItem(
        id: 'item',
        document: document('before', [first.id]),
      );
      var mutations = await attachmentMutations();
      expect(mutations.map((entry) => entry.entityId), [first.id]);
      expect(mutations.single.op, 'upsert');

      await db.delete(db.syncOutbox).go();
      await (db.update(db.attachments)..where((row) => row.id.equals(first.id)))
          .write(const AttachmentsCompanion(serverRevision: Value(5)));
      final second = await attachments.importImage(
        id: 'second',
        itemId: 'item',
        bytes: Uint8List.fromList([2]),
        mimeType: 'image/png',
      );

      await items.updateItem(
        'item',
        document: document('with second', [first.id, second.id]),
      );
      mutations = await attachmentMutations();
      expect(mutations.map((entry) => entry.entityId), [second.id]);
      expect(mutations.single.op, 'upsert');

      final secondMutationId = mutations.single.mutationId;
      await items.updateItem(
        'item',
        document: document('text only changed', [first.id, second.id]),
      );
      mutations = await attachmentMutations();
      expect(mutations, hasLength(1));
      expect(mutations.single.entityId, second.id);
      expect(mutations.single.mutationId, secondMutationId);

      await db.delete(db.syncOutbox).go();
      await items.updateItem(
        'item',
        document: document('first removed', [second.id]),
      );
      final firstRecord = await (db.select(
        db.attachments,
      )..where((row) => row.id.equals(first.id))).getSingle();
      expect(firstRecord.deletedAt, isNotNull);
      mutations = await attachmentMutations();
      expect(mutations.single.entityId, first.id);
      expect(mutations.single.op, 'delete');
      expect(mutations.single.baseRevision, 5);
      expect(await firstFile!.exists(), isTrue);

      await items.softDeleteItem('item');
      final secondRecord = await (db.select(
        db.attachments,
      )..where((row) => row.id.equals(second.id))).getSingle();
      expect(secondRecord.deletedAt, isNull);
      await items.restoreItem('item');
      expect(await attachments.resolveAttachmentFile(second.id), isNotNull);
    },
  );

  test('documents cannot claim another Item attachment', () async {
    await attachments.importImage(
      id: 'foreign',
      itemId: 'owner',
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );

    await expectLater(
      items.createItem(id: 'thief', document: document('', ['foreign'])),
      throwsStateError,
    );
    expect(await db.select(db.items).get(), isEmpty);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
  });
}
