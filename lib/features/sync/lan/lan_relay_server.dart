import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/sync_wire_codec.dart';
import '../domain/sync_models.dart';
import '../domain/sync_payloads.dart';
import '../domain/sync_protocol.dart';
import 'persistent_lan_relay_store.dart';

/// Small authenticated DEV/trusted-LAN HTTP server.
///
/// Authentication prevents anonymous access but does not encrypt traffic.
/// Production LAN sync must add TLS with a pinned persistent relay identity.
class LanRelayServer {
  LanRelayServer({
    required this.store,
    required this.relayId,
    required String pairingSecret,
  }) : _pairingSecret = pairingSecret {
    if (relayId.isEmpty || pairingSecret.length < 32) {
      throw ArgumentError(
        'Relay identity and a strong pairing secret required.',
      );
    }
  }

  final PersistentLanRelayStore store;
  final String relayId;
  final String _pairingSecret;
  HttpServer? _server;

  /// Test-only fault injection: commit one push, then drop its HTTP response.
  bool dropNextPushResponse = false;
  void Function()? onRemoteChange;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;
  Uri get loopbackBaseUri => Uri.parse('http://127.0.0.1:$port/');

  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) return;
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: false,
    );
    _server = server;
    unawaited(_serve(server));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/v1/health' && request.method == 'GET') {
        await _json(request.response, HttpStatus.ok, {
          'protocolVersion': stashSyncProtocolVersion,
          'relayId': relayId,
        });
        return;
      }
      if (!_authorized(request)) {
        await _json(request.response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
        });
        return;
      }
      if (path == '/v1/sync/push' && request.method == 'POST') {
        final push = SyncWireCodec.decodePushRequest(await _readJson(request));
        final result = await store.push(push);
        if (result.outcome == SyncApplyOutcome.accepted) onRemoteChange?.call();
        if (dropNextPushResponse) {
          dropNextPushResponse = false;
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }
        await _json(
          request.response,
          HttpStatus.ok,
          SyncWireCodec.encodePushResult(result),
        );
        return;
      }
      if (path == '/v1/sync/pull' && request.method == 'GET') {
        final after = int.tryParse(request.uri.queryParameters['after'] ?? '');
        final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '');
        if (after == null || limit == null) {
          await _json(request.response, HttpStatus.badRequest, {
            'error': 'invalidQuery',
          });
          return;
        }
        final result = await store.pull(afterCursor: after, limit: limit);
        await _json(
          request.response,
          HttpStatus.ok,
          SyncWireCodec.encodePullResult(result),
        );
        return;
      }
      if (path.startsWith('/v1/blobs/')) {
        final attachmentId = Uri.decodeComponent(
          path.substring('/v1/blobs/'.length),
        );
        if (attachmentId.isEmpty || attachmentId.contains('/')) {
          await _json(request.response, HttpStatus.badRequest, {
            'error': 'invalidAttachmentId',
          });
          return;
        }
        if (request.method == 'PUT') {
          final byteSize = request.contentLength;
          final checksum = request.headers.value('x-stash-sha256');
          if (byteSize < 0 || checksum == null) {
            await _json(request.response, HttpStatus.badRequest, {
              'error': 'missingBlobMetadata',
            });
            return;
          }
          await store.putBlob(
            attachmentId: attachmentId,
            byteSize: byteSize,
            sha256Value: checksum,
            bytes: request,
          );
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          final blob = await store.getBlob(attachmentId);
          if (blob == null) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..headers.contentLength = blob.byteSize
            ..headers.set('x-stash-sha256', blob.sha256);
          await request.response.addStream(blob.bytes);
          await request.response.close();
          return;
        }
      }
      await _json(request.response, HttpStatus.notFound, {'error': 'notFound'});
    } on FormatException catch (error) {
      await _safeJson(request.response, HttpStatus.badRequest, {
        'error': 'invalidRequest',
        'message': error.message,
      });
    } on ArgumentError {
      await _safeJson(request.response, HttpStatus.badRequest, {
        'error': 'invalidRequest',
      });
    } on SyncRemoteException catch (error) {
      await _safeJson(request.response, HttpStatus.unprocessableEntity, {
        'error': error.kind?.name ?? 'relayFailure',
      });
    } catch (_) {
      await _safeJson(request.response, HttpStatus.internalServerError, {
        'error': 'relayFailure',
      });
    }
  }

  bool _authorized(HttpRequest request) {
    final value = request.headers.value(HttpHeaders.authorizationHeader);
    if (value == null || !value.startsWith('Bearer ')) return false;
    final supplied = utf8.encode(value.substring('Bearer '.length));
    final expected = utf8.encode(_pairingSecret);
    var difference = supplied.length ^ expected.length;
    final length = supplied.length > expected.length
        ? supplied.length
        : expected.length;
    for (var index = 0; index < length; index++) {
      difference |=
          (index < supplied.length ? supplied[index] : 0) ^
          (index < expected.length ? expected[index] : 0);
    }
    return difference == 0;
  }

  static Future<JsonMap> _readJson(HttpRequest request) async {
    if (request.contentLength > 2 * 1024 * 1024) {
      throw const FormatException('JSON request is too large.');
    }
    final decoded = jsonDecode(await utf8.decoder.bind(request).join());
    if (decoded is! Map) throw const FormatException('Expected JSON object.');
    return Map<String, Object?>.from(decoded);
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    JsonMap body,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  static Future<void> _safeJson(
    HttpResponse response,
    int status,
    JsonMap body,
  ) async {
    try {
      await _json(response, status, body);
    } catch (_) {}
  }
}
