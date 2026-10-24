import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';
import 'sync_wire_codec.dart';

class LanSyncConfig {
  const LanSyncConfig({required this.baseUrl, required this.pairingSecret});

  final String baseUrl;
  final String pairingSecret;

  Uri get endpoint {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) {
      throw const SyncRemoteException(
        'LAN sync requires a DEV HTTP relay URL.',
        kind: SyncRemoteFailureKind.protocolMismatch,
      );
    }
    if (pairingSecret.length < 32) {
      throw const SyncRemoteException(
        'LAN pairing credential is missing or too short.',
        kind: SyncRemoteFailureKind.unauthorized,
      );
    }
    return uri;
  }
}

/// Authenticated HTTP implementation of [SyncRemote] for a paired LAN relay.
///
/// This phase intentionally uses plaintext HTTP and is restricted to DEV on a
/// trusted LAN. Bearer authentication does not encrypt payloads in transit.
class LanSyncRemote implements SyncRemote {
  LanSyncRemote({
    required this._config,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  LanSyncConfig _config;
  LanSyncConfig get config => _config;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _client.close();
  }

  void updateEndpoint({required String host, required int port}) {
    _config = LanSyncConfig(
      baseUrl: 'http://$host:$port/',
      pairingSecret: _config.pairingSecret,
    );
  }

  Future<JsonMap> health() =>
      _getJson(_uri('/v1/health'), authenticated: false);

  @override
  Future<SyncPushResult> push(SyncPushRequest request) async =>
      SyncWireCodec.decodePushResult(
        await _postJson(
          '/v1/sync/push',
          SyncWireCodec.encodePushRequest(request),
        ),
      );

  @override
  Future<SyncPullResult> pull({
    required int afterCursor,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 500) throw ArgumentError.value(limit, 'limit');
    final uri = _uri('/v1/sync/pull')
        .replace(queryParameters: {'after': '$afterCursor', 'limit': '$limit'});
    return SyncWireCodec.decodePullResult(await _getJson(uri));
  }

  @override
  Future<void> putBlob({
    required String attachmentId,
    required int byteSize,
    required String sha256,
    required Stream<List<int>> bytes,
  }) async {
    final request =
        http.StreamedRequest(
            'PUT',
            _uri('/v1/blobs/${Uri.encodeComponent(attachmentId)}'),
          )
          ..contentLength = byteSize
          ..headers.addAll(_headers)
          ..headers['x-stash-sha256'] = sha256;
    try {
      final responseFuture = _client.send(request).timeout(timeout);
      await request.sink.addStream(bytes);
      await request.sink.close();
      final response = await responseFuture;
      if (response.statusCode == HttpStatus.unauthorized) {
        await response.stream.drain<void>();
        throw const SyncRemoteException(
          'LAN relay authorization failed.',
          kind: SyncRemoteFailureKind.unauthorized,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw SyncRemoteException(
          'LAN relay rejected blob upload (${response.statusCode}).',
          kind: SyncRemoteFailureKind.blobFailure,
        );
      }
      await response.stream.drain<void>();
    } on SyncRemoteException {
      rethrow;
    } on TimeoutException {
      throw const SyncRemoteException(
        'LAN blob upload timed out.',
        kind: SyncRemoteFailureKind.timeout,
      );
    } on SocketException {
      throw const SyncRemoteException(
        'LAN relay is unavailable.',
        kind: SyncRemoteFailureKind.relayUnavailable,
      );
    } on http.ClientException {
      throw const SyncRemoteException(
        'LAN blob upload failed.',
        kind: SyncRemoteFailureKind.networkFailure,
      );
    }
  }

  @override
  Future<SyncBlobDownload?> getBlob(String attachmentId) async {
    try {
      final response = await _client
          .send(
            http.Request(
              'GET',
              _uri('/v1/blobs/${Uri.encodeComponent(attachmentId)}'),
            )..headers.addAll(_headers),
          )
          .timeout(timeout);
      if (response.statusCode == HttpStatus.notFound) {
        await response.stream.drain<void>();
        return null;
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        await response.stream.drain<void>();
        throw const SyncRemoteException(
          'LAN relay authorization failed.',
          kind: SyncRemoteFailureKind.unauthorized,
        );
      }
      final byteSize = response.contentLength;
      final checksum = response.headers['x-stash-sha256'];
      if (response.statusCode != HttpStatus.ok ||
          byteSize == null ||
          checksum == null) {
        await response.stream.drain<void>();
        throw SyncRemoteException(
          'LAN relay blob download failed (${response.statusCode}).',
          kind: SyncRemoteFailureKind.blobFailure,
        );
      }
      return SyncBlobDownload(
        byteSize: byteSize,
        sha256: checksum,
        bytes: response.stream.timeout(timeout),
      );
    } on SyncRemoteException {
      rethrow;
    } on TimeoutException {
      throw const SyncRemoteException(
        'LAN blob download timed out.',
        kind: SyncRemoteFailureKind.timeout,
      );
    } on SocketException {
      throw const SyncRemoteException(
        'LAN relay is unavailable.',
        kind: SyncRemoteFailureKind.relayUnavailable,
      );
    } on http.ClientException {
      throw const SyncRemoteException(
        'LAN blob download failed.',
        kind: SyncRemoteFailureKind.networkFailure,
      );
    }
  }

  Uri _uri(String path) => config.endpoint.resolve(path);

  Map<String, String> get _headers => {
    HttpHeaders.authorizationHeader: 'Bearer ${config.pairingSecret}',
    HttpHeaders.acceptHeader: 'application/json',
  };

  Future<JsonMap> _postJson(String path, JsonMap body) => _jsonResponse(
    () => _client
        .post(
          _uri(path),
          headers: {
            ..._headers,
            HttpHeaders.contentTypeHeader: 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout),
  );

  Future<JsonMap> _getJson(Uri uri, {bool authenticated = true}) =>
      _jsonResponse(
        () => _client
            .get(uri, headers: authenticated ? _headers : const {})
            .timeout(timeout),
      );

  Future<JsonMap> _jsonResponse(Future<http.Response> Function() action) async {
    try {
      final response = await action();
      if (response.statusCode == HttpStatus.unauthorized) {
        throw const SyncRemoteException(
          'LAN relay authorization failed.',
          kind: SyncRemoteFailureKind.unauthorized,
        );
      }
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw SyncWireCodec.protocol('LAN relay returned non-JSON data.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded is Map ? decoded['error'] : null;
        throw SyncRemoteException(
          'LAN relay request failed (${response.statusCode}${code is String ? ', $code' : ''}).',
          kind: response.statusCode >= 500
              ? SyncRemoteFailureKind.serverError
              : SyncRemoteFailureKind.protocolMismatch,
        );
      }
      if (decoded is! Map) {
        throw SyncWireCodec.protocol('LAN relay response must be an object.');
      }
      return Map<String, Object?>.from(decoded);
    } on SyncRemoteException {
      rethrow;
    } on TimeoutException {
      throw const SyncRemoteException(
        'LAN relay request timed out.',
        kind: SyncRemoteFailureKind.timeout,
      );
    } on SocketException {
      throw const SyncRemoteException(
        'LAN relay is unavailable.',
        kind: SyncRemoteFailureKind.relayUnavailable,
      );
    } on http.ClientException {
      throw const SyncRemoteException(
        'LAN relay network request failed.',
        kind: SyncRemoteFailureKind.networkFailure,
      );
    }
  }
}
