import 'dart:convert';

import '../../quick_stash/data/quick_stash_settings_repository.dart';
import '../domain/quick_channel_configuration.dart';

class QuickChannelConfigurationRepository {
  QuickChannelConfigurationRepository(this._store);

  static const configurationsKey = 'quick_channels.configurations';

  final QuickStashPreferenceStore _store;

  Future<List<QuickChannelConfiguration>> load() async {
    final encoded = await _store.getString(configurationsKey);
    if (encoded == null) return const [];
    try {
      final values = jsonDecode(encoded) as List<dynamic>;
      return values
          .map(
            (value) => QuickChannelConfiguration.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(Iterable<QuickChannelConfiguration> configurations) =>
      _store.setString(
        configurationsKey,
        jsonEncode(configurations.map((value) => value.toJson()).toList()),
      );
}
