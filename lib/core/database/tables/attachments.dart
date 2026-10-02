import 'package:drift/drift.dart';

@DataClassName('AttachmentRecord')
class Attachments extends Table {
  TextColumn get id => text()();

  TextColumn get itemId => text()();

  TextColumn get mimeType => text()();

  TextColumn get originalFileName => text().nullable()();

  /// Path relative to the app-managed support directory.
  TextColumn get relativePath => text()();

  IntColumn get byteSize => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
