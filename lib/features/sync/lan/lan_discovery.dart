import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/sync_wire_codec.dart';

const int stashLanDiscoveryPort = 53539;

class LanRelayAdvertisement {
  const LanRelayAdvertisement({
    required this.relayId,
    required this.protocolVersion,
    required this.host,
    required this.port,
    this.label,
  });

  final String relayId;
  final int protocolVersion;
  final String host;
  final int port;
  final String? label;
}

class LanRelayAvailability {
  const LanRelayAvailability({required this.relay, required this.available});

  final LanRelayAdvertisement relay;
  final bool available;
}

abstract interface class LanRelayDiscovery {
  Stream<LanRelayAvailability> get changes;
  Future<void> start();
  Future<void> dispose();
}

/// Filters discovery to one explicitly paired relay identity. Unknown relays
/// are observed by the transport but never become trusted sync targets.
class TrustedLanRelayDiscovery implements LanRelayDiscovery {
  TrustedLanRelayDiscovery({
    required this._source,
    required this.trustedRelayId,
  });

  final LanRelayDiscovery _source;
  final String trustedRelayId;
  final _controller = StreamController<LanRelayAvailability>.broadcast();
  StreamSubscription<LanRelayAvailability>? _subscription;

  @override
  Stream<LanRelayAvailability> get changes => _controller.stream;

  @override
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _source.changes
        .where((event) => event.relay.relayId == trustedRelayId)
        .listen(_controller.add);
    await _source.start();
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _source.dispose();
    await _controller.close();
  }
}

/// Minimal UDP discovery used for DEV while mDNS/DNS-SD support remains a
/// production follow-up. Advertisements contain identity and routing only.
class UdpLanRelayDiscovery implements LanRelayDiscovery {
  UdpLanRelayDiscovery({
    this.discoveryPort = stashLanDiscoveryPort,
    this.staleAfter = const Duration(seconds: 6),
    InternetAddress? bindAddress,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final int discoveryPort;
  final Duration staleAfter;
  final InternetAddress bindAddress;
  final _controller = StreamController<LanRelayAvailability>.broadcast();
  final Map<String, ({LanRelayAdvertisement relay, DateTime seen})> _seen = {};
  RawDatagramSocket? _socket;
  Timer? _expiryTimer;

  @override
  Stream<LanRelayAvailability> get changes => _controller.stream;

  @override
  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      bindAddress,
      discoveryPort,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        _accept(datagram!);
      }
    });
    _expiryTimer = Timer.periodic(staleAfter ~/ 2, (_) => _expire());
  }

  void _accept(Datagram datagram) {
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map || decoded['service'] != '_stash-sync._tcp') return;
      final relayId = decoded['relayId'];
      final version = decoded['protocolVersion'];
      final port = decoded['port'];
      final label = decoded['label'];
      if (relayId is! String ||
          version is! int ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          (label != null && label is! String)) {
        return;
      }
      final relay = LanRelayAdvertisement(
        relayId: relayId,
        protocolVersion: version,
        host: datagram.address.address,
        port: port,
        label: label as String?,
      );
      final previous = _seen[relayId];
      _seen[relayId] = (relay: relay, seen: DateTime.now());
      if (previous == null ||
          previous.relay.host != relay.host ||
          previous.relay.port != relay.port) {
        _controller.add(LanRelayAvailability(relay: relay, available: true));
      }
    } catch (_) {}
  }

  void _expire() {
    final threshold = DateTime.now().subtract(staleAfter);
    for (final entry in _seen.entries.toList(growable: false)) {
      if (entry.value.seen.isAfter(threshold)) continue;
      _seen.remove(entry.key);
      _controller.add(
        LanRelayAvailability(relay: entry.value.relay, available: false),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _socket?.close();
    _socket = null;
    await _controller.close();
  }
}

class UdpLanRelayAdvertiser {
  UdpLanRelayAdvertiser({
    required this.relayId,
    required this.relayPort,
    this.label,
    this.discoveryPort = stashLanDiscoveryPort,
    this.interval = const Duration(seconds: 2),
    InternetAddress? destination,
  }) : destination = destination ?? InternetAddress('255.255.255.255');

  final String relayId;
  final int relayPort;
  final String? label;
  final int discoveryPort;
  final Duration interval;
  final InternetAddress destination;
  RawDatagramSocket? _socket;
  Timer? _timer;

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _socket = socket;
    _advertise();
    _timer = Timer.periodic(interval, (_) => _advertise());
  }

  void _advertise() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'service': '_stash-sync._tcp',
        'protocolVersion': stashSyncProtocolVersion,
        'relayId': relayId,
        'port': relayPort,
        if (label != null) 'label': label,
      }),
    );
    socket.send(payload, destination, discoveryPort);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}
