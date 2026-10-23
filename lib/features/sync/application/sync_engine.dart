import 'dart:io';

import '../../../core/database/app_database.dart';
import '../data/sync_local_store.dart';
import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';

typedef BeforeApplyPushAck = Future<void> Function(
  SyncMutation mutation,
  SyncPushResult result,
);

/// Executes one explicit, deterministic local push then remote pull cycle.
class SyncEngine {
  SyncEngine(
    this._remote, {
    required AppDatabase database,
    required Directory storageRoot,
    this._beforeApplyPushAck,
  }) : _local = SyncLocalStore(database, storageRoot);

  final SyncRemote _remote;
  final SyncLocalStore _local;
  final BeforeApplyPushAck? _beforeApplyPushAck;

  Future<void> bootstrapLocalReplicaForSync() =>
      _local.bootstrapLocalReplicaForSync();

  Future<SyncCycleResult> syncOnce() async {
    var pushed = 0;
    var pulled = 0;
    final conflicts = <SyncConflict>[];
    final errors = <SyncFailure>[];

    for (final mutation in await _local.orderedPending()) {
      try {
        if (mutation.entity.type == SyncEntityType.attachment &&
            mutation.operation == SyncOperation.upsert) {
          final blob = await _local.prepareAttachmentBlob(mutation.entity.id);
          await _remote.putBlob(
            attachmentId: mutation.entity.id,
            byteSize: blob.byteSize,
            sha256: blob.sha256,
            bytes: blob.file.openRead(),
          );
        }
        final payload = await _local.payloadFor(mutation.entity);
        final response = await _remote.push(
          SyncPushRequest(
            entity: mutation.entity,
            mutationId: mutation.mutationId,
            baseRevision: mutation.baseRevision,
            operation: mutation.operation,
            payload: payload,
          ),
        );
        if (response.wasAccepted) {
          final revision = response.remoteRevision;
          if (revision == null) {
            throw const SyncRemoteException(
              'Accepted push did not include a remote revision.',
            );
          }
          await _beforeApplyPushAck?.call(mutation, response);
          await _local.applyPushAcknowledgement(
            pushed: mutation,
            remoteRevision: revision,
          );
          pushed++;
        } else if (response.outcome == SyncApplyOutcome.conflict) {
          errors.add(
            SyncFailure(
              stage: 'push-conflict',
              entity: mutation.entity,
              message: 'Remote revision rejected a stale local mutation.',
            ),
          );
        } else {
          errors.add(
            SyncFailure(
              stage: 'push',
              entity: mutation.entity,
              message: response.message ?? 'Remote rejected mutation.',
            ),
          );
        }
      } catch (error) {
        await _local.recordPushFailure(mutation);
        errors.add(
          SyncFailure(
            stage: mutation.entity.type == SyncEntityType.attachment
                ? 'push-or-blob-upload'
                : 'push',
            entity: mutation.entity,
            message: '$error',
          ),
        );
      }
    }

    var cursor = await _local.readPullCursor();
    try {
      final response = await _remote.pull(afterCursor: cursor);
      for (final change in response.changes) {
        final localRevision = await _local.serverRevisionFor(change.entity);
        final pending = await _local.pendingFor(change.entity);
        if (change.remoteRevision <= localRevision) {
          await _local.writePullCursor(change.cursor);
          cursor = change.cursor;
          continue;
        }
        if (pending != null) {
          conflicts.add(
            SyncConflict(
              entity: change.entity,
              localMutation: pending,
              localServerRevision: localRevision,
              remoteChange: change,
            ),
          );
          break;
        }

        String? relativePath;
        if (change.entity.type == SyncEntityType.attachment &&
            change.operation == SyncOperation.upsert) {
          final payload = AttachmentSyncPayload.fromJson(change.payload);
          final blob = await _remote.getBlob(change.entity.id);
          if (blob == null) {
            throw const SyncRemoteException(
              'Remote attachment metadata has no blob.',
            );
          }
          relativePath = await _local.installRemoteBlob(payload, blob);
        }
        await _local.applyRemoteChange(
          change,
          attachmentRelativePath: relativePath,
        );
        await _local.writePullCursor(change.cursor);
        cursor = change.cursor;
        pulled++;
      }
    } catch (error) {
      errors.add(SyncFailure(stage: 'pull', message: '$error'));
    }

    return SyncCycleResult(
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      errors: errors,
      remainingPending: await _local.pendingCount(),
      cursor: cursor,
    );
  }
}
