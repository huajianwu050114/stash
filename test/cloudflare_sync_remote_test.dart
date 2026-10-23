import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stash/features/sync/data/cloudflare_sync_remote.dart';
import 'package:stash/features/sync/domain/sync_models.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = CloudflareSyncConfig(
    baseUrl: 'https://sync.example.test',
    token: 'private-test-token',
  );

  test(
    'push sends authenticated protocol v1 DTO and parses acknowledgement',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/sync/push');
        expect(
          request.headers[HttpHeaders.authorizationHeader],
          'Bearer private-test-token',
        );
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['protocolVersion'], 1);
        expect((body['mutation'] as Map)['entityType'], 'item');
        return http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'outcome': 'accepted',
            'remoteRevision': 1,
            'changeCursor': 7,
          }),
          200,
        );
      });
      final remote = CloudflareSyncRemote(config: config, client: client);
      final result = await remote.push(
        const SyncPushRequest(
          entity: SyncEntityKey(type: SyncEntityType.item, id: 'item'),
          mutationId: 'mutation',
          baseRevision: 0,
          operation: SyncOperation.upsert,
          payload: {'id': 'item'},
        ),
      );
      expect(result.outcome, SyncApplyOutcome.accepted);
      expect(result.remoteRevision, 1);
      expect(result.changeCursor, 7);
    },
  );

  test('pull validates DTOs and exposes pagination metadata', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters, {'after': '4', 'limit': '2'});
      return http.Response(
        jsonEncode({
          'protocolVersion': 1,
          'changes': [
            {
              'cursor': 5,
              'entityType': 'channel',
              'entityId': 'channel',
              'remoteRevision': 1,
              'operation': 'upsert',
              'mutationId': 'mutation',
              'payload': {'id': 'channel'},
            },
          ],
          'nextCursor': 5,
          'hasMore': true,
        }),
        200,
      );
    });
    final result = await CloudflareSyncRemote(
      config: config,
      client: client,
    ).pull(afterCursor: 4, limit: 2);
    expect(result.changes.single.entity.type, SyncEntityType.channel);
    expect(result.nextCursor, 5);
    expect(result.hasMore, isTrue);
  });

  test(
    'protocol mismatch and unauthorized responses are structured failures',
    () async {
      var unauthorized = false;
      final client = MockClient((request) async {
        if (unauthorized) return http.Response('{}', 401);
        return http.Response(
          jsonEncode({'protocolVersion': 99, 'changes': []}),
          200,
        );
      });
      final remote = CloudflareSyncRemote(config: config, client: client);
      await expectLater(
        remote.pull(afterCursor: 0),
        throwsA(
          isA<SyncRemoteException>().having(
            (error) => error.kind,
            'kind',
            SyncRemoteFailureKind.protocolMismatch,
          ),
        ),
      );
      unauthorized = true;
      await expectLater(
        remote.pull(afterCursor: 0),
        throwsA(
          isA<SyncRemoteException>().having(
            (error) => error.kind,
            'kind',
            SyncRemoteFailureKind.unauthorized,
          ),
        ),
      );
    },
  );

  test(
    'blob data uses direct authorized R2 URLs, not the Worker body route',
    () async {
      final calls = <Uri>[];
      final client = MockClient((request) async {
        calls.add(request.url);
        if (request.url.path == '/v1/blobs/authorize-upload') {
          return http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'uploadUrl':
                  'https://bucket.r2.cloudflarestorage.com/object?signed=1',
              'headers': {
                'content-type': 'application/octet-stream',
                'x-amz-meta-sha256': 'checksum',
                'x-amz-meta-byte-size': '4',
              },
            }),
            200,
          );
        }
        if (request.method == 'PUT') {
          expect(request.bodyBytes, [1, 2, 3, 4]);
          expect(request.headers['x-amz-meta-byte-size'], '4');
          return http.Response('', 200);
        }
        if (request.url.path == '/v1/blobs/authorize-download') {
          return http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'downloadUrl':
                  'https://bucket.r2.cloudflarestorage.com/object?signed=2',
              'byteSize': 4,
              'sha256': 'checksum',
            }),
            200,
          );
        }
        expect(request.method, 'GET');
        return http.Response.bytes([1, 2, 3, 4], 200);
      });
      final remote = CloudflareSyncRemote(config: config, client: client);
      await remote.putBlob(
        attachmentId: 'attachment',
        byteSize: 4,
        sha256: 'checksum',
        bytes: Stream.value([1, 2, 3, 4]),
      );
      final download = await remote.getBlob('attachment');
      expect(await download!.bytes.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(
        calls.where((uri) => uri.host == 'sync.example.test'),
        hasLength(2),
      );
      expect(
        calls.where((uri) => uri.host.endsWith('r2.cloudflarestorage.com')),
        hasLength(2),
      );
    },
  );

  test(
    'checked-in protocol fixture decodes with Dart payload models',
    () async {
      final fixture = jsonDecode(
        await File('protocol/fixtures/sync-v1.json').readAsString(),
      ) as Map<String, Object?>;
      expect(fixture['protocolVersion'], stashSyncProtocolVersion);
      for (final key in ['channel', 'item', 'attachment']) {
        final mutation = fixture[key] as Map<String, Object?>;
        expect(
          SyncEntityType.fromWireValue(mutation['entityType']! as String),
          isNotNull,
        );
        expect(mutation['payload'], isA<Map>());
      }
    },
  );
}
