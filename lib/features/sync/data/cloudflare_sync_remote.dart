import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';

const int stashSyncProtocolVersion = 1;

class CloudflareSyncConfig {
  const CloudflareSyncConfig({required this.baseUrl, required this.token});

  factory CloudflareSyncConfig.fromEnvironment() => const CloudflareSyncConfig(
    baseUrl: String.fromEnvironment('STASH_SYNC_BASE_URL'),
    token: String.fromEnvironment('STASH_SYNC_TOKEN'),
  );

  factory CloudflareSyncConfig.fromProcessEnvironment() => CloudflareSyncConfig(
    baseUrl: Platform.environment['STASH_SYNC_BASE_URL'] ?? '',
    token: Platform.environment['STASH_SYNC_TOKEN'] ?? '',
  );

  final String baseUrl;
  final String token;

  Uri get endpoint {
    if (baseUrl.isEmpty || token.isEmpty) {
      throw const SyncRemoteException(
        'Cloud sync is not configured.',
        kind: SyncRemoteFailureKind.unauthorized,
      );
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' &&
            uri.host != '127.0.0.1' &&
            uri.host != 'localhost')) {
      throw const SyncRemoteException(
        'Cloud sync requires HTTPS (localhost is allowed for development).',
        kind: SyncRemoteFailureKind.protocolMismatch,
      );
    }
    return uri;
  }
}

