import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/tags_codec.dart';
import '../../sync/data/sync_outbox_repository.dart';
import '../../sync/domain/sync_models.dart';
import 'item_document_codec.dart';
import '../domain/item.dart';

/// Describes whether an optional field should be left alone or assigned a
/// value (including `null`).
sealed class FieldUpdate<T> {
  const FieldUpdate();

  const factory FieldUpdate.unchanged() = _UnchangedFieldUpdate<T>;

  const factory FieldUpdate.set(T value) = _SetFieldUpdate<T>;

  bool get isChanged;

  T valueOr(T current);
}

final class _UnchangedFieldUpdate<T> extends FieldUpdate<T> {
  const _UnchangedFieldUpdate();

  @override
  bool get isChanged => false;

  @override
  T valueOr(T current) => current;
}

final class _SetFieldUpdate<T> extends FieldUpdate<T> {
  const _SetFieldUpdate(this.value);

  final T value;

  @override
  bool get isChanged => true;

  @override
  T valueOr(T current) => value;
}

/// Local persistence boundary for [Item].
///
/// Every mutating operation writes the item row and its pending sync-outbox
/// mutation inside one SQLite transaction, so a committed change always has
/// its durable pending-mutation state. No operation involves the network.
class ItemRepository {
  ItemRepository(this._db, {SyncOutboxRepository? outbox})
    : _outbox = outbox ?? SyncOutboxRepository(_db);

  final AppDatabase _db;
  final SyncOutboxRepository _outbox;

  static final Uuid _uuid = Uuid();
  static const ItemDocumentCodec _documentCodec = ItemDocumentCodec();

  // --- reads ----------------------------------------------------------------

  /// Returns the item with [id], including tombstoned rows, or null when the
  /// id is unknown.
  Future<Item?> getItemById(String id) async =>
      (await _recordById(id))?.toItem();

  /// Streams the item with [id] (including tombstoned rows), or null while
  /// the id is unknown.
  Stream<Item?> watchItemById(String id) =>
      (_db.select(_db.items)..where((t) => t.id.equals(id)))
          .watchSingleOrNull()
          .map((record) => record?.toItem());

