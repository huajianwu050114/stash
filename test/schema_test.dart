import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/app_database.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = createInMemoryDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  const expectedTables = {
    'items': {
      'id',
      'title',
      'content',
      'note',
      'channel_id',
      'document_json',
      'tags',
      'is_pinned',
      'created_at',
      'updated_at',
      'deleted_at',
      'server_revision',
    },
    'channels': {
      'id',
      'name',
      'parent_id',
      'created_at',
      'updated_at',
      'deleted_at',
      'server_revision',
    },
    'attachments': {
      'id',
      'item_id',
      'mime_type',
      'original_file_name',
      'relative_path',
      'byte_size',
      'created_at',
      'deleted_at',
      'server_revision',
    },
    'sync_outbox': {
      'entity_type',
      'entity_id',
      'mutation_id',
      'base_revision',
      'op',
      'created_at',
      'retry_count',
    },
    'sync_meta': {'key', 'value'},
  };

  Future<Map<String, Set<String>>> liveSchema() async {
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    final result = <String, Set<String>>{};
    for (final table in tables) {
      final name = table.data['name']! as String;
      final columns = await db.customSelect('PRAGMA table_info($name)').get();
      result[name] = columns.map((c) => c.data['name']! as String).toSet();
    }
    return result;
  }

  test('database is created at schema version 4', () async {
    expect(db.schemaVersion, 4);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.data['user_version'], 4);
  });

  test(
    'live schema matches the expected Phase 2.6 tables and columns',
    () async {
      final live = await liveSchema();
      expect(live.keys.toSet(), expectedTables.keys.toSet());
      for (final entry in expectedTables.entries) {
        expect(
          live[entry.key],
          entry.value,
          reason: 'columns of table "${entry.key}"',
        );
      }
    },
  );

  test('committed schema export matches the live schema', () async {
    final exportFile = File('drift_schemas/drift_schema_v4.json');
    expect(
      exportFile.existsSync(),
      isTrue,
      reason:
          'regenerate with: dart run drift_dev schema dump '
          'lib/core/database/app_database.dart drift_schemas/',
    );

    final json =
        jsonDecode(exportFile.readAsStringSync()) as Map<String, dynamic>;
    final entities = (json['entities'] as List).cast<Map<String, dynamic>>();
    final exported = <String, Set<String>>{};
    for (final entity in entities) {
      final data = entity['data']! as Map<String, dynamic>;
      final columns = (data['columns'] as List).cast<Map<String, dynamic>>();
      exported[data['name']! as String] = columns
          .map((c) => c['name']! as String)
          .toSet();
    }
    expect(exported, expectedTables);
  });

  test('foreign key enforcement is enabled on open', () async {
    final fk = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(fk.data['foreign_keys'], 1);
  });

  test('generic outbox uses composite entity primary key', () async {
    final columns = await db
        .customSelect('PRAGMA table_info(sync_outbox)')
        .get();
    final primaryKey = <int, String>{};
    for (final column in columns) {
      final position = column.data['pk']! as int;
      if (position > 0) {
        primaryKey[position] = column.data['name']! as String;
      }
    }
    expect(primaryKey, {1: 'entity_type', 2: 'entity_id'});
  });
}
