import 'package:drift/drift.dart';

@DataClassName('ChannelRecord')
class Channels extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get parentId => text().nullable().references(Channels, #id)();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  /// 0 means this channel has never been acknowledged by a remote.
  IntColumn get serverRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
