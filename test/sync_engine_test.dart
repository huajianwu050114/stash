import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/sync/application/sync_engine.dart';
import 'package:stash/features/sync/data/sync_outbox_repository.dart';
import 'package:stash/features/sync/domain/sync_models.dart';
import 'package:stash/features/sync/domain/sync_payloads.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:stash/features/sync/testing/fake_sync_remote.dart';

import 'test_database.dart';

void main() {
  const codec = ItemDocumentCodec();
  final epoch = DateTime.utc(2026);

  ItemDocumentSnapshot document(
    String text, {
    Iterable<String> images = const [],
    Iterable<String> files = const [],
  }) {
    final operations = <Map<String, Object?>>[];
    if (text.isNotEmpty) operations.add({'insert': text});
    for (final id in images) {
      operations.add({
        'insert': BlockEmbed.custom(StashImageEmbed(id)).toJson(),
      });
    }
    for (final id in files) {
      operations.add({
        'insert': BlockEmbed.custom(StashFileEmbed(id)).toJson(),
      });
    }
    operations.add({'insert': '\n'});
    return codec.snapshot(Document.fromJson(operations));
  }

  ItemSyncPayload itemPayload({
    String id = 'item',
    String content = 'body',
    String? channelId,
  }) => ItemSyncPayload(
    id: id,
    title: null,
    content: content,
    note: null,
    channelId: channelId,
    documentJson: null,
    tags: const [],
    isPinned: false,
    createdAt: epoch,
    updatedAt: epoch,
    deletedAt: null,
    serverRevision: 0,
  );

  ChannelSyncPayload channelPayload({
    String id = 'channel',
    String? parentId,
  }) => ChannelSyncPayload(
    id: id,
    name: id,
    parentId: parentId,
    createdAt: epoch,
    updatedAt: epoch,
    deletedAt: null,
    serverRevision: 0,
  );

  group('Fake SyncRemote contract', () {
    test(
      'enforces revisions, dependencies, idempotency, and typed keys',
      () async {
        final remote = FakeSyncRemote();
        final itemKey = const SyncEntityKey(
          type: SyncEntityType.item,
          id: 'same',
        );
        final missingDependency = await remote.push(
          SyncPushRequest(
            entity: itemKey,
            mutationId: 'missing-channel',
            baseRevision: 0,
            operation: SyncOperation.upsert,
            payload: itemPayload(id: 'same', channelId: 'absent').toJson(),
          ),
        );
        expect(missingDependency.outcome, SyncApplyOutcome.invalidDependency);

        final channelKey = const SyncEntityKey(
          type: SyncEntityType.channel,
          id: 'same',
        );
        final channelRequest = SyncPushRequest(
          entity: channelKey,
          mutationId: 'channel-mutation',
          baseRevision: 0,
          operation: SyncOperation.upsert,
          payload: channelPayload(id: 'same').toJson(),
        );
        expect(
          (await remote.push(channelRequest)).outcome,
          SyncApplyOutcome.accepted,
        );

        final itemRequest = SyncPushRequest(
          entity: itemKey,
          mutationId: 'item-mutation',
          baseRevision: 0,
          operation: SyncOperation.upsert,
          payload: itemPayload(id: 'same', channelId: 'same').toJson(),
        );
        final accepted = await remote.push(itemRequest);
        final retried = await remote.push(itemRequest);
        expect(accepted.remoteRevision, 1);
        expect(retried.outcome, SyncApplyOutcome.alreadyApplied);
        expect(retried.remoteRevision, 1);
        expect(remote.changes, hasLength(2));
        expect(remote.entity(channelKey)?.revision, 1);
        expect(remote.entity(itemKey)?.revision, 1);

        final blobBytes = Uint8List.fromList([1]);
        final checksum = sha256.convert(blobBytes).toString();
        await remote.putBlob(
          attachmentId: 'same',
          byteSize: 1,
          sha256: checksum,
          bytes: Stream.value(blobBytes),
        );
        final attachmentKey = const SyncEntityKey(
          type: SyncEntityType.attachment,
          id: 'same',
        );
        final attachmentRequest = SyncPushRequest(
          entity: attachmentKey,
          mutationId: 'attachment-mutation',
          baseRevision: 0,
          operation: SyncOperation.upsert,
          payload: AttachmentSyncPayload(
            id: 'same',
            itemId: 'same',
            mimeType: 'application/octet-stream',
            originalFileName: 'same.bin',
            byteSize: 1,
            sha256: checksum,
            createdAt: epoch,
            deletedAt: null,
            serverRevision: 0,
          ).toJson(),
        );
        expect(
          (await remote.push(attachmentRequest)).outcome,
          SyncApplyOutcome.accepted,
        );
        expect(
          (await remote.push(attachmentRequest)).outcome,
          SyncApplyOutcome.alreadyApplied,
        );
        expect(remote.entity(attachmentKey)?.revision, 1);
        expect(remote.changes, hasLength(3));

        final divergentBytes = Uint8List.fromList([2]);
        final divergentChecksum = sha256.convert(divergentBytes).toString();
        await remote.putBlob(
          attachmentId: 'same',
          byteSize: 1,
          sha256: divergentChecksum,
          bytes: Stream.value(divergentBytes),
        );
        final rejectedAttachment = await remote.push(
          SyncPushRequest(
            entity: attachmentKey,
            mutationId: 'attachment-stale',
            baseRevision: 0,
            operation: SyncOperation.upsert,
            payload: AttachmentSyncPayload(
              id: 'same',
              itemId: 'same',
              mimeType: 'application/octet-stream',
              originalFileName: 'same.bin',
              byteSize: 1,
              sha256: divergentChecksum,
              createdAt: epoch,
              deletedAt: null,
              serverRevision: 0,
            ).toJson(),
          ),
        );
        expect(rejectedAttachment.outcome, SyncApplyOutcome.conflict);
        final committedBlob = await remote.getBlob('same');
        expect(await committedBlob!.bytes.expand((chunk) => chunk).toList(), [
          1,
        ]);

        final stale = await remote.push(
          SyncPushRequest(
            entity: itemKey,
            mutationId: 'stale',
            baseRevision: 0,
            operation: SyncOperation.upsert,
            payload: itemPayload(id: 'same', content: 'stale').toJson(),
          ),
        );
        expect(stale.outcome, SyncApplyOutcome.conflict);
        expect(remote.entity(itemKey)?.payload['content'], 'body');

        final future = await remote.push(
          SyncPushRequest(
            entity: itemKey,
            mutationId: 'future',
            baseRevision: 3,
            operation: SyncOperation.upsert,
            payload: itemPayload(id: 'same').toJson(),
          ),
        );
        expect(future.outcome, SyncApplyOutcome.invalidDependency);

        final blockedDelete = await remote.push(
          SyncPushRequest(
            entity: channelKey,
            mutationId: 'blocked-delete',
            baseRevision: 1,
            operation: SyncOperation.delete,
            payload: channelPayload(id: 'same').toJson(),
          ),
        );
        expect(blockedDelete.outcome, SyncApplyOutcome.invalidDependency);
      },
    );

    test(
      'rejects child Channel and Item when dependencies are missing',
      () async {
        final remote = FakeSyncRemote();
        final child = await remote.push(
          SyncPushRequest(
            entity: const SyncEntityKey(
              type: SyncEntityType.channel,
              id: 'child',
            ),
            mutationId: 'child',
            baseRevision: 0,
            operation: SyncOperation.upsert,
            payload: channelPayload(id: 'child', parentId: 'parent').toJson(),
          ),
        );
        expect(child.outcome, SyncApplyOutcome.invalidDependency);

        final item = await remote.push(
          SyncPushRequest(
            entity: const SyncEntityKey(
              type: SyncEntityType.item,
              id: 'located',
            ),
            mutationId: 'located',
            baseRevision: 0,
            operation: SyncOperation.upsert,
            payload: itemPayload(id: 'located', channelId: 'missing').toJson(),
          ),
        );
        expect(item.outcome, SyncApplyOutcome.invalidDependency);
      },
    );
  });

  group('two independent devices', () {
    late FakeSyncRemote remote;
    late _Device a;
    late _Device b;

    setUp(() async {
      remote = FakeSyncRemote();
      a = await _Device.create('a', remote);
      b = await _Device.create('b', remote);
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    test(
      'A syncs hierarchy and Item; offline A is reconstructed by B',
      () async {
        await a.channels.createRootChannel(id: 'study', name: '学习');
        await a.channels.createChildChannel(
          id: 'ai',
          name: 'AI',
          parentId: 'study',
        );
        await a.channels.createChildChannel(
          id: 'papers',
          name: '论文',
          parentId: 'ai',
        );
        await a.items.createItem(
          id: 'transformer',
          channelId: 'papers',
          content: 'Transformer',
        );

        final aResult = await a.engine.syncOnce();
        expect(aResult.errors, isEmpty);
        expect(aResult.conflicts, isEmpty);
        expect(remote.changes, hasLength(4));

        final bResult = await b.engine.syncOnce();
        expect(bResult.pulled, 4);
        expect(bResult.cursor, 4);
        final papers = await b.channels.getChannelById('papers');
        final item = await b.items.getItemById('transformer');
        expect(papers?.parentId, 'ai');
        expect(item?.channelId, 'papers');
        expect(item?.content, 'Transformer');
        expect(await b.outbox.readPending(), isEmpty);

        final noOp = await b.engine.syncOnce();
        expect(noOp.pulled, 0);
        expect(noOp.cursor, 4);

        await b.items.updateItem('transformer', content: 'Transformer v2');
        expect((await b.engine.syncOnce()).errors, isEmpty);
        expect(remote.entity(_itemKey('transformer'))?.revision, 2);
        expect((await a.engine.syncOnce()).errors, isEmpty);
        expect(
          (await a.items.getItemById('transformer'))?.content,
          'Transformer v2',
        );
      },
    );

    test(
      'offline divergent edits conflict without overwrite or cursor loss',
      () async {
        await a.items.createItem(id: 'item', content: 'revision 1');
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        final cursorBeforeConflict = await b.cursor();

        await a.items.updateItem('item', content: 'A version');
        await b.items.updateItem('item', content: 'B version');
        await a.engine.syncOnce();
        final bResult = await b.engine.syncOnce();

        expect(bResult.conflicts, hasLength(1));
        expect(bResult.conflicts.single.entity, _itemKey('item'));
        expect(await b.cursor(), cursorBeforeConflict);
        expect((await b.items.getItemById('item'))?.content, 'B version');
        expect(
          remote.entity(_itemKey('item'))?.payload['content'],
          'A version',
        );
        expect(await b.outbox.getPending(_itemKey('item')), isNotNull);
      },
    );

    test('in-flight edit survives acknowledgement and rebases', () async {
      var injected = false;
      final engine = SyncEngine(
        remote,
        database: a.db,
        storageRoot: a.storage,
        beforeApplyPushAck: (mutation, result) async {
          if (!injected && mutation.entity == _itemKey('item')) {
            injected = true;
            await a.items.updateItem('item', content: 'M2');
          }
        },
      );
      await a.items.createItem(id: 'item', content: 'M1');
      final first = await engine.syncOnce();
      expect(first.errors, isEmpty);
      expect(first.conflicts, isEmpty);
      final m2 = await a.outbox.getPending(_itemKey('item'));
      expect(m2, isNotNull);
      expect(m2!.baseRevision, 1);
      expect(await a.revision(_itemKey('item')), 1);

      final second = await a.engine.syncOnce();
      expect(second.errors, isEmpty);
      expect(remote.entity(_itemKey('item'))?.revision, 2);
      expect(remote.entity(_itemKey('item'))?.payload['content'], 'M2');
      expect(await a.outbox.getPending(_itemKey('item')), isNull);
    });

    test(
      'lost acknowledgement retries the same mutation idempotently',
      () async {
        final created = await a.items.createItem(id: 'item', content: 'once');
        final mutation = await a.outbox.getPending(_itemKey('item'));
        final first = await remote.push(
          SyncPushRequest(
            entity: mutation!.entity,
            mutationId: mutation.mutationId,
            baseRevision: mutation.baseRevision,
            operation: mutation.operation,
            payload: ItemSyncPayload(
              id: created.id,
              title: created.title,
              content: created.content,
              note: created.note,
              channelId: created.channelId,
              documentJson: created.documentJson,
              tags: created.tags,
              isPinned: created.isPinned,
              createdAt: created.createdAt,
              updatedAt: created.updatedAt,
              deletedAt: created.deletedAt,
              serverRevision: 0,
            ).toJson(),
          ),
        );
        expect(first.remoteRevision, 1);
        expect(remote.changes, hasLength(1));

        final retry = await a.engine.syncOnce();
        expect(retry.errors, isEmpty);
        expect(remote.changes, hasLength(1));
        expect(remote.entity(_itemKey('item'))?.revision, 1);
        expect(await a.revision(_itemKey('item')), 1);
        expect(await a.outbox.getPending(_itemKey('item')), isNull);
      },
    );

    test(
      'image and generic file blobs transfer with integrity and local paths',
      () async {
        await a.channels.createRootChannel(id: 'papers', name: '论文');
        final imageBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
        final pdfBytes = Uint8List.fromList([37, 80, 68, 70, 45, 1, 2, 3]);
        final image = await a.attachments.importImage(
          id: 'image',
          itemId: 'paper-item',
          bytes: imageBytes,
          mimeType: 'image/png',
          originalFileName: 'figure.png',
        );
        final source = File(path.join(a.storage.path, 'source.pdf'));
        await source.writeAsBytes(pdfBytes);
        final pdf = await a.attachments.importFile(
          id: 'pdf',
          itemId: 'paper-item',
          sourceFile: source,
          originalFileName: 'paper.pdf',
        );
        final originalPdf = await a.attachments.resolveAttachmentFile(pdf.id);
        final customPdf = File(
          path.join(a.storage.path, 'attachments', 'device-a-only-name.pdf'),
        );
        await originalPdf!.rename(customPdf.path);
        await (a.db.update(
          a.db.attachments,
        )..where((row) => row.id.equals(pdf.id))).write(
          const AttachmentsCompanion(
            relativePath: Value('attachments/device-a-only-name.pdf'),
          ),
        );
        await a.items.createItem(
          id: 'paper-item',
          channelId: 'papers',
          document: document(
            'Transformer paper',
            images: [image.id],
            files: [pdf.id],
          ),
        );

        final upload = await a.engine.syncOnce();
        expect(upload.errors, isEmpty);
        expect(remote.hasBlob('image'), isTrue);
        expect(remote.hasBlob('pdf'), isTrue);
        final download = await b.engine.syncOnce();
        expect(download.errors, isEmpty);

        for (final entry in {'image': imageBytes, 'pdf': pdfBytes}.entries) {
          final record = await (b.db.select(
            b.db.attachments,
          )..where((row) => row.id.equals(entry.key))).getSingle();
          final file = File(path.join(b.storage.path, record.relativePath));
          expect(await file.exists(), isTrue);
          expect(await file.readAsBytes(), entry.value);
          expect(record.byteSize, entry.value.length);
          expect(record.sha256, sha256.convert(entry.value).toString());
        }
        final bPdf = await (b.db.select(
          b.db.attachments,
        )..where((row) => row.id.equals('pdf'))).getSingle();
        expect(bPdf.relativePath, isNot('attachments/device-a-only-name.pdf'));
        expect(bPdf.relativePath, contains('pdf'));
      },
    );

    test(
      'Item, Attachment, and Channel tombstones plus restore propagate',
      () async {
        await a.channels.createRootChannel(id: 'channel', name: 'Channel');
        final attachment = await a.attachments.importImage(
          id: 'attachment',
          itemId: 'item',
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'item',
          channelId: 'channel',
          document: document('with image', images: [attachment.id]),
        );
        await a.engine.syncOnce();
        await b.engine.syncOnce();

        await a.items.softDeleteItem('item');
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        expect((await b.items.getItemById('item'))?.isDeleted, isTrue);
        expect(
          (await b.db.select(b.db.attachments).getSingle()).deletedAt,
          isNull,
        );

        await a.items.restoreItem('item');
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        expect((await b.items.getItemById('item'))?.isDeleted, isFalse);

        await a.items.updateItem('item', document: document('without image'));
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        final removed = await b.db.select(b.db.attachments).getSingle();
        expect(removed.deletedAt, isNotNull);
        expect(
          codec
              .snapshot(
                codec.decode(
                  documentJson: (await b.items.getItemById('item'))!
                      .documentJson,
                  legacyText: '',
                ),
              )
              .attachmentIds,
          isEmpty,
        );

        await a.items.moveItem('item', channelId: null);
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        await a.channels.softDeleteChannel('channel');
        await a.engine.syncOnce();
        await b.engine.syncOnce();
        expect((await b.channels.getChannelById('channel'))?.isDeleted, isTrue);
        expect(await b.db.select(b.db.items).get(), hasLength(1));
        expect(await b.db.select(b.db.attachments).get(), hasLength(1));
      },
    );

    test(
      'bootstrap exports committed 0.6 data but skips staged attachments',
      () async {
        await a.channels.createRootChannel(
          id: 'legacy-channel',
          name: 'Legacy',
        );
        final committed = await a.attachments.importImage(
          id: 'committed',
          itemId: 'legacy-item',
          bytes: Uint8List.fromList([9, 8, 7]),
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'legacy-item',
          channelId: 'legacy-channel',
          document: document('legacy', images: [committed.id]),
        );
        await a.items.createItem(id: 'deleted-item', content: 'deleted');
        await a.items.softDeleteItem('deleted-item');
        final removed = await a.attachments.importImage(
          id: 'removed',
          itemId: 'removed-item',
          bytes: Uint8List.fromList([2, 4, 6]),
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'removed-item',
          document: document('', images: [removed.id]),
        );
        await a.items.updateItem('removed-item', document: document('removed'));
        await a.attachments.importImage(
          id: 'staged',
          itemId: 'future-item',
          bytes: Uint8List.fromList([6, 5, 4]),
          mimeType: 'image/png',
        );
        await a.db.delete(a.db.syncOutbox).go();

        await a.engine.bootstrapLocalReplicaForSync();
        final first = await a.outbox.readPending();
        expect(first, hasLength(6));
        expect(
          first.map((mutation) => mutation.entity.id),
          isNot(contains('staged')),
        );
        expect(
          first
              .singleWhere((mutation) => mutation.entity.id == 'deleted-item')
              .operation,
          SyncOperation.delete,
        );
        expect(
          first
              .singleWhere((mutation) => mutation.entity.id == 'removed')
              .operation,
          SyncOperation.delete,
        );
        final mutationIds = {
          for (final mutation in first) mutation.entity: mutation.mutationId,
        };
        await a.engine.bootstrapLocalReplicaForSync();
        final second = await a.outbox.readPending();
        expect(second, hasLength(6));
        expect({
          for (final mutation in second) mutation.entity: mutation.mutationId,
        }, mutationIds);

        expect((await a.engine.syncOnce()).errors, isEmpty);
        expect((await b.engine.syncOnce()).errors, isEmpty);
        expect((await b.items.getItemById('legacy-item'))?.content, 'legacy');
        expect(await b.channels.getChannelById('legacy-channel'), isNotNull);
        expect(
          await (b.db.select(
            b.db.attachments,
          )..where((row) => row.id.equals('committed'))).getSingleOrNull(),
          isNotNull,
        );
        expect(remote.entity(_attachmentKey('staged')), isNull);
        expect((await b.items.getItemById('deleted-item'))?.isDeleted, isTrue);
        expect(
          (await (b.db.select(
            b.db.attachments,
          )..where((row) => row.id.equals('removed'))).getSingle()).deletedAt,
          isNotNull,
        );
      },
    );

    test(
      'push, pull, and blob failures preserve durable local state',
      () async {
        await a.items.createItem(id: 'item', content: 'safe');
        remote.failNextPush = true;
        final failedPush = await a.engine.syncOnce();
        expect(failedPush.errors, isNotEmpty);
        final pending = await a.outbox.getPending(_itemKey('item'));
        expect(pending, isNotNull);
        expect(pending!.retryCount, 1);
        expect((await a.items.getItemById('item'))?.content, 'safe');

        expect((await a.engine.syncOnce()).errors, isEmpty);
        remote.failNextPull = true;
        final cursor = await b.cursor();
        final failedPull = await b.engine.syncOnce();
        expect(failedPull.errors, isNotEmpty);
        expect(await b.cursor(), cursor);

        final blob = await a.attachments.importImage(
          id: 'blob',
          itemId: 'blob-item',
          bytes: Uint8List.fromList([4, 3, 2, 1]),
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'blob-item',
          document: document('', images: [blob.id]),
        );
        remote.failNextBlobUpload = true;
        final failedBlob = await a.engine.syncOnce();
        expect(failedBlob.errors, isNotEmpty);
        expect(await a.outbox.getPending(_attachmentKey('blob')), isNotNull);
        expect(await a.attachments.resolveAttachmentFile('blob'), isNotNull);
      },
    );

    test(
      'missing remote blob blocks metadata application and cursor advancement',
      () async {
        final attachment = await a.attachments.importImage(
          id: 'missing',
          itemId: 'item',
          bytes: Uint8List.fromList([8, 6, 4, 2]),
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'item',
          document: document('', images: [attachment.id]),
        );
        await a.engine.syncOnce();
        remote.removeBlob('missing');

        final result = await b.engine.syncOnce();
        expect(result.errors, isNotEmpty);
        expect(await b.cursor(), 1);
        expect(
          await (b.db.select(
            b.db.attachments,
          )..where((row) => row.id.equals('missing'))).getSingleOrNull(),
          isNull,
        );
      },
    );

    test(
      'corrupt remote blob blocks cursor and never publishes partial data',
      () async {
        final blobBytes = Uint8List.fromList([1, 3, 5, 7]);
        final attachment = await a.attachments.importImage(
          id: 'corrupt',
          itemId: 'item',
          bytes: blobBytes,
          mimeType: 'image/png',
        );
        await a.items.createItem(
          id: 'item',
          document: document('', images: [attachment.id]),
        );
        await a.engine.syncOnce();
        remote.corruptBlob('corrupt');

        final result = await b.engine.syncOnce();
        expect(result.errors, isNotEmpty);
        expect(await b.cursor(), 1); // Item applied; attachment change blocked.
        final target = File(
          path.join(b.storage.path, 'attachments', 'corrupt.png'),
        );
        expect(await target.exists(), isFalse);
        expect(
          await (b.db.select(
            b.db.attachments,
          )..where((row) => row.id.equals('corrupt'))).getSingleOrNull(),
          isNull,
        );
      },
    );
  });
}

SyncEntityKey _itemKey(String id) =>
    SyncEntityKey(type: SyncEntityType.item, id: id);

SyncEntityKey _attachmentKey(String id) =>
    SyncEntityKey(type: SyncEntityType.attachment, id: id);

class _Device {
  _Device._({required this.db, required this.storage, required this.remote})
    : items = ItemRepository(db),
      channels = ChannelRepository(db),
      attachments = AttachmentRepository(db, storageRoot: storage),
      outbox = SyncOutboxRepository(db),
      engine = SyncEngine(remote, database: db, storageRoot: storage);

  static Future<_Device> create(String name, SyncRemote remote) async {
    final storage = await Directory.systemTemp.createTemp(
      'stash-sync-s2-$name-',
    );
    return _Device._(
      db: createInMemoryDatabase(),
      storage: storage,
      remote: remote,
    );
  }

  final AppDatabase db;
  final Directory storage;
  final SyncRemote remote;
  final ItemRepository items;
  final ChannelRepository channels;
  final AttachmentRepository attachments;
  final SyncOutboxRepository outbox;
  final SyncEngine engine;

  Future<int> cursor() async {
    final row = await (db.select(
      db.syncMeta,
    )..where((entry) => entry.key.equals('pull_cursor'))).getSingleOrNull();
    return row == null ? 0 : int.parse(row.value);
  }

  Future<int> revision(SyncEntityKey key) async {
    switch (key.type) {
      case SyncEntityType.item:
        return (await (db.select(
          db.items,
        )..where((row) => row.id.equals(key.id))).getSingle()).serverRevision;
      case SyncEntityType.channel:
        return (await (db.select(
          db.channels,
        )..where((row) => row.id.equals(key.id))).getSingle()).serverRevision;
      case SyncEntityType.attachment:
        return (await (db.select(
          db.attachments,
        )..where((row) => row.id.equals(key.id))).getSingle()).serverRevision;
    }
  }

  Future<void> close() async {
    await db.close();
    if (await storage.exists()) await storage.delete(recursive: true);
  }
}
