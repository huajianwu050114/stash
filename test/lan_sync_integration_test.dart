import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:stash/app/app_profile.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/core/storage/app_storage_paths.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/sync/application/sync_engine.dart';
import 'package:stash/features/sync/application/auto_sync_coordinator.dart';
import 'package:stash/features/sync/application/lan_dev_sync_runtime.dart';
import 'package:stash/features/sync/data/lan_sync_remote.dart';
import 'package:stash/features/sync/data/sync_outbox_repository.dart';
import 'package:stash/features/sync/data/sync_wire_codec.dart';
import 'package:stash/features/sync/domain/sync_models.dart';
import 'package:stash/features/sync/domain/sync_payloads.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:stash/features/sync/lan/lan_discovery.dart';
import 'package:stash/features/sync/lan/lan_identity.dart';
import 'package:stash/features/sync/lan/lan_relay_server.dart';
import 'package:stash/features/sync/lan/persistent_lan_relay_store.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef0123456789abcdef';

  group('persistent LAN relay over real HTTP', () {
    late Directory root;
    late File relayDatabase;
    late Directory relayBlobs;
    late PersistentLanRelayStore store;
    late LanRelayServer server;
    final remotes = <LanSyncRemote>[];
    final devices = <_LanDevice>[];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('stash-lan-integration-');
      relayDatabase = File(path.join(root.path, 'relay', 'lan-relay.sqlite'));
      relayBlobs = Directory(path.join(root.path, 'relay', 'blobs'));
      store = await PersistentLanRelayStore.open(
        databaseFile: relayDatabase,
        blobRoot: relayBlobs,
      );
      server = LanRelayServer(
        store: store,
        relayId: 'relay-integration',
        pairingSecret: secret,
      );
      await server.start(address: InternetAddress.loopbackIPv4);
    });

    tearDown(() async {
      for (final remote in remotes) {
        remote.close();
      }
      for (final device in devices.reversed) {
        await device.close();
      }
      await server.stop();
      store.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    LanSyncRemote remote({String pairingSecret = secret}) {
      final value = LanSyncRemote(
        config: LanSyncConfig(
          baseUrl: server.loopbackBaseUri.toString(),
          pairingSecret: pairingSecret,
        ),
      );
      remotes.add(value);
      return value;
    }

    test(
      'A pushes, relay restarts, and later B reconstructs independent data',
      () async {
        final health = await remote().health();
        expect(health['protocolVersion'], stashSyncProtocolVersion);
        expect(health['relayId'], 'relay-integration');
        await expectLater(
          remote(pairingSecret: 'wrong-secret-that-is-still-long-enough-0000')
              .pull(afterCursor: 0),
          throwsA(
            isA<SyncRemoteException>().having(
              (error) => error.kind,
              'kind',
              SyncRemoteFailureKind.unauthorized,
            ),
          ),
        );

        final aRoot = Directory(path.join(root.path, 'device-a'));
        final a = await _LanDevice.open(aRoot, remote());
        devices.add(a);
        await a.channels.createRootChannel(id: 'papers', name: '论文');
        final source = File(path.join(root.path, 'test.pdf'));
        final expectedBytes = Uint8List.fromList(
          List<int>.generate(8192, (index) => index % 251),
        );
        await source.writeAsBytes(expectedBytes);
        await a.attachments.importFile(
          id: 'test-pdf',
          itemId: 'lan-item',
          sourceFile: source,
          mimeType: 'application/pdf',
        );
        final attachment = await (a.db.select(
          a.db.attachments,
        )..where((row) => row.id.equals('test-pdf'))).getSingle();
        final customRelativePath = path.join('attachments', 'a-local-name.pdf');
        await File(path.join(aRoot.path, attachment.relativePath))
            .rename(path.join(aRoot.path, customRelativePath));
        await (a.db.update(
          a.db.attachments,
        )..where((row) => row.id.equals('test-pdf'))).write(
          AttachmentsCompanion(relativePath: Value(customRelativePath)),
        );
        await a.items.createItem(
          id: 'lan-item',
          content: 'LAN sync test',
          channelId: 'papers',
          document: const ItemDocumentCodec().snapshot(
            Document.fromJson([
              {'insert': 'LAN sync test'},
              {
                'insert': BlockEmbed.custom(StashFileEmbed('test-pdf'))
                    .toJson(),
              },
              {'insert': '\n'},
            ]),
          ),
        );

        final pushed = await a.engine.syncOnce();
        expect(pushed.errors, isEmpty);
        expect(pushed.remainingPending, 0);
        expect(store.changeCount, 3);
        expect(
          await relayBlobs
              .list(recursive: true)
              .where(
                (entry) => entry is File && !entry.path.endsWith('.partial'),
              )
              .isEmpty,
          isFalse,
        );

        await a.close();
        devices.remove(a);
        await server.stop();
        store.close();

        store = await PersistentLanRelayStore.open(
          databaseFile: relayDatabase,
          blobRoot: relayBlobs,
        );
        expect(store.changeCount, 3);
        server = LanRelayServer(
          store: store,
          relayId: 'relay-integration',
          pairingSecret: secret,
        );
        await server.start(address: InternetAddress.loopbackIPv4);

        final bRoot = Directory(path.join(root.path, 'device-b'));
        final b = await _LanDevice.open(bRoot, remote());
        devices.add(b);
        final pulled = await b.engine.syncOnce();
        expect(pulled.errors, isEmpty);
        expect(pulled.pulled, 3);
        final channel = await (b.db.select(
          b.db.channels,
        )..where((row) => row.id.equals('papers'))).getSingle();
        final item = await (b.db.select(
          b.db.items,
        )..where((row) => row.id.equals('lan-item'))).getSingle();
        final pulledAttachment = await (b.db.select(
          b.db.attachments,
        )..where((row) => row.id.equals('test-pdf'))).getSingle();
        expect(channel.name, '论文');
        expect(item.content, 'LAN sync test');
        expect(item.channelId, channel.id);
        expect(pulledAttachment.itemId, item.id);
        expect(pulledAttachment.relativePath, isNot(customRelativePath));
        final downloaded = File(
          path.join(bRoot.path, pulledAttachment.relativePath),
        );
        expect(await downloaded.readAsBytes(), expectedBytes);
        expect(
          (await sha256.bind(downloaded.openRead()).first).toString(),
          sha256.convert(expectedBytes).toString(),
        );

        final reopenedA = await _LanDevice.open(aRoot, remote());
        devices.add(reopenedA);
        await reopenedA.items.updateItem('lan-item', content: 'edit from A');
        await b.items.updateItem('lan-item', content: 'edit from B');
        final aEdit = await reopenedA.engine.syncOnce();
        expect(aEdit.errors, isEmpty);
        final bConflict = await b.engine.syncOnce();
        expect(
          bConflict.errors.any((error) => error.stage == 'push-conflict'),
          isTrue,
        );
        expect(bConflict.conflicts, isNotEmpty);
        expect(
          (await (b.db.select(
            b.db.items,
          )..where((row) => row.id.equals('lan-item'))).getSingle()).content,
          'edit from B',
        );
        expect(await b.outbox.readPending(), isNotEmpty);
        expect(
          store.revisionFor(
            const SyncEntityKey(type: SyncEntityType.item, id: 'lan-item'),
          ),
          2,
        );
      },
    );

    test('lost push response retries idempotently over the network', () async {
      final lan = remote();
      final now = DateTime.utc(2026);
      final owner = SyncPushRequest(
        entity: const SyncEntityKey(
          type: SyncEntityType.item,
          id: 'retry-item',
        ),
        mutationId: 'retry-owner-mutation',
        baseRevision: 0,
        operation: SyncOperation.upsert,
        payload: ItemSyncPayload(
          id: 'retry-item',
          title: null,
          content: 'retry',
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
      );
      expect((await lan.push(owner)).wasAccepted, isTrue);
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final checksum = sha256.convert(bytes).toString();
      for (var retry = 0; retry < 2; retry++) {
        await lan.putBlob(
          attachmentId: 'retry-attachment',
          byteSize: bytes.length,
          sha256: checksum,
          bytes: Stream.value(bytes),
        );
      }
      final request = SyncPushRequest(
        entity: const SyncEntityKey(
          type: SyncEntityType.attachment,
          id: 'retry-attachment',
        ),
        mutationId: 'retry-attachment-mutation',
        baseRevision: 0,
        operation: SyncOperation.upsert,
        payload: AttachmentSyncPayload(
          id: 'retry-attachment',
          itemId: 'retry-item',
          mimeType: 'application/pdf',
          originalFileName: 'retry.pdf',
          byteSize: bytes.length,
          sha256: checksum,
          createdAt: now,
          deletedAt: null,
          serverRevision: 0,
        ).toJson(),
      );
      server.dropNextPushResponse = true;
      await expectLater(lan.push(request), throwsA(isA<SyncRemoteException>()));
      final retried = await lan.push(request);
      expect(retried.outcome, SyncApplyOutcome.alreadyApplied);
      expect(retried.remoteRevision, 1);
      expect(store.changeCount, 2);
      final committedBlobFiles = await relayBlobs
          .list(recursive: true)
          .where((entry) => entry is File)
          .toList();
      expect(committedBlobFiles, hasLength(1));
    });
  });

  test('identity is random, durable, and stored outside user data', () async {
    final root = await Directory.systemTemp.createTemp('stash-lan-identity-');
    addTearDown(() => root.delete(recursive: true));
    final identityDirectory = Directory(
      path.join(root.path, 'sync', 'identity'),
    );
    final store = LanIdentityStore(identityDirectory);
    final first = await store.loadOrCreate();
    final second = await store.loadOrCreate();
    expect(second.deviceId, first.deviceId);
    expect(second.relayId, first.relayId);
    expect(second.pairingSecret, first.pairingSecret);
    expect(first.deviceId, isNot(first.relayId));
    expect(first.pairingSecret.length, greaterThanOrEqualTo(43));
    expect(identityDirectory.path, contains(path.join('sync', 'identity')));
    final pairs = PairedLanRelayStore(identityDirectory);
    final paired = PairedLanRelay(
      relayId: first.relayId,
      host: '192.0.2.1',
      port: 4242,
      pairingSecret: first.pairingSecret,
      lastSeen: DateTime.utc(2026),
    );
    await pairs.save(paired);
    final restored = await pairs.load();
    expect(restored?.relayId, paired.relayId);
    expect(restored?.host, paired.host);
    expect(restored?.pairingSecret, paired.pairingSecret);
  });

  test(
    'a local Item reaches the relay automatically without manual sync',
    () async {
      final support = await Directory.systemTemp.createTemp('stash-lan-auto-');
      final storage = AppStoragePaths.fromSupportDirectory(
        profile: AppProfile.dev,
        supportDirectory: support,
      );
      await storage.ensureCreated();
      final database = AppDatabase(NativeDatabase(storage.databaseFile));
      final runtime = await LanDevSyncRuntime.startIfConfigured(
        profile: AppProfile.dev,
        database: database,
        storage: storage,
        environment: const {
          'STASH_LAN_ENABLED': '1',
          'STASH_LAN_ROLE': 'relay',
          'STASH_LAN_PAIRING_SECRET': secret,
        },
        observeAppLifecycle: false,
      );
      expect(runtime, isNotNull);
      try {
        await _waitUntil(
          () => runtime!.coordinator.status.state == AutoSyncState.upToDate,
        );
        await ItemRepository(database)
            .createItem(id: 'automatic-item', content: 'automatic LAN sync');
        await _waitUntil(() {
          final revision = runtime!.store!.revisionFor(
            const SyncEntityKey(
              type: SyncEntityType.item,
              id: 'automatic-item',
            ),
          );
          return revision == 1 &&
              runtime.coordinator.status.state == AutoSyncState.upToDate;
        });
        expect(await SyncOutboxRepository(database).readPending(), isEmpty);
        expect(runtime!.coordinator.status.state, AutoSyncState.upToDate);
      } finally {
        await runtime?.dispose();
        await database.close();
        if (await support.exists()) await support.delete(recursive: true);
      }
    },
  );

  test(
    'UDP DEV discovery reports relay identity, version, and dynamic port',
    () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final discovery = UdpLanRelayDiscovery(
        discoveryPort: port,
        bindAddress: InternetAddress.loopbackIPv4,
        staleAfter: const Duration(seconds: 2),
      );
      final advertiser = UdpLanRelayAdvertiser(
        relayId: 'udp-relay',
        relayPort: 43210,
        discoveryPort: port,
        destination: InternetAddress.loopbackIPv4,
        interval: const Duration(milliseconds: 100),
      );
      addTearDown(discovery.dispose);
      addTearDown(advertiser.dispose);
      await discovery.start();
      final found = discovery.changes.firstWhere((event) => event.available);
      await advertiser.start();
      final event = await found.timeout(const Duration(seconds: 3));
      expect(event.relay.relayId, 'udp-relay');
      expect(event.relay.protocolVersion, stashSyncProtocolVersion);
      expect(event.relay.port, 43210);
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _LanDevice {
  _LanDevice._(this.root, this.db, SyncRemote remote)
    : channels = ChannelRepository(db),
      items = ItemRepository(db),
      attachments = AttachmentRepository(db, storageRoot: root),
      outbox = SyncOutboxRepository(db),
      engine = SyncEngine(remote, database: db, storageRoot: root);

  static Future<_LanDevice> open(Directory root, SyncRemote remote) async {
    await root.create(recursive: true);
    final database = AppDatabase(
      NativeDatabase(File(path.join(root.path, 'device.sqlite'))),
    );
    await database.customSelect('SELECT 1').get();
    return _LanDevice._(root, database, remote);
  }

  final Directory root;
  final AppDatabase db;
  final ChannelRepository channels;
  final ItemRepository items;
  final AttachmentRepository attachments;
  final SyncOutboxRepository outbox;
  final SyncEngine engine;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await db.close();
  }
}
