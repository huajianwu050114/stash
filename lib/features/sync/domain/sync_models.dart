enum SyncEntityType {
  item('item'),
  channel('channel'),
  attachment('attachment');

  const SyncEntityType(this.wireValue);

  final String wireValue;

  static SyncEntityType fromWireValue(String value) => switch (value) {
    'item' => SyncEntityType.item,
    'channel' => SyncEntityType.channel,
    'attachment' => SyncEntityType.attachment,
    _ => throw FormatException('Unknown sync entity type: $value'),
  };
}

enum SyncOperation {
  upsert('upsert'),
  delete('delete');

  const SyncOperation(this.wireValue);

  final String wireValue;

  static SyncOperation fromWireValue(String value) => switch (value) {
    'upsert' => SyncOperation.upsert,
    'delete' => SyncOperation.delete,
    _ => throw FormatException('Unknown sync operation: $value'),
  };
}

class SyncEntityKey {
  const SyncEntityKey({required this.type, required this.id});

  final SyncEntityType type;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is SyncEntityKey && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);
}

/// A durable local mutation waiting for a future remote sync implementation.
///
/// A retry keeps [mutationId]. A new local edit creates a new [mutationId]
/// while preserving the original [baseRevision] until acknowledgement.
class SyncMutation {
  const SyncMutation({
    required this.entity,
    required this.mutationId,
    required this.baseRevision,
    required this.operation,
    required this.createdAt,
    required this.retryCount,
  });

  final SyncEntityKey entity;
  final String mutationId;
  final int baseRevision;
  final SyncOperation operation;
  final DateTime createdAt;
  final int retryCount;
}

/// Outcomes a future remote application boundary must distinguish.
enum SyncApplyOutcome { accepted, alreadyApplied, conflict, invalidDependency }

/// Pure protocol result model. S1 deliberately does not resolve conflicts.
class SyncApplyResult {
  const SyncApplyResult({
    required this.outcome,
    this.serverRevision,
    this.message,
  });

  final SyncApplyOutcome outcome;
  final int? serverRevision;
  final String? message;

  bool get isConflict => outcome == SyncApplyOutcome.conflict;
}

abstract final class SyncConcurrency {
  /// Models the S1 optimistic contract without applying any mutation.
  static SyncApplyResult evaluate({
    required int remoteRevision,
    required int baseRevision,
    bool mutationAlreadyApplied = false,
  }) {
    if (remoteRevision < 0 || baseRevision < 0) {
      throw ArgumentError('Revisions must be non-negative.');
    }
    if (mutationAlreadyApplied) {
      return SyncApplyResult(
        outcome: SyncApplyOutcome.alreadyApplied,
        serverRevision: remoteRevision,
      );
    }
    if (remoteRevision == baseRevision) {
      return SyncApplyResult(
        outcome: SyncApplyOutcome.accepted,
        serverRevision: remoteRevision,
      );
    }
    if (remoteRevision > baseRevision) {
      return SyncApplyResult(
        outcome: SyncApplyOutcome.conflict,
        serverRevision: remoteRevision,
      );
    }
    return SyncApplyResult(
      outcome: SyncApplyOutcome.invalidDependency,
      serverRevision: remoteRevision,
      message: 'Mutation base revision is ahead of the remote entity.',
    );
  }
}
