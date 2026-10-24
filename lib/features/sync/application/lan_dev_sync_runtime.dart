import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../../app/app_profile.dart';
import '../../../core/database/app_database.dart';
import '../../../core/storage/app_storage_paths.dart';
import '../data/lan_sync_remote.dart';
import '../lan/lan_discovery.dart';
import '../lan/lan_identity.dart';
import '../lan/lan_relay_server.dart';
import '../lan/persistent_lan_relay_store.dart';
import 'auto_sync_coordinator.dart';
import 'sync_engine.dart';

/// DEV-only composition root for the LAN relay and automatic sync services.
/// Normal builds remain disabled unless STASH_LAN_ENABLED=1 is explicitly set.
class LanDevSyncRuntime with WidgetsBindingObserver {
  LanDevSyncRuntime._({
    required this.coordinator,
    required this.remote,
    required this.outboxSubscription,
    required this.observingAppLifecycle,
    this.store,
    this.server,
    this.advertiser,
    this.discovery,
    this.discoverySubscription,
  });

  final AutoSyncCoordinator coordinator;
  final LanSyncRemote remote;
  final StreamSubscription<List<SyncOutboxEntry>> outboxSubscription;
  final PersistentLanRelayStore? store;
  final LanRelayServer? server;
  final UdpLanRelayAdvertiser? advertiser;
  final LanRelayDiscovery? discovery;
  final StreamSubscription<LanRelayAvailability>? discoverySubscription;
  final bool observingAppLifecycle;

  static Future<LanDevSyncRuntime?> startIfConfigured({
    required AppProfile profile,
    required AppDatabase database,
    required AppStoragePaths storage,
    Map<String, String>? environment,
    bool observeAppLifecycle = true,
  }) async {
    final env = environment ?? Platform.environment;
    if (!profile.isDevelopment || env['STASH_LAN_ENABLED'] != '1') return null;
    final role = env['STASH_LAN_ROLE'];
    if (role != 'relay' && role != 'client') {
      throw StateError('STASH_LAN_ROLE must be relay or client.');
    }
    final identity = await LanIdentityStore(storage.lanIdentityDirectory)
        .loadOrCreate();
    final injectedSecret = env['STASH_LAN_PAIRING_SECRET'];

    PersistentLanRelayStore? store;
    LanRelayServer? server;
    UdpLanRelayAdvertiser? advertiser;
    LanRelayDiscovery? discovery;
    StreamSubscription<LanRelayAvailability>? discoverySubscription;
    PairedLanRelayStore? pairedStore;
    PairedLanRelay? pairedRelay;
    late final LanSyncRemote remote;

    if (role == 'relay') {
      final secret = injectedSecret?.isNotEmpty == true
          ? injectedSecret!
          : identity.pairingSecret;
      if (secret.length < 32) {
        throw StateError(
          'STASH_LAN_PAIRING_SECRET must contain 256-bit material.',
        );
      }
      store = await PersistentLanRelayStore.open(
        databaseFile: storage.lanRelayDatabaseFile,
        blobRoot: storage.lanRelayBlobDirectory,
      );
      server = LanRelayServer(
        store: store,
        relayId: identity.relayId,
        pairingSecret: secret,
      );
      final configuredPort = int.tryParse(env['STASH_LAN_PORT'] ?? '') ?? 0;
      await server.start(port: configuredPort);
      remote = LanSyncRemote(
        config: LanSyncConfig(
          baseUrl: server.loopbackBaseUri.toString(),
          pairingSecret: secret,
        ),
      );
      advertiser = UdpLanRelayAdvertiser(
        relayId: identity.relayId,
        relayPort: server.port,
        label: env['STASH_LAN_DEVICE_LABEL'],
      );
      await advertiser.start();
    } else {
      final relayId = env['STASH_LAN_RELAY_ID'];
      final initialHost = env['STASH_LAN_RELAY_HOST'];
      final initialPort = int.tryParse(env['STASH_LAN_RELAY_PORT'] ?? '');
      pairedStore = PairedLanRelayStore(storage.lanIdentityDirectory);
      if (relayId != null &&
          initialHost != null &&
          initialPort != null &&
          injectedSecret != null) {
        pairedRelay = PairedLanRelay(
          relayId: relayId,
          host: initialHost,
          port: initialPort,
          pairingSecret: injectedSecret,
          lastSeen: DateTime.now().toUtc(),
        );
        await pairedStore.save(pairedRelay);
      } else {
        pairedRelay = await pairedStore.load();
      }
      final configuredPair = pairedRelay;
      if (configuredPair == null || configuredPair.pairingSecret.length < 32) {
        throw StateError(
          'Client role requires securely paired relay configuration.',
        );
      }
      remote = LanSyncRemote(
        config: LanSyncConfig(
          baseUrl: 'http://${configuredPair.host}:${configuredPair.port}/',
          pairingSecret: configuredPair.pairingSecret,
        ),
      );
      discovery = TrustedLanRelayDiscovery(
        source: UdpLanRelayDiscovery(),
        trustedRelayId: configuredPair.relayId,
      );
    }

    final engine = SyncEngine(
      remote,
      database: database,
      storageRoot: storage.root,
    );
    await engine.bootstrapLocalReplicaForSync();
    final coordinator = AutoSyncCoordinator(syncOnce: engine.syncOnce);
    coordinator.start();

    if (server != null) {
      server.onRemoteChange = coordinator.notifyRelayDiscovered;
    }
    if (discovery != null) {
      discoverySubscription = discovery.changes.listen((event) async {
        if (!event.available) return;
        remote.updateEndpoint(host: event.relay.host, port: event.relay.port);
        pairedRelay = PairedLanRelay(
          relayId: event.relay.relayId,
          host: event.relay.host,
          port: event.relay.port,
          pairingSecret: remote.config.pairingSecret,
          lastSeen: DateTime.now().toUtc(),
        );
        await pairedStore?.save(pairedRelay!);
        coordinator.notifyRelayDiscovered();
      });
      await discovery.start();
    }

    Set<String>? previousMutationIds;
    final outboxSubscription = database
        .select(database.syncOutbox)
        .watch()
        .listen((rows) {
          final mutationIds = rows.map((row) => row.mutationId).toSet();
          final previous = previousMutationIds;
          if (previous != null && mutationIds.difference(previous).isNotEmpty) {
            coordinator.notifyLocalMutation();
          }
          previousMutationIds = mutationIds;
        });
    final runtime = LanDevSyncRuntime._(
      coordinator: coordinator,
      remote: remote,
      outboxSubscription: outboxSubscription,
      observingAppLifecycle: observeAppLifecycle,
      store: store,
      server: server,
      advertiser: advertiser,
      discovery: discovery,
      discoverySubscription: discoverySubscription,
    );
    if (observeAppLifecycle) WidgetsBinding.instance.addObserver(runtime);
    return runtime;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) coordinator.notifyAppForeground();
  }

  Future<void> dispose() async {
    if (observingAppLifecycle) WidgetsBinding.instance.removeObserver(this);
    server?.onRemoteChange = null;
    await outboxSubscription.cancel();
    await discoverySubscription?.cancel();
    await coordinator.dispose();
    await discovery?.dispose();
    await advertiser?.dispose();
    await server?.stop();
    store?.close();
    remote.close();
  }
}
