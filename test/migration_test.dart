import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:stash/core/database/app_database.dart';

void main() {
  test('v1 upgrades to v2 without losing items or sync state', () async {
    final raw = sqlite3.openInMemory();
    raw.execute('''
      CREATE TABLE items (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NULL,
        content TEXT NOT NULL,
        note TEXT NULL,
        tags TEXT NOT NULL DEFAULT '[]',
        is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER NULL,
        server_revision INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE sync_outbox (
        item_id TEXT NOT NULL PRIMARY KEY,
        mutation_id TEXT NOT NULL,
        base_revision INTEGER NOT NULL,
        op TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE sync_meta (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL
      );
      PRAGMA user_version = 1;
    ''');
    final timestamp = DateTime.utc(2026).toIso8601String();
    raw.execute(
      'INSERT INTO items '
      '(id, content, created_at, updated_at) VALUES (?, ?, ?, ?)',
      ['legacy', 'kept', timestamp, timestamp],
    );
    raw.execute(
      'INSERT INTO sync_outbox '
      '(item_id, mutation_id, base_revision, op, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['legacy', 'mutation', 3, 'upsert', timestamp],
    );
    raw.execute('INSERT INTO sync_meta (key, value) VALUES (?, ?)', [
      'cursor',
      '42',
    ]);

    final db = AppDatabase(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final item = await (db.select(db.items)).getSingle();
    expect(item.id, 'legacy');
    expect(item.content, 'kept');
    expect(item.channelId, isNull);
    expect(await db.select(db.channels).get(), isEmpty);
    expect((await db.select(db.syncOutbox).getSingle()).mutationId, 'mutation');
    expect((await db.select(db.syncMeta).getSingle()).value, '42');
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(item.documentJson, isNull);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect(version.data['user_version'], 3);
  });

  test(
    'v2 upgrades to v3 preserving items, channels, and sync state',
    () async {
      final raw = sqlite3.openInMemory();
      raw.execute('''
      CREATE TABLE items (
        id TEXT NOT NULL PRIMARY KEY,
        title TEXT NULL,
        content TEXT NOT NULL,
        note TEXT NULL,
        channel_id TEXT NULL,
        tags TEXT NOT NULL DEFAULT '[]',
        is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT NULL,
        server_revision INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE channels (
        id TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        parent_id TEXT NULL REFERENCES channels (id),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT NULL
      );
      CREATE TABLE sync_outbox (
        item_id TEXT NOT NULL PRIMARY KEY,
        mutation_id TEXT NOT NULL,
        base_revision INTEGER NOT NULL,
        op TEXT NOT NULL,
        created_at TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE sync_meta (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL
      );
      PRAGMA user_version = 2;
    ''');
      final timestamp = DateTime.utc(2026).toIso8601String();
      raw.execute(
        'INSERT INTO channels '
        '(id, name, created_at, updated_at) VALUES (?, ?, ?, ?)',
        ['channel', 'Kept channel', timestamp, timestamp],
      );
      raw.execute(
        'INSERT INTO items '
        '(id, content, channel_id, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        ['legacy', 'exact legacy text', 'channel', timestamp, timestamp],
      );
      raw.execute(
        'INSERT INTO sync_outbox '
        '(item_id, mutation_id, base_revision, op, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        ['legacy', 'mutation', 4, 'upsert', timestamp],
      );
      raw.execute('INSERT INTO sync_meta (key, value) VALUES (?, ?)', [
        'cursor',
        '99',
      ]);

      final db = AppDatabase(NativeDatabase.opened(raw));
      addTearDown(db.close);

      final item = await db.select(db.items).getSingle();
      expect(item.content, 'exact legacy text');
      expect(item.channelId, 'channel');
      expect(item.documentJson, isNull);
      expect((await db.select(db.channels).getSingle()).name, 'Kept channel');
      expect(
        (await db.select(db.syncOutbox).getSingle()).mutationId,
        'mutation',
      );
      expect((await db.select(db.syncMeta).getSingle()).value, '99');
      expect(await db.select(db.attachments).get(), isEmpty);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 3);
    },
  );
}
