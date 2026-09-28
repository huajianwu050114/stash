import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/tags_codec.dart';
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
  ItemRepository(this._db);

  final AppDatabase _db;

  static final Uuid _uuid = Uuid();

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

  // --- mutations ------------------------------------------------------------

  /// Inserts a new item. [id] is generated (UUIDv4) unless supplied, so
  /// callers may pass a client-generated id and keep it stable forever.
  Future<Item> createItem({
    String? id,
    String? title,
    required String content,
    String? note,
    List<String> tags = const [],
    bool isPinned = false,
  }) async {
    final now = DateTime.now();
    final item = Item(
      id: id ?? _uuid.v4(),
      title: title,
      content: _validatedContent(content),
      note: note,
      tags: tags,
      isPinned: isPinned,
      createdAt: now,
      updatedAt: now,
    );
    return _db.transaction(() async {
      await _db
          .into(_db.items)
          .insert(
            ItemsCompanion.insert(
              id: item.id,
              title: Value(item.title),
              content: item.content,
              note: Value(item.note),
              tags: Value(TagsCodec.encode(item.tags)),
              isPinned: Value(item.isPinned),
              createdAt: item.createdAt,
              updatedAt: item.updatedAt,
            ),
          );
      await _enqueueMutation(item.id, op: 'upsert', baseRevisionFallback: 0);
      return item;
    });
  }

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
        tags == null) {
      return current;
    }
    final updatedTitle = title.valueOr(current.title);
    final updatedNote = note.valueOr(current.note);
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(
        title: Value(updatedTitle),
        content: Value(
          content == null ? current.content : _validatedContent(content),
        ),
        note: Value(updatedNote),
        tags: Value(
          tags == null
              ? TagsCodec.encode(current.tags)
              : TagsCodec.encode(tags),
        ),
        updatedAt: Value(now),
      ),
    );
    await _enqueueMutation(
      id,
      op: 'upsert',
      baseRevisionFallback: record.serverRevision,
    );
    return Item(
      id: current.id,
      title: updatedTitle,
      content: content ?? current.content,
      note: updatedNote,
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
    await _enqueueMutation(
      id,
      op: 'upsert',
      baseRevisionFallback: record.serverRevision,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
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
    await _enqueueMutation(
      id,
      op: 'delete',
      baseRevisionFallback: record.serverRevision,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
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
    final now = DateTime.now();
    await (_db.update(_db.items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(deletedAt: const Value(null), updatedAt: Value(now)),
    );
    await _enqueueMutation(
      id,
      op: 'upsert',
      baseRevisionFallback: record.serverRevision,
    );
    return Item(
      id: record.id,
      title: record.title,
      content: record.content,
      note: record.note,
      tags: TagsCodec.decode(record.tags),
      isPinned: record.isPinned,
      createdAt: record.createdAt,
      updatedAt: now,
      deletedAt: null,
    );
  });

  // --- internals ------------------------------------------------------------

  /// Upserts the pending outbox mutation for [itemId]. Must be called inside
  /// a transaction so the item write and its pending mutation commit (or
  /// roll back) atomically.
  ///
  /// Coalescing rules: at most one outbox row per item. A new local edit
  /// refreshes `mutationId`, `op`, `createdAt` and `retryCount`, but
  /// preserves the existing row's `baseRevision` — the server revision the
  /// pending change first diverged from. [baseRevisionFallback] is only used
  /// when no pending entry exists yet.
  Future<void> _enqueueMutation(
    String itemId, {
    required String op,
    required int baseRevisionFallback,
  }) async {
    final existing = await (_db.select(
      _db.syncOutbox,
    )..where((t) => t.itemId.equals(itemId))).getSingleOrNull();
    final mutationId = _uuid.v4();
    final now = DateTime.now();
    if (existing == null) {
      await _db
          .into(_db.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              itemId: itemId,
              mutationId: mutationId,
              baseRevision: baseRevisionFallback,
              op: op,
              createdAt: now,
            ),
          );
    } else {
      await (_db.update(
        _db.syncOutbox,
      )..where((t) => t.itemId.equals(itemId))).write(
        SyncOutboxCompanion(
          mutationId: Value(mutationId),
          op: Value(op),
          retryCount: const Value(0),
          createdAt: Value(now),
        ),
      );
    }
  }

  Future<ItemRecord?> _recordById(String id) =>
      (_db.select(_db.items)..where((t) => t.id.equals(id))).getSingleOrNull();

  static String _validatedContent(String content) {
    if (content.trim().isEmpty) {
      throw ArgumentError.value(content, 'content', 'must not be blank');
    }
    return content;
  }
}

extension on ItemRecord {
  Item toItem() => Item(
    id: id,
    title: title,
    content: content,
    note: note,
    tags: TagsCodec.decode(tags),
    isPinned: isPinned,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );
}
