import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:stash/features/sync/data/lan_sync_remote.dart';
import 'package:stash/features/sync/domain/sync_models.dart';
import 'package:stash/features/sync/domain/sync_payloads.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:stash/features/sync/lan/lan_identity.dart';
import 'package:stash/features/sync/lan/lan_relay_server.dart';
import 'package:stash/features/sync/lan/persistent_lan_relay_store.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('stash-lan-smoke-');
  final database = File(path.join(root.path, 'relay', 'lan-relay.sqlite'));
  final blobs = Directory(path.join(root.path, 'relay', 'blobs'));
  PersistentLanRelayStore? store;
  LanRelayServer? server;
  LanSyncRemote? remote;
  try {
    final identity = await LanIdentityStore(
      Directory(path.join(root.path, 'identity')),
    ).loadOrCreate();
    store = await PersistentLanRelayStore.open(
      databaseFile: database,
      blobRoot: blobs,
    );
    server = LanRelayServer(
      store: store,
      relayId: identity.relayId,
      pairingSecret: identity.pairingSecret,
    );
    await server.start(address: InternetAddress.loopbackIPv4);
    remote = LanSyncRemote(
      config: LanSyncConfig(
        baseUrl: server.loopbackBaseUri.toString(),
        pairingSecret: identity.pairingSecret,
      ),
    );
    final now = DateTime.now().toUtc();
    final item = await remote.push(
      SyncPushRequest(
        entity: const SyncEntityKey(
          type: SyncEntityType.item,
          id: 'smoke-item',
        ),
        mutationId: 'smoke-item-mutation',
        baseRevision: 0,
        operation: SyncOperation.upsert,
        payload: ItemSyncPayload(
          id: 'smoke-item',
          title: null,
          content: 'LAN smoke',
          note: null,
          channelId: null,
          documentJson: null,
          tags: const [],
          isPinned: false,
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          serverRevision: 0,
        ).toJson(),
      ),
    );
    if (!item.wasAccepted) throw StateError('Item push was rejected.');

    final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
    final checksum = sha256.convert(bytes).toString();
    await remote.putBlob(
      attachmentId: 'smoke-attachment',
      byteSize: bytes.length,
      sha256: checksum,
      bytes: Stream.value(bytes),
    );
    final attachment = await remote.push(
      SyncPushRequest(
        entity: const SyncEntityKey(
          type: SyncEntityType.attachment,
          id: 'smoke-attachment',
        ),
        mutationId: 'smoke-attachment-mutation',
        baseRevision: 0,
        operation: SyncOperation.upsert,
        payload: AttachmentSyncPayload(
          id: 'smoke-attachment',
          itemId: 'smoke-item',
          mimeType: 'application/pdf',
          originalFileName: 'smoke.pdf',
          byteSize: bytes.length,
          sha256: checksum,
          createdAt: now,
          deletedAt: null,
          serverRevision: 0,
        ).toJson(),
      ),
    );
    if (!attachment.wasAccepted) {
      throw StateError('Attachment push was rejected.');
    }

    remote.close();
    remote = null;
    await server.stop();
    server = null;
    store.close();
    store = null;

    store = await PersistentLanRelayStore.open(
      databaseFile: database,
      blobRoot: blobs,
    );
    server = LanRelayServer(
      store: store,
      relayId: identity.relayId,
      pairingSecret: identity.pairingSecret,
    );
    await server.start(address: InternetAddress.loopbackIPv4);
    remote = LanSyncRemote(
      config: LanSyncConfig(
        baseUrl: server.loopbackBaseUri.toString(),
        pairingSecret: identity.pairingSecret,
      ),
    );
    final pulled = await remote.pull(afterCursor: 0);
    final blob = await remote.getBlob('smoke-attachment');
    if (pulled.changes.length != 2 || blob == null) {
      throw StateError('Relay restart did not preserve smoke data.');
    }
    final downloadedChecksum = await sha256.bind(blob.bytes).first;
    if (downloadedChecksum.toString() != checksum) {
      throw StateError('Downloaded blob checksum differs.');
    }
    stdout.writeln('LAN relay smoke PASS');
    stdout.writeln('protocol=1 changes=2 restart=persistent blobSha256=PASS');
  } finally {
    remote?.close();
    await server?.stop();
    store?.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
