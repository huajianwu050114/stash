import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/channel.dart';

class ChannelRepositoryException implements Exception {
  const ChannelRepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChannelRepository {
  ChannelRepository(this._db);

  final AppDatabase _db;
  static final Uuid _uuid = Uuid();

  Future<Channel?> getChannelById(String id) async =>
      (await _recordById(id))?.toChannel();

  Stream<Channel?> watchChannelById(String id) =>
      (_db.select(_db.channels)..where((row) => row.id.equals(id)))
          .watchSingleOrNull()
          .map((row) => row?.toChannel());

  Stream<List<Channel>> watchRootChannels() => _watchChildren(null);

  Stream<List<Channel>> watchChildChannels(String parentId) =>
      _watchChildren(parentId);

  Stream<List<Channel>> watchActiveChannels() {
    final query = _db.select(_db.channels)
      ..where((row) => row.deletedAt.isNull())
      ..orderBy([(row) => OrderingTerm.asc(row.name)]);
    return query.watch().map(
      (rows) => rows.map((row) => row.toChannel()).toList(),
    );
  }

  Future<List<Channel>> getActiveChannels() async {
    final rows =
        await (_db.select(_db.channels)
              ..where((row) => row.deletedAt.isNull())
              ..orderBy([(row) => OrderingTerm.asc(row.name)]))
            .get();
    return rows.map((row) => row.toChannel()).toList();
  }

  Future<List<Channel>> getBreadcrumbs(String channelId) async {
    final result = <Channel>[];
    final seen = <String>{};
    String? cursor = channelId;
    while (cursor != null) {
      if (!seen.add(cursor)) {
        throw const ChannelRepositoryException('Invalid channel hierarchy.');
      }
      final record = await _recordById(cursor);
      if (record == null || record.deletedAt != null) {
        throw const ChannelRepositoryException('Channel is unavailable.');
      }
      result.add(record.toChannel());
      cursor = record.parentId;
    }
    return result.reversed.toList();
  }

  Future<Channel> createRootChannel({String? id, required String name}) =>
      _create(id: id, name: name, parentId: null);

  Future<Channel> createChildChannel({
    String? id,
    required String name,
    required String parentId,
  }) => _create(id: id, name: name, parentId: parentId);

  Future<Channel> renameChannel(String id, String name) => _db.transaction(
    () async {
      final record = await _activeRecord(id);
      final trimmed = _validatedName(name);
      if (record.name == trimmed) return record.toChannel();
      final now = DateTime.now();
      await (_db.update(_db.channels)..where((row) => row.id.equals(id))).write(
        ChannelsCompanion(name: Value(trimmed), updatedAt: Value(now)),
      );
      return Channel(
        id: id,
        name: trimmed,
        parentId: record.parentId,
        createdAt: record.createdAt,
        updatedAt: now,
        deletedAt: null,
      );
    },
  );

  Future<Channel> moveChannel(String id, {required String? parentId}) =>
      _db.transaction(() async {
        final record = await _activeRecord(id);
        if (parentId == id) {
          throw const ChannelRepositoryException(
            'A channel cannot be its own parent.',
          );
        }
        if (parentId != null) {
          await _validateParent(parentId, movingChannelId: id);
        }
        if (record.parentId == parentId) return record.toChannel();
        final now = DateTime.now();
        await (_db.update(
          _db.channels,
        )..where((row) => row.id.equals(id))).write(
          ChannelsCompanion(parentId: Value(parentId), updatedAt: Value(now)),
        );
        return Channel(
          id: id,
          name: record.name,
          parentId: parentId,
          createdAt: record.createdAt,
          updatedAt: now,
          deletedAt: null,
        );
      });

  Future<Channel> softDeleteChannel(String id) => _db.transaction(() async {
    final record = await _activeRecord(id);
    final child =
        await (_db.select(_db.channels)
              ..where((row) => row.parentId.equals(id) & row.deletedAt.isNull())
              ..limit(1))
            .getSingleOrNull();
    if (child != null) {
      throw const ChannelRepositoryException(
        'Move or delete child channels first.',
      );
    }
    final item =
        await (_db.select(_db.items)
              ..where(
                (row) => row.channelId.equals(id) & row.deletedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (item != null) {
      throw const ChannelRepositoryException(
        'Move or delete items in this channel first.',
      );
    }
    final now = DateTime.now();
    await (_db.update(_db.channels)..where((row) => row.id.equals(id))).write(
      ChannelsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
    return Channel(
      id: id,
      name: record.name,
      parentId: record.parentId,
      createdAt: record.createdAt,
      updatedAt: now,
      deletedAt: now,
    );
  });

  Stream<List<Channel>> _watchChildren(String? parentId) {
    final query = _db.select(_db.channels)
      ..where(
        (row) =>
            (parentId == null
                ? row.parentId.isNull()
                : row.parentId.equals(parentId)) &
            row.deletedAt.isNull(),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.name)]);
    return query.watch().map(
      (rows) => rows.map((row) => row.toChannel()).toList(),
    );
  }

  Future<Channel> _create({
    required String? id,
    required String name,
    required String? parentId,
  }) => _db.transaction(() async {
    if (parentId != null) await _validateParent(parentId);
    final now = DateTime.now();
    final channel = Channel(
      id: id ?? _uuid.v4(),
      name: _validatedName(name),
      parentId: parentId,
      createdAt: now,
      updatedAt: now,
      deletedAt: null,
    );
    await _db
        .into(_db.channels)
        .insert(
          ChannelsCompanion.insert(
            id: channel.id,
            name: channel.name,
            parentId: Value(channel.parentId),
            createdAt: channel.createdAt,
            updatedAt: channel.updatedAt,
          ),
        );
    return channel;
  });

  Future<void> _validateParent(
    String parentId, {
    String? movingChannelId,
  }) async {
    final seen = <String>{};
    String? cursor = parentId;
    while (cursor != null) {
      if (cursor == movingChannelId) {
        throw const ChannelRepositoryException(
          'A channel cannot be moved below one of its descendants.',
        );
      }
      if (!seen.add(cursor)) {
        throw const ChannelRepositoryException('Invalid channel hierarchy.');
      }
      final record = await _recordById(cursor);
      if (record == null || record.deletedAt != null) {
        throw const ChannelRepositoryException(
          'Parent channel does not exist or was deleted.',
        );
      }
      cursor = record.parentId;
    }
  }

  Future<ChannelRecord> _activeRecord(String id) async {
    final record = await _recordById(id);
    if (record == null || record.deletedAt != null) {
      throw const ChannelRepositoryException(
        'Channel does not exist or was deleted.',
      );
    }
    return record;
  }

  Future<ChannelRecord?> _recordById(String id) => (_db.select(
    _db.channels,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  static String _validatedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be blank');
    }
    return trimmed;
  }
}

extension on ChannelRecord {
  Channel toChannel() => Channel(
    id: id,
    name: name,
    parentId: parentId,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
  );
}
