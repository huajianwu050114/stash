import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';

/// Non-production, in-memory implementation used to prove sync semantics.
class FakeSyncRemote implements SyncRemote {
  final Map<SyncEntityKey, FakeRemoteEntity> _entities = {};
  final Map<String, SyncPushResult> _appliedMutations = {};
  final List<SyncRemoteChange> _changes = [];
  final Map<String, _FakeBlob> _blobs = {};
  final Map<String, _FakeBlob> _stagedBlobs = {};

  bool failNextPush = false;
  bool failNextPull = false;
  bool failNextBlobUpload = false;

  List<SyncRemoteChange> get changes => List.unmodifiable(_changes);

  FakeRemoteEntity? entity(SyncEntityKey key) => _entities[key];

  bool hasBlob(String attachmentId) => _blobs.containsKey(attachmentId);

  void removeBlob(String attachmentId) => _blobs.remove(attachmentId);

  void corruptBlob(String attachmentId) {
    final blob = _blobs[attachmentId];
    if (blob == null) return;
    _blobs[attachmentId] = _FakeBlob(
      bytes: Uint8List.fromList([...blob.bytes, 0]),
      sha256: blob.sha256,
    );
  }

  @override
  Future<SyncPushResult> push(SyncPushRequest request) async {
    if (failNextPush) {
      failNextPush = false;
      throw const SyncRemoteException('Injected push failure.');
    }
    final applied = _appliedMutations[request.mutationId];
    if (applied != null) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.alreadyApplied,
        remoteRevision: applied.remoteRevision,
      );
    }

    final current = _entities[request.entity];
    if (current == null && request.baseRevision != 0) {
      return const SyncPushResult(
        outcome: SyncApplyOutcome.invalidDependency,
        message: 'A new remote entity must use base revision 0.',
      );
    }
    if (current != null && current.revision > request.baseRevision) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.conflict,
        remoteRevision: current.revision,
      );
    }
    if (current != null && current.revision < request.baseRevision) {
      return SyncPushResult(
        outcome: SyncApplyOutcome.invalidDependency,
        remoteRevision: current.revision,
        message: 'Mutation base revision is ahead of the remote entity.',
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

    final revision = (current?.revision ?? 0) + 1;
    final payload = Map<String, Object?>.unmodifiable(request.payload);
    final record = FakeRemoteEntity(
      key: request.entity,
      revision: revision,
      operation: request.operation,
      payload: payload,
    );
    if (request.entity.type == SyncEntityType.attachment &&
        request.operation == SyncOperation.upsert) {
      final staged = _stagedBlobs.remove(request.entity.id);
      if (staged != null) _blobs[request.entity.id] = staged;
    }
    _entities[request.entity] = record;
    final change = SyncRemoteChange(
      cursor: _changes.length + 1,
      entity: request.entity,
      remoteRevision: revision,
      operation: request.operation,
      mutationId: request.mutationId,
      payload: payload,
    );
    _changes.add(change);
    final result = SyncPushResult(
      outcome: SyncApplyOutcome.accepted,
      remoteRevision: revision,
    );
    _appliedMutations[request.mutationId] = result;
    return result;
  }

  String? _validateDependencies(SyncPushRequest request) {
    if (request.operation == SyncOperation.delete) {
      if (request.entity.type != SyncEntityType.channel) return null;
      final activeChild = _entities.values.any(
        (entry) =>
            entry.key.type == SyncEntityType.channel &&
            entry.operation != SyncOperation.delete &&
            entry.payload['parentId'] == request.entity.id,
      );
      if (activeChild) return 'Channel still has an active child.';
      final activeItem = _entities.values.any(
        (entry) =>
            entry.key.type == SyncEntityType.item &&
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
        if (itemId == null ||
            !_entities.containsKey(
              SyncEntityKey(type: SyncEntityType.item, id: itemId),
            )) {
          return 'Owning Item is missing.';
        }
        final checksum = request.payload['sha256'] as String?;
        final byteSize = request.payload['byteSize'] as int?;
        final blob =
            _stagedBlobs[request.entity.id] ?? _blobs[request.entity.id];
        if (checksum == null || byteSize == null || blob == null) {
          return 'Attachment blob is missing.';
        }
        if (blob.sha256 != checksum || blob.bytes.length != byteSize) {
          return 'Attachment blob integrity metadata does not match.';
        }
        return null;
    }
  }

  bool _isLive(SyncEntityType type, String id) {
    final record = _entities[SyncEntityKey(type: type, id: id)];
    return record != null && record.operation != SyncOperation.delete;
  }

  @override
  Future<SyncPullResult> pull({required int afterCursor}) async {
    if (failNextPull) {
      failNextPull = false;
      throw const SyncRemoteException('Injected pull failure.');
    }
    return SyncPullResult(
      changes: _changes.where((change) => change.cursor > afterCursor),
    );
  }

  @override
  Future<void> putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256,
    required Stream<List<int>> bytes,
  }) async {
    if (failNextBlobUpload) {
      failNextBlobUpload = false;
      throw const SyncRemoteException('Injected blob upload failure.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final collected = builder.takeBytes();
    final actual = _digest(collected);
    if (collected.length != byteSize || actual != sha256) {
      throw const SyncRemoteException('Uploaded blob failed integrity checks.');
    }
    final uploaded = _FakeBlob(bytes: collected, sha256: actual);
    final committed = _blobs[attachmentId];
    if (committed != null &&
        committed.sha256 == uploaded.sha256 &&
        committed.bytes.length == uploaded.bytes.length) {
      return;
    }
    _stagedBlobs[attachmentId] = uploaded;
  }

  @override
  Future<SyncBlobDownload?> getBlob(String attachmentId) async {
    final blob = _blobs[attachmentId];
    if (blob == null) return null;
    return SyncBlobDownload(
      byteSize: blob.bytes.length,
      sha256: blob.sha256,
      bytes: Stream.value(blob.bytes),
    );
  }

  static String _digest(List<int> bytes) => sha256.convert(bytes).toString();
}

class FakeRemoteEntity {
  const FakeRemoteEntity({
    required this.key,
    required this.revision,
    required this.operation,
    required this.payload,
  });

  final SyncEntityKey key;
  final int revision;
  final SyncOperation operation;
  final JsonMap payload;
}

class _FakeBlob {
  const _FakeBlob({required this.bytes, required this.sha256});

  final Uint8List bytes;
  final String sha256;
}