  /// Streams all non-deleted items, newest-updated first.
  Stream<List<Item>> watchActiveItems() =>
      (_db.select(_db.items)
            ..where((t) => t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
          .watch()
          .map((rows) => rows.map((record) => record.toItem()).toList());

  Stream<List<Item>> watchInboxItems() =>
      _watchItems((row) => row.channelId.isNull() & row.deletedAt.isNull());

  Stream<List<Item>> watchItemsInChannel(String channelId) => _watchItems(
    (row) => row.channelId.equals(channelId) & row.deletedAt.isNull(),
  );

  Stream<List<Item>> watchPinnedItems() =>
      _watchItems((row) => row.isPinned.equals(true) & row.deletedAt.isNull());

  // --- mutations ------------------------------------------------------------

  /// Inserts a new item. [id] is generated (UUIDv4) unless supplied, so
  /// callers may pass a client-generated id and keep it stable forever.
  Future<Item> createItem({
    String? id,
    String? title,
    String content = '',
    String? note,
    List<String> tags = const [],
    bool isPinned = false,
    String? channelId,
    ItemDocumentSnapshot? document,
  }) async {
    return _db.transaction(() async {
      await _validateTargetChannel(channelId);
      final savedContent = document == null
          ? _validatedLegacyContent(content)
          : _validatedDocument(document).plainText;
      final itemId = id ?? _uuid.v4();
      final attachmentRecords = await _validatedAttachmentRecords(
        itemId: itemId,
        attachmentIds: document?.attachmentIds ?? const {},
      );
      final now = DateTime.now();
      final item = Item(
        id: itemId,
        title: title,
        content: savedContent,
        note: note,
        channelId: channelId,
        documentJson: document?.documentJson,
        tags: tags,
        isPinned: isPinned,
        createdAt: now,
        updatedAt: now,
      );
      await _db
          .into(_db.items)
          .insert(
            ItemsCompanion.insert(
              id: item.id,
              title: Value(item.title),
              content: item.content,
              note: Value(item.note),
              channelId: Value(item.channelId),
              documentJson: Value(item.documentJson),
              tags: Value(TagsCodec.encode(item.tags)),
              isPinned: Value(item.isPinned),
              createdAt: item.createdAt,
              updatedAt: item.updatedAt,
            ),
          );
      await _outbox.enqueue(
        entityType: SyncEntityType.item,
        entityId: item.id,
        baseRevision: 0,
        operation: SyncOperation.upsert,
      );
      for (final attachment in attachmentRecords) {
        await _outbox.enqueue(
          entityType: SyncEntityType.attachment,
          entityId: attachment.id,
          baseRevision: attachment.serverRevision,
          operation: SyncOperation.upsert,
        );
      }
      return item;
    });
  }

  /// Moves an active item. A null [channelId] means Inbox.
  Future<Item> moveItem(String id, {required String? channelId}) =>
      _db.transaction(() async {
        final record = await _recordById(id);
        if (record == null) throw StateError('No item with id "$id"');
        if (record.deletedAt != null) {
          throw StateError('Cannot move tombstoned item "$id"');
        }
        await _validateTargetChannel(channelId);
        if (record.channelId == channelId) return record.toItem();
        final now = DateTime.now();
        await (_db.update(_db.items)..where((row) => row.id.equals(id))).write(
          ItemsCompanion(channelId: Value(channelId), updatedAt: Value(now)),
        );
        await _outbox.enqueue(
          entityType: SyncEntityType.item,
          entityId: id,
          baseRevision: record.serverRevision,
          operation: SyncOperation.upsert,
        );
        return Item(
          id: record.id,
          title: record.title,
          content: record.content,
          note: record.note,
          channelId: channelId,
          documentJson: record.documentJson,
          tags: TagsCodec.decode(record.tags),
          isPinned: record.isPinned,
          createdAt: record.createdAt,
          updatedAt: now,
          deletedAt: record.deletedAt,
        );
      });

  /// Updates the provided fields. [title] and [note] distinguish an omitted
  /// update from assigning a value (including `null`) with [FieldUpdate].
  /// [content] may not be set to a blank value. Returns the updated item, or
  /// the item unchanged when no field was provided.
  Future<Item> updateItem(
    String id, {
    FieldUpdate<String?> title = const FieldUpdate.unchanged(),
    String? content,
    FieldUpdate<String?> note = const FieldUpdate.unchanged(),
    List<String>? tags,
    ItemDocumentSnapshot? document,
  }) => _db.transaction(() async {
    final record = await _recordById(id);
    if (record == null) {
      throw StateError('No item with id "$id"');
    }
    final current = record.toItem();
    if (current.isDeleted) {
      throw StateError('Cannot update tombstoned item "$id"');
    }
    if (!title.isChanged &&
        content == null &&
        !note.isChanged &&
        tags == null &&
        document == null) {
      return current;
    }
    if (content != null && document != null) {
      throw ArgumentError('Set either content or document, not both.');
    }
    final updatedTitle = title.valueOr(current.title);
    final updatedNote = note.valueOr(current.note);
    final updatedContent = document != null
        ? _validatedDocument(document).plainText
        : content == null
        ? current.content
        : _validatedLegacyContent(content);
    final updatedDocumentJson = document != null
        ? document.documentJson
        : content != null
        ? null
        : current.documentJson;
    final oldAttachmentIds = _attachmentIds(
      documentJson: record.documentJson,
      legacyText: record.content,
    );
    final newAttachmentIds = document != null
        ? document.attachmentIds
        : content != null
        ? const <String>{}
        : oldAttachmentIds;
    final attachmentRecords = document != null || content != null
        ? await _validatedAttachmentRecords(
            itemId: id,
            attachmentIds: newAttachmentIds,
          )
        : const <AttachmentRecord>[];
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(
        title: Value(updatedTitle),
        content: Value(updatedContent),
        documentJson: Value(updatedDocumentJson),
        note: Value(updatedNote),
        tags: Value(
          tags == null
              ? TagsCodec.encode(current.tags)
              : TagsCodec.encode(tags),
        ),
        updatedAt: Value(now),
      ),
    );
    await _outbox.enqueue(
      entityType: SyncEntityType.item,
      entityId: id,
      baseRevision: record.serverRevision,
      operation: SyncOperation.upsert,
    );
    if (document != null || content != null) {
      await _applyAttachmentDiff(
        itemId: id,
        oldIds: oldAttachmentIds,
        newIds: newAttachmentIds,
        activeNewRecords: attachmentRecords,
        deletedAt: now,
      );
    }
    return Item(
      id: current.id,
      title: updatedTitle,
      content: updatedContent,
      note: updatedNote,
      channelId: current.channelId,
      documentJson: updatedDocumentJson,
      tags: tags ?? current.tags,
      isPinned: current.isPinned,
      createdAt: current.createdAt,
      updatedAt: now,
      deletedAt: current.deletedAt,
    );
  });

  /// Sets the pinned flag. No-op when the flag already has that value.
  Future<Item> setPinned(String id, bool isPinned) => _db.transaction(() async {
    final record = await _recordById(id);
    if (record == null) {
      throw StateError('No item with id "$id"');
    }
    if (record.deletedAt != null) {
      throw StateError('Cannot pin tombstoned item "$id"');
    }
    if (record.isPinned == isPinned) {
      return record.toItem();
    }
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(isPinned: Value(isPinned), updatedAt: Value(now)),
    );
    await _outbox.enqueue(
      entityType: SyncEntityType.item,
      entityId: id,
      baseRevision: record.serverRevision,
      operation: SyncOperation.upsert,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
      channelId: record.channelId,
      documentJson: record.documentJson,
      tags: TagsCodec.decode(record.tags),
      isPinned: isPinned,
      createdAt: record.createdAt,
      updatedAt: now,
      deletedAt: record.deletedAt,
    );
  });

