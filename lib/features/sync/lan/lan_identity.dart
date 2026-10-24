import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

class LanLocalIdentity {
  const LanLocalIdentity({
    required this.deviceId,
    required this.relayId,
    required this.pairingSecret,
  });

  final String deviceId;
  final String relayId;
  final String pairingSecret;
}

/// Persists opaque device-local identity outside sync payloads and backups.
class LanIdentityStore {
  const LanIdentityStore(this.directory);

  final Directory directory;

  Future<LanLocalIdentity> loadOrCreate() async {
    await directory.create(recursive: true);
    return LanLocalIdentity(
      deviceId: await _loadOrCreate('device-id', () => const Uuid().v4()),
      relayId: await _loadOrCreate('relay-id', () => const Uuid().v4()),
      pairingSecret: await _loadOrCreate(
        'pairing-secret',
        () => base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ).replaceAll('=', ''),
      ),
    );
  }

  Future<String> _loadOrCreate(String name, String Function() generate) async {
    final file = File(path.join(directory.path, name));
    if (await file.exists()) {
      final value = (await file.readAsString()).trim();
      if (value.isNotEmpty) return value;
      throw StateError('LAN identity file is empty: $name');
    }
    final value = generate();
    final temporary = File('${file.path}.partial');
    await temporary.writeAsString(value, flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      if (!await file.exists()) rethrow;
      await temporary.delete();
      return (await file.readAsString()).trim();
    }
    return value;
  }
}

class PairedLanRelay {
  const PairedLanRelay({
    required this.relayId,
    required this.host,
    required this.port,
    required this.pairingSecret,
    required this.lastSeen,
  });

  final String relayId;
  final String host;
  final int port;
  final String pairingSecret;
  final DateTime lastSeen;
}

class PairedLanRelayStore {
  const PairedLanRelayStore(this.directory);

  final Directory directory;

  File get _file => File(path.join(directory.path, 'paired-relay.json'));

  Future<PairedLanRelay?> load() async {
    if (!await _file.exists()) return null;
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map) throw const FormatException('Invalid paired relay.');
    final json = Map<String, Object?>.from(decoded);
    final relayId = json['relayId'];
    final host = json['host'];
    final port = json['port'];
    final secret = json['pairingSecret'];
    final lastSeen = json['lastSeen'];
    if (relayId is! String ||
        host is! String ||
        port is! int ||
        secret is! String ||
        secret.length < 32 ||
        lastSeen is! String) {
      throw const FormatException('Invalid paired relay fields.');
    }
    return PairedLanRelay(
      relayId: relayId,
      host: host,
      port: port,
      pairingSecret: secret,
      lastSeen: DateTime.parse(lastSeen).toUtc(),
    );
  }

  Future<void> save(PairedLanRelay relay) async {
    await directory.create(recursive: true);
    final temporary = File('${_file.path}.partial');
    await temporary.writeAsString(
      jsonEncode({
        'relayId': relay.relayId,
        'host': relay.host,
        'port': relay.port,
        'pairingSecret': relay.pairingSecret,
        'lastSeen': relay.lastSeen.toUtc().toIso8601String(),
      }),
      flush: true,
    );
    if (await _file.exists()) await _file.delete();
    await temporary.rename(_file.path);
  }
}
