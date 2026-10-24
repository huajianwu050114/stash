import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';

/// Durable synchronization authority for LAN peers.
///
/// This database is operational relay state, not a user's working Stash
/// database. Blob files are staged, verified without whole-file buffering,
/// and then published under immutable checksum-addressed paths.
class PersistentLanRelayStore {
  PersistentLanRelayStore._(this.databaseFile, this.blobRoot, this._database);

  static const _uuid = Uuid();
  static final _safeSegment = RegExp(r'^[A-Za-z0-9._-]{1,180}$');

  final File databaseFile;
  final Directory blobRoot;
  final Database _database;
  Future<void> _operationTail = Future.value();
  bool _closed = false;

  static Future<PersistentLanRelayStore> open({
    required File databaseFile,
    required Directory blobRoot,
  }) async {
    await databaseFile.parent.create(recursive: true);
    await blobRoot.create(recursive: true);
    final database = sqlite3.open(databaseFile.path);
    final store = PersistentLanRelayStore._(databaseFile, blobRoot, database);
    try {
      store._initialize();
      return store;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  void _initialize() {
    _database
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('PRAGMA synchronous = FULL')
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('''
        CREATE TABLE IF NOT EXISTS relay_entities (
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          revision INTEGER NOT NULL,
          operation TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          PRIMARY KEY (entity_type, entity_id)
        )
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS applied_mutations (
          mutation_id TEXT PRIMARY KEY,
          remote_revision INTEGER NOT NULL,
          change_cursor INTEGER NOT NULL
        )
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS relay_changes (
          cursor INTEGER PRIMARY KEY AUTOINCREMENT,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          remote_revision INTEGER NOT NULL,
          operation TEXT NOT NULL,
          mutation_id TEXT NOT NULL UNIQUE,
          payload_json TEXT NOT NULL
        )
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS staged_blobs (
          attachment_id TEXT PRIMARY KEY,
          sha256 TEXT NOT NULL,
          byte_size INTEGER NOT NULL,
          file_path TEXT NOT NULL
        )
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS committed_blobs (
          attachment_id TEXT PRIMARY KEY,
          sha256 TEXT NOT NULL,
          byte_size INTEGER NOT NULL,
          file_path TEXT NOT NULL
        )
      ''')
      ..userVersion = 1;
  }

  Future<SyncPushResult> push(SyncPushRequest request) =>
      _serialize(() => _push(request));

  Future<SyncPushResult> _push(SyncPushRequest request) async {
    _ensureOpen();
    final already = _database.select(
      'SELECT remote_revision, change_cursor FROM applied_mutations '
      'WHERE mutation_id = ?',
      [request.mutationId],
    );
    if (already.isNotEmpty) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.alreadyApplied,
        remoteRevision: already.first['remote_revision'] as int,
        changeCursor: already.first['change_cursor'] as int,
      );
    }

    final current = _entity(request.entity);
    final currentRevision = current?.revision ?? 0;
    if (current == null && request.baseRevision != 0) {
      return const SyncPushResult(
        outcome: SyncApplyOutcome.invalidDependency,
        message: 'A new relay entity must use base revision 0.',
      );
    }
    if (currentRevision > request.baseRevision) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.conflict,
        remoteRevision: currentRevision,
      );
    }
    if (currentRevision < request.baseRevision) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.invalidDependency,
        remoteRevision: currentRevision,
        message: 'Mutation base revision is ahead of the relay entity.',
      );
    }

    final dependencyError = _validateDependencies(request);
    if (dependencyError != null) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.invalidDependency,
        remoteRevision: current?.revision,
        message: dependencyError,
      );
    }

    final revision = currentRevision + 1;
    final payloadJson = jsonEncode(request.payload);
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'INSERT INTO relay_entities '
        '(entity_type, entity_id, revision, operation, payload_json) '
        'VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT(entity_type, entity_id) DO UPDATE SET '
        'revision = excluded.revision, operation = excluded.operation, '
        'payload_json = excluded.payload_json',
        [
          request.entity.type.wireValue,
          request.entity.id,
          revision,
          request.operation.wireValue,
          payloadJson,
        ],
      );
      _database.execute(
        'INSERT INTO relay_changes '
        '(entity_type, entity_id, remote_revision, operation, mutation_id, '
        'payload_json) VALUES (?, ?, ?, ?, ?, ?)',
        [
          request.entity.type.wireValue,
          request.entity.id,
          revision,
          request.operation.wireValue,
          request.mutationId,
          payloadJson,
        ],
      );
      final cursor = _database.lastInsertRowId;
      _database.execute(
        'INSERT INTO applied_mutations '
        '(mutation_id, remote_revision, change_cursor) VALUES (?, ?, ?)',
        [request.mutationId, revision, cursor],
      );
      if (request.entity.type == SyncEntityType.attachment &&
          request.operation == SyncOperation.upsert) {
        await _commitStagedBlob(request.entity.id, request.payload);
      }
      _database.execute('COMMIT');
      return SyncPushResult(
        outcome: SyncApplyOutcome.accepted,
        remoteRevision: revision,
        changeCursor: cursor,
      );
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<SyncPullResult> pull({required int afterCursor, int limit = 100}) =>
      _serialize(() => _pull(afterCursor: afterCursor, limit: limit));

  Future<SyncPullResult> _pull({
    required int afterCursor,
    required int limit,
  }) async {
    _ensureOpen();
    if (afterCursor < 0) throw ArgumentError.value(afterCursor, 'afterCursor');
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final rows = _database.select(
      'SELECT cursor, entity_type, entity_id, remote_revision, operation, '
      'mutation_id, payload_json FROM relay_changes WHERE cursor > ? '
      'ORDER BY cursor ASC LIMIT ?',
      [afterCursor, limit + 1],
    );
    final hasMore = rows.length > limit;
    final page = rows.take(limit).map(_decodeChange).toList(growable: false);
    return SyncPullResult(
      changes: page,
      nextCursor: page.isEmpty ? afterCursor : page.last.cursor,
      hasMore: hasMore,
    );
  }

  Future<void> putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256Value,
    required Stream<List<int>> bytes,
  }) => _serialize(
    () => _putBlob(
      attachmentId: attachmentId,
      byteSize: byteSize,
      sha256Value: sha256Value,
      bytes: bytes,
    ),
  );

  Future<void> _putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256Value,
    required Stream<List<int>> bytes,
  }) async {
    _ensureOpen();
    _requireSafeSegment(attachmentId, 'attachmentId');
    if (byteSize < 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256Value)) {
      throw const SyncRemoteException(
        'Invalid blob integrity metadata.',
        kind: SyncRemoteFailureKind.blobFailure,
      );
    }
    final staging = Directory(path.join(blobRoot.path, '.staging'));
    await staging.create(recursive: true);
    final staged = File(path.join(staging.path, '${_uuid.v4()}.partial'));
    var copied = 0;
    IOSink? sink;
    try {
      sink = staged.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(
        bytes.map((chunk) {
          copied += chunk.length;
          if (copied > byteSize) {
            throw const SyncRemoteException(
              'Blob exceeds its declared byte size.',
              kind: SyncRemoteFailureKind.blobFailure,
            );
          }
          return chunk;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      final digest = await sha256.bind(staged.openRead()).first;
      if (copied != byteSize || digest.toString() != sha256Value) {
        throw const SyncRemoteException(
          'Uploaded blob failed integrity checks.',
          kind: SyncRemoteFailureKind.blobFailure,
        );
      }
      final previous = _database.select(
        'SELECT file_path FROM staged_blobs WHERE attachment_id = ?',
        [attachmentId],
      );
      _database.execute(
        'INSERT INTO staged_blobs '
        '(attachment_id, sha256, byte_size, file_path) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(attachment_id) DO UPDATE SET sha256 = excluded.sha256, '
        'byte_size = excluded.byte_size, file_path = excluded.file_path',
        [attachmentId, sha256Value, byteSize, staged.path],
      );
      if (previous.isNotEmpty) {
        final old = File(previous.first['file_path'] as String);
        if (old.path != staged.path && await old.exists()) await old.delete();
      }
    } catch (_) {
      if (sink != null) await sink.close();
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
  }

  Future<SyncBlobDownload?> getBlob(String attachmentId) =>
      _serialize(() => _getBlob(attachmentId));

  Future<SyncBlobDownload?> _getBlob(String attachmentId) async {
    _ensureOpen();
    _requireSafeSegment(attachmentId, 'attachmentId');
    final rows = _database.select(
      'SELECT sha256, byte_size, file_path FROM committed_blobs '
      'WHERE attachment_id = ?',
      [attachmentId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final file = File(row['file_path'] as String);
    if (!await file.exists()) {
      throw const SyncRemoteException(
        'Relay blob file is missing.',
        kind: SyncRemoteFailureKind.blobFailure,
      );
    }
    return SyncBlobDownload(
      byteSize: row['byte_size'] as int,
      sha256: row['sha256'] as String,
      bytes: file.openRead(),
    );
  }

  int get changeCount =>
      (_database
              .select('SELECT COUNT(*) AS count FROM relay_changes')
              .first['count']
          as int);

  int? revisionFor(SyncEntityKey key) {
    final entity = _entity(key);
    return entity?.revision;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _database.close();
  }

  _RelayEntity? _entity(SyncEntityKey key) {
    final rows = _database.select(
      'SELECT revision, operation, payload_json FROM relay_entities '
      'WHERE entity_type = ? AND entity_id = ?',
      [key.type.wireValue, key.id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return _RelayEntity(
      revision: row['revision'] as int,
      operation: SyncOperation.fromWireValue(row['operation'] as String),
      payload: _decodePayload(row['payload_json'] as String),
    );
  }

  String? _validateDependencies(SyncPushRequest request) {
    if (request.operation == SyncOperation.delete) {
      if (request.entity.type != SyncEntityType.channel) return null;
      final entities = _allEntities();
      final activeChild = entities.any(
        (entry) =>
            entry.type == SyncEntityType.channel &&
            entry.operation != SyncOperation.delete &&
            entry.payload['parentId'] == request.entity.id,
      );
      if (activeChild) return 'Channel still has an active child.';
      final activeItem = entities.any(
        (entry) =>
            entry.type == SyncEntityType.item &&
            entry.operation != SyncOperation.delete &&
            entry.payload['channelId'] == request.entity.id,
      );
      return activeItem ? 'Channel still has an active Item.' : null;
    }
    switch (request.entity.type) {
      case SyncEntityType.channel:
        final parentId = request.payload['parentId'] as String?;
        return parentId == null || _isLive(SyncEntityType.channel, parentId)
            ? null
            : 'Parent Channel is missing or tombstoned.';
      case SyncEntityType.item:
        final channelId = request.payload['channelId'] as String?;
        return channelId == null || _isLive(SyncEntityType.channel, channelId)
            ? null
            : 'Referenced Channel is missing or tombstoned.';
      case SyncEntityType.attachment:
        final itemId = request.payload['itemId'] as String?;
        if (itemId == null || !_isLive(SyncEntityType.item, itemId)) {
          return 'Owning Item is missing or tombstoned.';
        }
        final checksum = request.payload['sha256'] as String?;
        final byteSize = request.payload['byteSize'] as int?;
        final rows = _database.select(
          'SELECT sha256, byte_size FROM staged_blobs '
          'WHERE attachment_id = ? UNION ALL '
          'SELECT sha256, byte_size FROM committed_blobs '
          'WHERE attachment_id = ? LIMIT 1',
          [request.entity.id, request.entity.id],
        );
        if (checksum == null || byteSize == null || rows.isEmpty) {
          return 'Attachment blob is missing.';
        }
        return rows.first['sha256'] == checksum &&
                rows.first['byte_size'] == byteSize
            ? null
            : 'Attachment blob integrity metadata does not match.';
    }
  }

  bool _isLive(SyncEntityType type, String id) {
    final entity = _entity(SyncEntityKey(type: type, id: id));
    return entity != null && entity.operation != SyncOperation.delete;
  }

  List<_TypedRelayEntity> _allEntities() => _database
      .select('SELECT entity_type, operation, payload_json FROM relay_entities')
      .map(
        (row) => _TypedRelayEntity(
          type: SyncEntityType.fromWireValue(row['entity_type'] as String),
          operation: SyncOperation.fromWireValue(row['operation'] as String),
          payload: _decodePayload(row['payload_json'] as String),
        ),
      )
      .toList(growable: false);

  Future<void> _commitStagedBlob(String attachmentId, JsonMap payload) async {
    _requireSafeSegment(attachmentId, 'attachmentId');
    final checksum = payload['sha256'] as String;
    final byteSize = payload['byteSize'] as int;
    final committed = _database.select(
      'SELECT sha256, byte_size, file_path FROM committed_blobs '
      'WHERE attachment_id = ?',
      [attachmentId],
    );
    if (committed.isNotEmpty &&
        committed.first['sha256'] == checksum &&
        committed.first['byte_size'] == byteSize) {
      return;
    }
    final stagedRows = _database.select(
      'SELECT file_path FROM staged_blobs WHERE attachment_id = ? '
      'AND sha256 = ? AND byte_size = ?',
      [attachmentId, checksum, byteSize],
    );
    if (stagedRows.isEmpty) {
      throw const SyncRemoteException(
        'Verified staged blob disappeared before publish.',
        kind: SyncRemoteFailureKind.blobFailure,
      );
    }
    final staged = File(stagedRows.first['file_path'] as String);
    final targetDirectory = Directory(path.join(blobRoot.path, attachmentId));
    await targetDirectory.create(recursive: true);
    final target = File(path.join(targetDirectory.path, checksum));
    if (!await target.exists()) await staged.rename(target.path);
    _database.execute(
      'INSERT INTO committed_blobs '
      '(attachment_id, sha256, byte_size, file_path) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(attachment_id) DO UPDATE SET sha256 = excluded.sha256, '
      'byte_size = excluded.byte_size, file_path = excluded.file_path',
      [attachmentId, checksum, byteSize, target.path],
    );
    _database.execute('DELETE FROM staged_blobs WHERE attachment_id = ?', [
      attachmentId,
    ]);
  }

  static SyncRemoteChange _decodeChange(Row row) => SyncRemoteChange(
    cursor: row['cursor'] as int,
    entity: SyncEntityKey(
      type: SyncEntityType.fromWireValue(row['entity_type'] as String),
      id: row['entity_id'] as String,
    ),
    remoteRevision: row['remote_revision'] as int,
    operation: SyncOperation.fromWireValue(row['operation'] as String),
    mutationId: row['mutation_id'] as String,
    payload: _decodePayload(row['payload_json'] as String),
  );

  static JsonMap _decodePayload(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map) throw const FormatException('Invalid relay payload.');
    return Map<String, Object?>.from(decoded);
  }

  static void _requireSafeSegment(String value, String name) {
    if (!_safeSegment.hasMatch(value)) {
      throw ArgumentError.value(value, name, 'must be a safe path segment');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('LAN relay store is closed.');
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}

class _RelayEntity {
  const _RelayEntity({
    required this.revision,
    required this.operation,
    required this.payload,
  });

  final int revision;
  final SyncOperation operation;
  final JsonMap payload;
}

class _TypedRelayEntity {
  const _TypedRelayEntity({
    required this.type,
    required this.operation,
    required this.payload,
  });

  final SyncEntityType type;
  final SyncOperation operation;
  final JsonMap payload;
}
