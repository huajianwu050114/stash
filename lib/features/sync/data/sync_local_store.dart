import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/tags_codec.dart';
import '../../items/data/item_document_codec.dart';
import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';
import 'sync_outbox_repository.dart';

class LocalAttachmentBlob {
  const LocalAttachmentBlob({
    required this.file,
    required this.byteSize,
    required this.sha256,
  });

  final File file;
  final int byteSize;
  final String sha256;
}

/// Database-facing sync path. Remote changes deliberately bypass user-facing
/// repositories so applying a pull never creates new outbox work.
class SyncLocalStore {
  SyncLocalStore(this._db, this._storageRoot, {SyncOutboxRepository? outbox})
    : _outbox = outbox ?? SyncOutboxRepository(_db);

  static const pullCursorKey = 'pull_cursor';
  static const _documentCodec = ItemDocumentCodec();
  static final _uuid = Uuid();

  final AppDatabase _db;
  final Directory _storageRoot;
  final SyncOutboxRepository _outbox;

  Future<void> bootstrapLocalReplicaForSync() => _db.transaction(() async {
    final pending = {
      for (final mutation in await _outbox.readPending()) mutation.entity,
    };

    for (final channel in await _db.select(_db.channels).get()) {
      final key = SyncEntityKey(type: SyncEntityType.channel, id: channel.id);
      if (channel.serverRevision != 0 || pending.contains(key)) continue;
      await _outbox.enqueue(
        entityType: key.type,
        entityId: key.id,
        baseRevision: 0,
        operation: channel.deletedAt == null
            ? SyncOperation.upsert
            : SyncOperation.delete,
      );
    }

    final items = await _db.select(_db.items).get();
    for (final item in items) {
      final key = SyncEntityKey(type: SyncEntityType.item, id: item.id);
      if (item.serverRevision != 0 || pending.contains(key)) continue;
      await _outbox.enqueue(
        entityType: key.type,
        entityId: key.id,
        baseRevision: 0,
        operation: item.deletedAt == null
            ? SyncOperation.upsert
            : SyncOperation.delete,
      );
    }

    final itemById = {for (final item in items) item.id: item};
    for (final attachment in await _db.select(_db.attachments).get()) {
      final key = SyncEntityKey(
        type: SyncEntityType.attachment,
        id: attachment.id,
      );
      if (attachment.serverRevision != 0 || pending.contains(key)) continue;
      final owner = itemById[attachment.itemId];
      if (owner == null ||
          (attachment.deletedAt == null &&
              !_references(owner, attachment.id))) {
        continue;
      }
      await _outbox.enqueue(
        entityType: key.type,
        entityId: key.id,
        baseRevision: 0,
        operation: attachment.deletedAt == null
            ? SyncOperation.upsert
            : SyncOperation.delete,
      );
    }
  });