  /// Tombstones the item: sets [Item.deletedAt] and bumps [Item.updatedAt],
  /// but keeps the row in the database. No-op when already deleted.
  Future<Item> softDeleteItem(String id) => _db.transaction(() async {
    final record = await _recordById(id);
    if (record == null) {
      throw StateError('No item with id "$id"');
    }
    if (record.deletedAt != null) {
      return record.toItem();
    }
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    await _outbox.enqueue(
      entityType: SyncEntityType.item,
      entityId: id,
      baseRevision: record.serverRevision,
      operation: SyncOperation.delete,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
      channelId: record.channelId,
      documentJson: record.documentJson,
      tags: TagsCodec.decode(record.tags),
      isPinned: record.isPinned,
      createdAt: record.createdAt,
      updatedAt: now,
      deletedAt: now,
    );
  });

  /// Clears the tombstone set by [softDeleteItem]. No-op when not deleted.
  Future<Item> restoreItem(String id) => _db.transaction(() async {
    final record = await _recordById(id);
    if (record == null) {
      throw StateError('No item with id "$id"');
    }
    if (record.deletedAt == null) {
      return record.toItem();
    }
    final restoredChannelId = await _activeChannelIdOrInbox(record.channelId);
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(
        channelId: Value(restoredChannelId),
        deletedAt: const Value(null),
        updatedAt: Value(now),
      ),
    );
    await _outbox.enqueue(
      entityType: SyncEntityType.item,
      entityId: id,
      baseRevision: record.serverRevision,
      operation: SyncOperation.upsert,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
      channelId: restoredChannelId,
      documentJson: record.documentJson,
      tags: TagsCodec.decode(record.tags),
      isPinned: record.isPinned,
      createdAt: record.createdAt,
      updatedAt: now,
      deletedAt: null,
    );
  });

  // --- internals ------------------------------------------------------------

  /// Validates that a saved document can only claim live attachment metadata
  /// already staged for this exact Item.
  Future<List<AttachmentRecord>> _validatedAttachmentRecords({
    required String itemId,
    required Set<String> attachmentIds,
  }) async {
    if (attachmentIds.isEmpty) return const [];
    final records = <AttachmentRecord>[];
    for (final attachmentId in attachmentIds) {
      final record = await (_db.select(
        _db.attachments,
      )..where((row) => row.id.equals(attachmentId))).getSingleOrNull();
      if (record == null) {
        throw StateError('Attachment "$attachmentId" does not exist.');
      }
      if (record.itemId != itemId) {
        throw StateError('Attachment "$attachmentId" belongs to another Item.');
      }
      if (record.deletedAt != null) {
        throw StateError('Attachment "$attachmentId" is deleted.');
      }
      records.add(record);
    }
    return records;
  }

  Future<void> _applyAttachmentDiff({
    required String itemId,
    required Set<String> oldIds,
    required Set<String> newIds,
    required List<AttachmentRecord> activeNewRecords,
    required DateTime deletedAt,
  }) async {
    final added = newIds.difference(oldIds);
    for (final attachment in activeNewRecords) {
      if (!added.contains(attachment.id)) continue;
      await _outbox.enqueue(
        entityType: SyncEntityType.attachment,
        entityId: attachment.id,
        baseRevision: attachment.serverRevision,
        operation: SyncOperation.upsert,
      );
    }
    for (final attachmentId in oldIds.difference(newIds)) {
      final record = await (_db.select(
        _db.attachments,
      )..where((row) => row.id.equals(attachmentId))).getSingleOrNull();
      if (record == null || record.itemId != itemId) {
        throw StateError(
          'Stored attachment "$attachmentId" has invalid ownership.',
        );
      }
      if (record.deletedAt != null) continue;
      await (_db.update(_db.attachments)
            ..where((row) => row.id.equals(attachmentId)))
          .write(AttachmentsCompanion(deletedAt: Value(deletedAt)));
      await _outbox.enqueue(
        entityType: SyncEntityType.attachment,
        entityId: attachmentId,
        baseRevision: record.serverRevision,
        operation: SyncOperation.delete,
      );
    }
  }

  static Set<String> _attachmentIds({
    required String? documentJson,
    required String legacyText,
  }) {
    if (documentJson == null) return const {};
    return _documentCodec
        .snapshot(
          _documentCodec.decode(
            documentJson: documentJson,
            legacyText: legacyText,
          ),
        )
        .attachmentIds;
  }

  Future<ItemRecord?> _recordById(String id) =>
      (_db.select(_db.items)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<Item>> _watchItems(
    Expression<bool> Function($ItemsTable row) predicate,
  ) =>
      (_db.select(_db.items)
            ..where(predicate)
            ..orderBy([(row) => OrderingTerm.desc(row.updatedAt)]))
          .watch()
          .map((rows) => rows.map((row) => row.toItem()).toList());

  Future<void> _validateTargetChannel(String? channelId) async {
    if (channelId == null) return;
    final channel = await (_db.select(
      _db.channels,
    )..where((row) => row.id.equals(channelId))).getSingleOrNull();
    if (channel == null || channel.deletedAt != null) {
      throw StateError('Target channel does not exist or was deleted.');
    }
  }

  Future<String?> _activeChannelIdOrInbox(String? channelId) async {
    if (channelId == null) return null;
    final channel = await (_db.select(
      _db.channels,
    )..where((row) => row.id.equals(channelId))).getSingleOrNull();
    return channel == null || channel.deletedAt != null ? null : channelId;
  }

  static String _validatedLegacyContent(String content) {
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content', 'must not be blank');
    }
    return content;
  }

  static ItemDocumentSnapshot _validatedDocument(
    ItemDocumentSnapshot document,
  ) {
    if (!document.hasMeaningfulBody) {
      throw ArgumentError.value(
        document.documentJson,
        'document',
        'must contain text or an attachment',
      );
    }
    return document;
  }
}

extension on ItemRecord {
  Item toItem() => Item(
    id: id,
    title: title,
    content: content,
    note: note,
    channelId: channelId,
    documentJson: documentJson,
    tags: TagsCodec.decode(tags),
    isPinned: isPinned,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );
}
