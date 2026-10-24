import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';

const int stashSyncProtocolVersion = 1;

abstract final class SyncWireCodec {
  static JsonMap encodePushRequest(SyncPushRequest request) => {
    'protocolVersion': stashSyncProtocolVersion,
    'mutation': {
      'entityType': request.entity.type.wireValue,
      'entityId': request.entity.id,
      'mutationId': request.mutationId,
      'baseRevision': request.baseRevision,
      'operation': request.operation.wireValue,
      'payload': request.payload,
    },
  };

  static SyncPushRequest decodePushRequest(JsonMap json) {
    requireProtocol(json);
    final mutation = map(json, 'mutation');
    return SyncPushRequest(
      entity: SyncEntityKey(
        type: SyncEntityType.fromWireValue(string(mutation, 'entityType')),
        id: string(mutation, 'entityId'),
      ),
      mutationId: string(mutation, 'mutationId'),
      baseRevision: integer(mutation, 'baseRevision'),
      operation: SyncOperation.fromWireValue(string(mutation, 'operation')),
      payload: map(mutation, 'payload'),
    );
  }

  static JsonMap encodePushResult(SyncPushResult result) => {
    'protocolVersion': stashSyncProtocolVersion,
    'outcome': switch (result.outcome) {
      SyncApplyOutcome.accepted => 'accepted',
      SyncApplyOutcome.alreadyApplied => 'alreadyApplied',
      SyncApplyOutcome.conflict => 'conflict',
      SyncApplyOutcome.invalidDependency => 'invalidDependency',
    },
    'remoteRevision': result.remoteRevision,
    'changeCursor': result.changeCursor,
    'message': result.message,
  };

  static SyncPushResult decodePushResult(JsonMap json) {
    requireProtocol(json);
    return SyncPushResult(
      outcome: switch (string(json, 'outcome')) {
        'accepted' => SyncApplyOutcome.accepted,
        'alreadyApplied' => SyncApplyOutcome.alreadyApplied,
        'conflict' => SyncApplyOutcome.conflict,
        'invalidDependency' => SyncApplyOutcome.invalidDependency,
        final value => throw protocol('Unknown push outcome: $value'),
      },
      remoteRevision: nullableInteger(json, 'remoteRevision'),
      changeCursor: nullableInteger(json, 'changeCursor'),
      message: nullableString(json, 'message'),
    );
  }

  static JsonMap encodePullResult(SyncPullResult result) => {
    'protocolVersion': stashSyncProtocolVersion,
    'changes': result.changes
        .map(
          (change) => {
            'cursor': change.cursor,
            'entityType': change.entity.type.wireValue,
            'entityId': change.entity.id,
            'remoteRevision': change.remoteRevision,
            'operation': change.operation.wireValue,
            'mutationId': change.mutationId,
            'payload': change.payload,
          },
        )
        .toList(growable: false),
    'nextCursor': result.nextCursor,
    'hasMore': result.hasMore,
  };

  static SyncPullResult decodePullResult(JsonMap json) {
    requireProtocol(json);
    final raw = json['changes'];
    if (raw is! List) throw protocol('changes must be an array.');
    return SyncPullResult(
      changes: raw.map((value) {
        if (value is! Map) throw protocol('A change must be an object.');
        final change = Map<String, Object?>.from(value);
        return SyncRemoteChange(
          cursor: integer(change, 'cursor'),
          entity: SyncEntityKey(
            type: SyncEntityType.fromWireValue(string(change, 'entityType')),
            id: string(change, 'entityId'),
          ),
          remoteRevision: integer(change, 'remoteRevision'),
          operation: SyncOperation.fromWireValue(string(change, 'operation')),
          mutationId: string(change, 'mutationId'),
          payload: map(change, 'payload'),
        );
      }),
      nextCursor: integer(json, 'nextCursor'),
      hasMore: boolean(json, 'hasMore'),
    );
  }

  static void requireProtocol(JsonMap json) {
    if (json['protocolVersion'] != stashSyncProtocolVersion) {
      throw protocol('Remote protocol version is not supported.');
    }
  }

  static JsonMap map(JsonMap json, String key) {
    final value = json[key];
    if (value is! Map) throw protocol('$key must be an object.');
    return Map<String, Object?>.from(value);
  }

  static String string(JsonMap json, String key) {
    final value = json[key];
    if (value is! String) throw protocol('$key must be a string.');
    return value;
  }

  static String? nullableString(JsonMap json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) throw protocol('$key must be a string or null.');
    return value;
  }

  static int integer(JsonMap json, String key) {
    final value = json[key];
    if (value is! int) throw protocol('$key must be an integer.');
    return value;
  }

  static int? nullableInteger(JsonMap json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) throw protocol('$key must be an integer or null.');
    return value;
  }

  static bool boolean(JsonMap json, String key) {
    final value = json[key];
    if (value is! bool) throw protocol('$key must be a boolean.');
    return value;
  }

  static SyncRemoteException protocol(String message) => SyncRemoteException(
    message,
    kind: SyncRemoteFailureKind.protocolMismatch,
  );
}
