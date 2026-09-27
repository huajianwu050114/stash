import 'package:drift/drift.dart';

/// The single unified table behind every stashed item.
///
/// [serverRevision] is persistence/sync metadata and deliberately does not
/// appear on the domain `Item` object. A value of 0 means the row has never
/// been acknowledged by a remote server.
@DataClassName('ItemRecord')
class Items extends Table {
  TextColumn get id => text()();

  TextColumn get title => text().nullable()();

  TextColumn get content => text()();

  TextColumn get note => text().nullable()();

  /// JSON array of strings, encoded by `TagsCodec`. Kept serialized for
  /// Phase 1; the codec is the single seam for a future relational schema.
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  /// Tombstone: when set, the item is deleted from the user's perspective
  /// but the row is retained.
  DateTimeColumn get deletedAt => dateTime().nullable()();

  IntColumn get serverRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