  Future<List<SyncMutation>> orderedPending() async {
    final pending = await _outbox.readPending();
    final channels = {
      for (final row in await _db.select(_db.channels).get()) row.id: row,
    };
    int depth(String id) {
      var cursor = channels[id]?.parentId;
      var result = 0;
      final seen = <String>{id};
      while (cursor != null && seen.add(cursor)) {
        result++;
        cursor = channels[cursor]?.parentId;
      }
      return result;
    }

    int rank(SyncMutation mutation) {
      if (mutation.operation == SyncOperation.upsert) {
        return switch (mutation.entity.type) {
          SyncEntityType.channel => 0,
          SyncEntityType.item => 1,
          SyncEntityType.attachment => 2,
        };
      }
      return switch (mutation.entity.type) {
        SyncEntityType.attachment => 3,
        SyncEntityType.item => 4,
        SyncEntityType.channel => 5,
      };
    }

    pending.sort((left, right) {
      final byRank = rank(left).compareTo(rank(right));
      if (byRank != 0) return byRank;
      if (left.entity.type == SyncEntityType.channel) {
        final leftDepth = depth(left.entity.id);
        final rightDepth = depth(right.entity.id);
        final byDepth = left.operation == SyncOperation.upsert
            ? leftDepth.compareTo(rightDepth)
            : rightDepth.compareTo(leftDepth);
        if (byDepth != 0) return byDepth;
      }
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) return byTime;
      return left.entity.id.compareTo(right.entity.id);
    });
    return pending;
  }

  Future<JsonMap> payloadFor(SyncEntityKey key) async {
    switch (key.type) {
      case SyncEntityType.item:
        final row = await (_db.select(
          _db.items,
        )..where((entry) => entry.id.equals(key.id))).getSingleOrNull();
        if (row == null) throw StateError('Missing local Item ${key.id}.');
        return ItemSyncPayload(
          id: row.id,
          title: row.title,
          content: row.content,
          note: row.note,
          channelId: row.channelId,
          documentJson: row.documentJson,
          tags: TagsCodec.decode(row.tags),
          isPinned: row.isPinned,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          serverRevision: row.serverRevision,
        ).toJson();
      case SyncEntityType.channel:
        final row = await (_db.select(
          _db.channels,
        )..where((entry) => entry.id.equals(key.id))).getSingleOrNull();
        if (row == null) throw StateError('Missing local Channel ${key.id}.');
        return ChannelSyncPayload(
          id: row.id,
          name: row.name,
          parentId: row.parentId,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          serverRevision: row.serverRevision,
        ).toJson();
      case SyncEntityType.attachment:
        final row = await (_db.select(
          _db.attachments,
        )..where((entry) => entry.id.equals(key.id))).getSingleOrNull();
        if (row == null) {
          throw StateError('Missing local Attachment ${key.id}.');
        }
        return AttachmentSyncPayload(
          id: row.id,
          itemId: row.itemId,
          mimeType: row.mimeType,
          originalFileName: row.originalFileName,
          byteSize: row.byteSize,
          sha256: row.sha256,
          createdAt: row.createdAt,
          deletedAt: row.deletedAt,
          serverRevision: row.serverRevision,
        ).toJson();
    }
  }

  Future<LocalAttachmentBlob> prepareAttachmentBlob(String id) async {
    final row = await (_db.select(
      _db.attachments,
    )..where((entry) => entry.id.equals(id))).getSingleOrNull();
    if (row == null || row.deletedAt != null) {
      throw StateError('Active Attachment $id is unavailable.');
    }
    final file = _managedFile(row.relativePath);
    if (!await file.exists()) {
      throw StateError('Managed blob for Attachment $id is missing.');
    }
    final byteSize = await file.length();
    final checksum = (await sha256.bind(file.openRead()).first).toString();
    if (row.byteSize != byteSize || row.sha256 != checksum) {
      await (_db.update(
        _db.attachments,
      )..where((entry) => entry.id.equals(id))).write(
        AttachmentsCompanion(
          byteSize: Value(byteSize),
          sha256: Value(checksum),
        ),
      );
    }
    return LocalAttachmentBlob(
      file: file,
      byteSize: byteSize,
      sha256: checksum,
    );
  }

  Future<void> applyPushAcknowledgement({
    required SyncMutation pushed,
    required int remoteRevision,
  }) => _db.transaction(() async {
    await _setServerRevision(pushed.entity, remoteRevision);
    final current = await _outbox.getPending(pushed.entity);
    if (current == null) return;
    if (current.mutationId == pushed.mutationId) {
      await _outbox.acknowledge(
        entity: pushed.entity,
        mutationId: pushed.mutationId,
      );
      return;
    }
    if (current.baseRevision == pushed.baseRevision) {
      await (_db.update(_db.syncOutbox)..where(
            (row) =>
                row.entityType.equals(pushed.entity.type.wireValue) &
                row.entityId.equals(pushed.entity.id) &
                row.mutationId.equals(current.mutationId),
          ))
          .write(SyncOutboxCompanion(baseRevision: Value(remoteRevision)));
    }
  });

  Future<void> recordPushFailure(SyncMutation mutation) =>
      _outbox.incrementRetryCount(
        entity: mutation.entity,
        mutationId: mutation.mutationId,
      );

  Future<SyncMutation?> pendingFor(SyncEntityKey key) =>
      _outbox.getPending(key);

  Future<int> pendingCount() async => (await _outbox.readPending()).length;

  Future<int> serverRevisionFor(SyncEntityKey key) async {
    switch (key.type) {
      case SyncEntityType.item:
        return (await (_db.select(
                  _db.items,
                )..where((row) => row.id.equals(key.id))).getSingleOrNull())
                ?.serverRevision ??
            0;
      case SyncEntityType.channel:
        return (await (_db.select(
                  _db.channels,
                )..where((row) => row.id.equals(key.id))).getSingleOrNull())
                ?.serverRevision ??
            0;
      case SyncEntityType.attachment:
        return (await (_db.select(
                  _db.attachments,
                )..where((row) => row.id.equals(key.id))).getSingleOrNull())
                ?.serverRevision ??
            0;
    }
  }

  Future<int> readPullCursor() async {
    final row = await (_db.select(
      _db.syncMeta,
    )..where((entry) => entry.key.equals(pullCursorKey))).getSingleOrNull();
    if (row == null) return 0;
    final parsed = int.tryParse(row.value);
    if (parsed == null || parsed < 0) {
      throw StateError('Invalid persisted pull cursor: ${row.value}');
    }
    return parsed;
  }

  Future<void> writePullCursor(int cursor) => _db
      .into(_db.syncMeta)
      .insertOnConflictUpdate(
        SyncMetaCompanion.insert(key: pullCursorKey, value: '$cursor'),
      );

  Future<String> installRemoteBlob(
    AttachmentSyncPayload payload,
    SyncBlobDownload download,
  ) async {
    final expectedSize = payload.byteSize;
    final expectedChecksum = payload.sha256;
    if (expectedSize == null || expectedChecksum == null) {
      throw const SyncRemoteException(
        'Remote attachment lacks blob integrity metadata.',
      );
    }
    if (download.byteSize != expectedSize ||
        download.sha256 != expectedChecksum) {
      throw const SyncRemoteException(
        'Remote blob descriptor does not match attachment metadata.',
      );
    }
    final relativePath = _attachmentRelativePath(payload);
    final target = _managedFile(relativePath);
    if (await target.exists() &&
        await target.length() == expectedSize &&
        (await sha256.bind(target.openRead()).first).toString() ==
            expectedChecksum) {
      return relativePath;
    }

    await target.parent.create(recursive: true);
    final staged = File('${target.path}.part-${_uuid.v4()}');
    try {
      final sink = staged.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(download.bytes);
      await sink.flush();
      await sink.close();
      final actualSize = await staged.length();
      final actualChecksum = (await sha256.bind(staged.openRead()).first)
          .toString();
      if (actualSize != expectedSize || actualChecksum != expectedChecksum) {
        throw const SyncRemoteException(
          'Downloaded blob failed SHA-256 or byte-count verification.',
        );
      }
      await _publishVerifiedBlob(staged, target);
      return relativePath;
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
  }

  Future<void> applyRemoteChange(
    SyncRemoteChange change, {
    String? attachmentRelativePath,
  }) => _db.transaction(() async {
    switch (change.entity.type) {
      case SyncEntityType.item:
        final payload = ItemSyncPayload.fromJson(change.payload);
        await _db
            .into(_db.items)
            .insertOnConflictUpdate(
              ItemsCompanion.insert(
                id: payload.id,
                title: Value(payload.title),
                content: payload.content,
                note: Value(payload.note),
                channelId: Value(payload.channelId),
                documentJson: Value(payload.documentJson),
                tags: Value(TagsCodec.encode(payload.tags)),
                isPinned: Value(payload.isPinned),
                createdAt: payload.createdAt,
                updatedAt: payload.updatedAt,
                deletedAt: Value(payload.deletedAt),
                serverRevision: Value(change.remoteRevision),
              ),
            );
      case SyncEntityType.channel:
        final payload = ChannelSyncPayload.fromJson(change.payload);
        await _db
            .into(_db.channels)
            .insertOnConflictUpdate(
              ChannelsCompanion.insert(
                id: payload.id,
                name: payload.name,
                parentId: Value(payload.parentId),
                createdAt: payload.createdAt,
                updatedAt: payload.updatedAt,
                deletedAt: Value(payload.deletedAt),
                serverRevision: Value(change.remoteRevision),
              ),
            );
      case SyncEntityType.attachment:
        final payload = AttachmentSyncPayload.fromJson(change.payload);
        final existing = await (_db.select(
          _db.attachments,
        )..where((row) => row.id.equals(payload.id))).getSingleOrNull();
        final relativePath =
            attachmentRelativePath ??
            existing?.relativePath ??
            _attachmentRelativePath(payload);
        await _db
            .into(_db.attachments)
            .insertOnConflictUpdate(
              AttachmentsCompanion.insert(
                id: payload.id,
                itemId: payload.itemId,
                mimeType: payload.mimeType,
                originalFileName: Value(payload.originalFileName),
                relativePath: relativePath,
                byteSize: Value(payload.byteSize),
                sha256: Value(payload.sha256),
                createdAt: payload.createdAt,
                deletedAt: Value(payload.deletedAt),
                serverRevision: Value(change.remoteRevision),
              ),
            );
    }
  });

  Future<void> _setServerRevision(SyncEntityKey key, int revision) async {
    switch (key.type) {
      case SyncEntityType.item:
        await (_db.update(_db.items)..where((row) => row.id.equals(key.id)))
            .write(ItemsCompanion(serverRevision: Value(revision)));
      case SyncEntityType.channel:
        await (_db.update(_db.channels)..where((row) => row.id.equals(key.id)))
            .write(ChannelsCompanion(serverRevision: Value(revision)));
      case SyncEntityType.attachment:
        await (_db.update(_db.attachments)
              ..where((row) => row.id.equals(key.id)))
            .write(AttachmentsCompanion(serverRevision: Value(revision)));
    }
  }

  static bool _references(ItemRecord item, String attachmentId) {
    if (item.documentJson == null) return false;
    return _documentCodec
        .snapshot(
          _documentCodec.decode(
            documentJson: item.documentJson,
            legacyText: item.content,
          ),
        )
        .attachmentIds
        .contains(attachmentId);
  }

  File _managedFile(String relativePath) {
    if (path.isAbsolute(relativePath)) {
      throw StateError('Attachment paths must be relative.');
    }
    final resolved = path.normalize(path.join(_storageRoot.path, relativePath));
    if (!path.isWithin(_storageRoot.path, resolved)) {
      throw StateError('Attachment path escapes managed storage.');
    }
    return File(resolved);
  }

  static String _attachmentRelativePath(AttachmentSyncPayload payload) {
    var extension = payload.originalFileName == null
        ? ''
        : path.extension(payload.originalFileName!).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9][a-z0-9._+-]{0,19}$').hasMatch(extension)) {
      extension = switch (payload.mimeType.toLowerCase()) {
        'image/jpeg' => '.jpg',
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        'application/pdf' => '.pdf',
        'application/zip' => '.zip',
        _ => '',
      };
    }
    return path.join('attachments', '${payload.id}$extension');
  }

  static Future<void> _publishVerifiedBlob(File staged, File target) async {
    if (!await target.exists()) {
      await staged.rename(target.path);
      return;
    }
    final backup = File('${target.path}.old-${_uuid.v4()}');
    await target.rename(backup.path);
    try {
      await staged.rename(target.path);
      await backup.delete();
    } catch (_) {
      if (await target.exists()) await target.delete();
      await backup.rename(target.path);
      rethrow;
    }
  }
}
