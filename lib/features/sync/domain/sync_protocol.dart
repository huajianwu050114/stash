import 'sync_models.dart';
import 'sync_payloads.dart';

class SyncPushRequest {
  const SyncPushRequest({
    required this.entity,
    required this.mutationId,
    required this.baseRevision,
    required this.operation,
    required this.payload,
  });

  final SyncEntityKey entity;
  final String mutationId;
  final int baseRevision;
  final SyncOperation operation;
  final JsonMap payload;
}

class SyncPushResult {
  const SyncPushResult({
    required this.outcome,
    this.remoteRevision,
    this.message,
  });

  final SyncApplyOutcome outcome;
  final int? remoteRevision;
  final String? message;

  bool get wasAccepted =>
      outcome == SyncApplyOutcome.accepted ||
      outcome == SyncApplyOutcome.alreadyApplied;
}

class SyncRemoteChange {
  const SyncRemoteChange({
    required this.cursor,
    required this.entity,
    required this.remoteRevision,
    required this.operation,
    required this.mutationId,
    required this.payload,
  });

  final int cursor;
  final SyncEntityKey entity;
  final int remoteRevision;
  final SyncOperation operation;
  final String mutationId;
  final JsonMap payload;
}

class SyncPullResult {
  SyncPullResult({required Iterable<SyncRemoteChange> changes})
    : changes = List.unmodifiable(changes);

  final List<SyncRemoteChange> changes;
}

class SyncBlobDownload {
  const SyncBlobDownload({
    required this.byteSize,
    required this.sha256,
    required this.bytes,
  });

  final int byteSize;
  final String sha256;
  final Stream<List<int>> bytes;
}

abstract interface class SyncRemote {
  Future<SyncPushResult> push(SyncPushRequest request);

  Future<SyncPullResult> pull({required int afterCursor});

  Future<void> putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256,
    required Stream<List<int>> bytes,
  });

  Future<SyncBlobDownload?> getBlob(String attachmentId);
}

class SyncConflict {
  const SyncConflict({
    required this.entity,
    required this.localMutation,
    required this.localServerRevision,
    required this.remoteChange,
  });

  final SyncEntityKey entity;
  final SyncMutation localMutation;
  final int localServerRevision;
  final SyncRemoteChange remoteChange;
}

class SyncFailure {
  const SyncFailure({required this.stage, required this.message, this.entity});

  final String stage;
  final String message;
  final SyncEntityKey? entity;
}

class SyncCycleResult {
  SyncCycleResult({
    required this.pushed,
    required this.pulled,
    required Iterable<SyncConflict> conflicts,
    required Iterable<SyncFailure> errors,
    required this.remainingPending,
    required this.cursor,
  }) : conflicts = List.unmodifiable(conflicts),
       errors = List.unmodifiable(errors);

  final int pushed;
  final int pulled;
  final List<SyncConflict> conflicts;
  final List<SyncFailure> errors;
  final int remainingPending;
  final int cursor;
}

class SyncRemoteException implements Exception {
  const SyncRemoteException(this.message);

  final String message;

  @override
  String toString() => 'SyncRemoteException: $message';
}
