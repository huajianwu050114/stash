import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';

import 'test_database.dart';

void main() {
  const codec = ItemDocumentCodec();

  test('legacy plain text becomes a usable editor document', () {
    final document = codec.decode(documentJson: null, legacyText: 'legacy');
    expect(document.toPlainText(), 'legacy\n');
    expect(codec.snapshot(document).plainText, 'legacy');
  });

  test('rich document round-trips with formatting and version envelope', () {
    final document = Document.fromJson([
      {
        'insert': 'Bold',
        'attributes': {'bold': true},
      },
      {'insert': '\n'},
    ]);
    final snapshot = codec.snapshot(document);
    final decoded = codec.decode(
      documentJson: snapshot.documentJson,
      legacyText: 'ignored',
    );
    expect(decoded.toDelta().toJson(), document.toDelta().toJson());
    expect(snapshot.documentJson, contains('"version":1'));
    expect(snapshot.documentJson, contains('"format":"quill-delta"'));
  });

  test('image and file snapshots track all attachment kinds', () {
    final image = Document.fromJson([
      {
        'insert': BlockEmbed.custom(const StashImageEmbed('attachment'))
            .toJson(),
      },
      {'insert': '\n'},
    ]);
    final file = Document.fromJson([
      {'insert': BlockEmbed.custom(const StashFileEmbed('file-id')).toJson()},
      {'insert': '\n'},
    ]);
    final mixed = Document.fromJson([
      {'insert': 'notes'},
      {'insert': BlockEmbed.custom(const StashImageEmbed('image-id')).toJson()},
      {'insert': BlockEmbed.custom(const StashFileEmbed('file-one')).toJson()},
      {'insert': BlockEmbed.custom(const StashFileEmbed('file-two')).toJson()},
      {'insert': '\n'},
    ]);
    final imageSnapshot = codec.snapshot(image);
    expect(imageSnapshot.hasMeaningfulBody, isTrue);
    expect(imageSnapshot.imageAttachmentIds, {'attachment'});
    expect(imageSnapshot.fileAttachmentIds, isEmpty);
    final fileSnapshot = codec.snapshot(file);
    expect(fileSnapshot.hasMeaningfulBody, isTrue);
    expect(fileSnapshot.imageAttachmentIds, isEmpty);
    expect(fileSnapshot.fileAttachmentIds, {'file-id'});
    expect(fileSnapshot.attachmentIds, {'file-id'});
    final mixedSnapshot = codec.snapshot(mixed);
    expect(mixedSnapshot.plainText, 'notes');
    expect(mixedSnapshot.imageAttachmentIds, {'image-id'});
    expect(mixedSnapshot.fileAttachmentIds, {'file-one', 'file-two'});
    expect(mixedSnapshot.attachmentIds, {'image-id', 'file-one', 'file-two'});
    expect(codec.snapshot(Document()).hasMeaningfulBody, isFalse);
    expect(
      codec.snapshot(codec.fromPlainText('  \n\t')).hasMeaningfulBody,
      isFalse,
    );
  });

  test('old stash-image document still decodes unchanged', () {
    final original = Document.fromJson([
      {
        'insert': BlockEmbed.custom(const StashImageEmbed('legacy-image'))
            .toJson(),
      },
      {'insert': '\n'},
    ]);
    final encoded = codec.snapshot(original);
    final decoded = codec.decode(
      documentJson: encoded.documentJson,
      legacyText: 'ignored',
    );

    expect(codec.snapshot(decoded).imageAttachmentIds, {'legacy-image'});
    expect(codec.snapshot(decoded).fileAttachmentIds, isEmpty);
  });

  group('document repository persistence', () {
    late AppDatabase db;
    late ItemRepository items;
    late ChannelRepository channels;

    setUp(() {
      db = createInMemoryDatabase();
      items = ItemRepository(db);
      channels = ChannelRepository(db);
    });
    tearDown(() => db.close());

    test(
      'text document updates its plain-text projection atomically',
      () async {
        final first = codec.snapshot(codec.fromPlainText('first'));
        final item = await items.createItem(id: 'item', document: first);
        expect(item.content, 'first');
        expect(item.documentJson, first.documentJson);

        final second = codec.snapshot(codec.fromPlainText('second paragraph'));
        final updated = await items.updateItem(item.id, document: second);
        expect(updated.content, 'second paragraph');
        expect(updated.documentJson, second.documentJson);
        final row = await db.select(db.items).getSingle();
        expect(row.content, 'second paragraph');
        expect(row.documentJson, second.documentJson);
        final outbox = await db.select(db.syncOutbox).getSingle();
        expect(outbox.entityType, 'item');
        expect(outbox.entityId, item.id);
        expect(outbox.op, 'upsert');
      },
    );

    test(
      'attachment-only documents are valid but empty documents are rejected',
      () async {
        final now = DateTime.utc(2026);
        await db
            .into(db.attachments)
            .insert(
              AttachmentsCompanion.insert(
                id: 'image-id',
                itemId: 'image-item',
                mimeType: 'image/png',
                relativePath: 'attachments/image-id.png',
                createdAt: now,
              ),
            );
        final image = Document.fromJson([
          {
            'insert': BlockEmbed.custom(const StashImageEmbed('image-id'))
                .toJson(),
          },
          {'insert': '\n'},
        ]);
        final created = await items.createItem(
          id: 'image-item',
          document: codec.snapshot(image),
        );
        expect(created.content, isEmpty);

        await db
            .into(db.attachments)
            .insert(
              AttachmentsCompanion.insert(
                id: 'file-id',
                itemId: 'file-item',
                mimeType: 'application/pdf',
                relativePath: 'attachments/file-id.pdf',
                createdAt: now,
              ),
            );
        final file = Document.fromJson([
          {
            'insert': BlockEmbed.custom(const StashFileEmbed('file-id'))
                .toJson(),
          },
          {'insert': '\n'},
        ]);
        final fileItem = await items.createItem(
          id: 'file-item',
          document: codec.snapshot(file),
        );
        expect(fileItem.content, isEmpty);

        await expectLater(
          items.createItem(document: codec.snapshot(Document())),
          throwsArgumentError,
        );
        await expectLater(
          items.createItem(
            document: codec.snapshot(codec.fromPlainText('   ')),
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'document edit preserves metadata and channel while clearing title',
      () async {
        final channel = await channels.createRootChannel(
          id: 'channel',
          name: 'Channel',
        );
        final item = await items.createItem(
          title: 'Title',
          note: 'Note',
          tags: ['tag'],
          channelId: channel.id,
          document: codec.snapshot(codec.fromPlainText('before')),
        );

        final updated = await items.updateItem(
          item.id,
          title: const FieldUpdate.set(null),
          document: codec.snapshot(codec.fromPlainText('after')),
        );

        expect(updated.title, isNull);
        expect(updated.note, 'Note');
        expect(updated.tags, ['tag']);
        expect(updated.channelId, channel.id);
        expect(updated.content, 'after');
      },
    );
  });
}