/// API v1 implementation backed by an authenticated Cloudflare Worker.
///
/// Only JSON metadata passes through the Worker. Blob streams use short-lived,
/// operation-specific R2 presigned URLs returned by the authorization routes.
class CloudflareSyncRemote implements SyncRemote {
  CloudflareSyncRemote({
    required this.config,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final CloudflareSyncConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<SyncPushResult> push(SyncPushRequest request) async {
    final json = (await _postJson('/v1/sync/push', {
      'protocolVersion': stashSyncProtocolVersion,
      'mutation': {
        'entityType': request.entity.type.wireValue,
        'entityId': request.entity.id,
        'mutationId': request.mutationId,
        'baseRevision': request.baseRevision,
        'operation': request.operation.wireValue,
        'payload': request.payload,
      },
    }))!;
    _requireProtocol(json);
    final outcome = switch (_string(json, 'outcome')) {
      'accepted' => SyncApplyOutcome.accepted,
      'alreadyApplied' => SyncApplyOutcome.alreadyApplied,
      'conflict' => SyncApplyOutcome.conflict,
      'invalidDependency' => SyncApplyOutcome.invalidDependency,
      final value => throw _protocol('Unknown push outcome: $value'),
    };
    return SyncPushResult(
      outcome: outcome,
      remoteRevision: _nullableInt(json, 'remoteRevision'),
      changeCursor: _nullableInt(json, 'changeCursor'),
      message: _nullableString(json, 'message'),
    );
  }

  @override
  Future<SyncPullResult> pull({
    required int afterCursor,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final uri = _uri('/v1/sync/pull')
        .replace(queryParameters: {'after': '$afterCursor', 'limit': '$limit'});
    final json = await _getJson(uri);
    _requireProtocol(json);
    final rawChanges = json['changes'];
    if (rawChanges is! List) throw _protocol('changes must be an array.');
    final changes = rawChanges
        .map((value) {
          if (value is! Map) throw _protocol('A change must be an object.');
          final entry = Map<String, Object?>.from(value);
          final payload = entry['payload'];
          if (payload is! Map) {
            throw _protocol('Change payload must be an object.');
          }
          return SyncRemoteChange(
            cursor: _integer(entry, 'cursor'),
            entity: SyncEntityKey(
              type: SyncEntityType.fromWireValue(_string(entry, 'entityType')),
              id: _string(entry, 'entityId'),
            ),
            remoteRevision: _integer(entry, 'remoteRevision'),
            operation: SyncOperation.fromWireValue(_string(entry, 'operation')),
            mutationId: _string(entry, 'mutationId'),
            payload: Map<String, Object?>.from(payload),
          );
        })
        .toList(growable: false);
    return SyncPullResult(
      changes: changes,
      nextCursor: _integer(json, 'nextCursor'),
      hasMore: _boolean(json, 'hasMore'),
    );
  }

  @override
  Future<void> putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256,
    required Stream<List<int>> bytes,
  }) async {
    final grant = (await _postJson('/v1/blobs/authorize-upload', {
      'protocolVersion': stashSyncProtocolVersion,
      'attachmentId': attachmentId,
      'byteSize': byteSize,
      'sha256': sha256,
    }))!;
    _requireProtocol(grant);
    final uploadUrl = Uri.tryParse(_string(grant, 'uploadUrl'));
    if (uploadUrl == null || uploadUrl.scheme != 'https') {
      throw _protocol('Upload grant did not contain an HTTPS URL.');
    }
    final request = http.StreamedRequest('PUT', uploadUrl)
      ..contentLength = byteSize;
    final rawHeaders = grant['headers'];
    if (rawHeaders is! Map) throw _protocol('Upload headers are missing.');
    for (final entry in rawHeaders.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw _protocol('Upload headers must be strings.');
      }
      request.headers[entry.key as String] = entry.value as String;
    }
    final upload = request.sink
        .addStream(bytes)
        .then((_) => request.sink.close());
    final response = await _send(request, blob: true);
    await upload;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw SyncRemoteException(
        'R2 rejected the authorized blob upload (${response.statusCode}).',
        kind: SyncRemoteFailureKind.blobFailure,
      );
    }
    await response.stream.drain<void>();
  }

  @override
  Future<SyncBlobDownload?> getBlob(String attachmentId) async {
    final grant = await _postJson('/v1/blobs/authorize-download', {
      'protocolVersion': stashSyncProtocolVersion,
      'attachmentId': attachmentId,
    }, allowNotFound: true);
    if (grant == null) return null;
    _requireProtocol(grant);
    final downloadUrl = Uri.tryParse(_string(grant, 'downloadUrl'));
    if (downloadUrl == null || downloadUrl.scheme != 'https') {
      throw _protocol('Download grant did not contain an HTTPS URL.');
    }
    final response = await _send(http.Request('GET', downloadUrl), blob: true);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw SyncRemoteException(
        'R2 rejected the authorized blob download (${response.statusCode}).',
        kind: SyncRemoteFailureKind.blobFailure,
      );
    }
    return SyncBlobDownload(
      byteSize: _integer(grant, 'byteSize'),
      sha256: _string(grant, 'sha256'),
      bytes: response.stream.timeout(
        timeout,
        onTimeout: (sink) {
          sink.addError(
            const SyncRemoteException(
              'Blob transfer timed out.',
              kind: SyncRemoteFailureKind.blobFailure,
            ),
          );
          sink.close();
        },
      ),
    );
  }

  Uri _uri(String path) => config.endpoint.resolve(path);

  Map<String, String> get _headers => {
    HttpHeaders.authorizationHeader: 'Bearer ${config.token}',
    HttpHeaders.contentTypeHeader: 'application/json',
    HttpHeaders.acceptHeader: 'application/json',
  };

  Future<Map<String, Object?>?> _postJson(
    String path,
    JsonMap body, {
    bool allowNotFound = false,
  }) => _jsonResponse(
    () => _client
        .post(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(timeout),
    allowNotFound: allowNotFound,
  );

  Future<Map<String, Object?>> _getJson(Uri uri) async => (await _jsonResponse(
    () => _client.get(uri, headers: _headers).timeout(timeout),
  ))!;

  Future<Map<String, Object?>?> _jsonResponse(
    Future<http.Response> Function() action, {
    bool allowNotFound = false,
  }) async {
    try {
      final response = await action();
      if (allowNotFound && response.statusCode == 404) return null;
      if (response.statusCode == 401) {
        throw const SyncRemoteException(
          'Cloud sync authorization failed.',
          kind: SyncRemoteFailureKind.unauthorized,
        );
      }
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw _protocol('Remote returned non-JSON data.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded is Map ? decoded['error'] : null;
        throw SyncRemoteException(
          'Cloud sync request failed (${response.statusCode}${code is String ? ', $code' : ''}).',
          kind: response.statusCode >= 500
              ? SyncRemoteFailureKind.serverError
              : SyncRemoteFailureKind.protocolMismatch,
        );
      }
      if (decoded is! Map) {
        throw _protocol('Remote response must be an object.');
      }
      return Map<String, Object?>.from(decoded);
    } on TimeoutException {
      throw const SyncRemoteException(
        'Cloud sync request timed out.',
        kind: SyncRemoteFailureKind.timeout,
      );
    } on SocketException {
      throw const SyncRemoteException(
        'Cloud sync is offline.',
        kind: SyncRemoteFailureKind.offline,
      );
    } on http.ClientException {
      throw const SyncRemoteException(
        'Cloud sync network request failed.',
        kind: SyncRemoteFailureKind.offline,
      );
    }
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request, {
    required bool blob,
  }) async {
    try {
      return await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw SyncRemoteException(
        blob ? 'Blob transfer timed out.' : 'Cloud sync request timed out.',
        kind: blob
            ? SyncRemoteFailureKind.blobFailure
            : SyncRemoteFailureKind.timeout,
      );
    } on SocketException catch (_) {
      throw SyncRemoteException(
        blob ? 'Blob transfer is offline.' : 'Cloud sync is offline.',
        kind: blob
            ? SyncRemoteFailureKind.blobFailure
            : SyncRemoteFailureKind.offline,
      );
    } on http.ClientException catch (_) {
      throw SyncRemoteException(
        blob ? 'Blob transfer failed.' : 'Cloud sync network request failed.',
        kind: blob
            ? SyncRemoteFailureKind.blobFailure
            : SyncRemoteFailureKind.offline,
      );
    }
  }

  void _requireProtocol(JsonMap json) {
    if (json['protocolVersion'] != stashSyncProtocolVersion) {
      throw _protocol('Remote protocol version is not supported.');
    }
  }

  static SyncRemoteException _protocol(String message) => SyncRemoteException(
    message,
    kind: SyncRemoteFailureKind.protocolMismatch,
  );

  static String _string(JsonMap json, String key) {
    final value = json[key];
    if (value is! String) throw _protocol('$key must be a string.');
    return value;
  }

  static String? _nullableString(JsonMap json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) throw _protocol('$key must be a string or null.');
    return value;
  }

  static int _integer(JsonMap json, String key) {
    final value = json[key];
    if (value is! int) throw _protocol('$key must be an integer.');
    return value;
  }

  static int? _nullableInt(JsonMap json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) throw _protocol('$key must be an integer or null.');
    return value;
  }

  static bool _boolean(JsonMap json, String key) {
    final value = json[key];
    if (value is! bool) throw _protocol('$key must be a boolean.');
    return value;
  }
}
