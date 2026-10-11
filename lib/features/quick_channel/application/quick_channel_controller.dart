import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../platform/global_hotkey/global_hotkey_service.dart';
import '../../channels/data/channel_repository.dart';
import '../../quick_stash/application/quick_stash_settings_controller.dart';
import '../../quick_stash/domain/quick_stash_settings.dart';
import '../data/quick_channel_configuration_repository.dart';
import '../domain/quick_channel_configuration.dart';

class QuickChannelController extends ChangeNotifier {
  factory QuickChannelController({
    required QuickChannelConfigurationRepository repository,
    required ChannelRepository channels,
    required GlobalHotkeyService hotkeys,
    required QuickStashSettingsController quickStashSettings,
    required void Function(String channelId) onGlobalShortcut,
  }) => QuickChannelController._(
    repository,
    channels,
    hotkeys,
    quickStashSettings,
    onGlobalShortcut,
  );

  QuickChannelController._(
    this._repository,
    this._channels,
    this._hotkeys,
    this._quickStashSettings,
    this._onGlobalShortcut,
  ) {
    _quickStashSettings.setShortcutConflictChecker(_conflictsWithQuickChannel);
  }

  final QuickChannelConfigurationRepository _repository;
  final ChannelRepository _channels;
  final GlobalHotkeyService _hotkeys;
  final QuickStashSettingsController _quickStashSettings;
  final void Function(String channelId) _onGlobalShortcut;

  final Map<String, QuickChannelConfiguration> _configurations = {};
  final Map<String, String> _errors = {};
  final Map<String, QuickStashShortcut> _registeredShortcuts = {};
  Future<void>? _initialization;
  bool _isLoading = true;

  List<QuickChannelConfiguration> get configurations =>
      List.unmodifiable(_configurations.values);
  bool get isLoading => _isLoading;
  bool get shortcutSupported => _hotkeys.isSupported;

  QuickChannelConfiguration? configurationFor(String channelId) =>
      _configurations[channelId];

  String? errorFor(String channelId) => _errors[channelId];

  bool _conflictsWithQuickChannel(QuickStashShortcut shortcut) =>
      _configurations.values.any(
        (configuration) =>
            configuration.quickPaletteEnabled &&
            shortcut.hasSameChord(configuration.globalShortcut),
      );

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _quickStashSettings.initialize();
    final loaded = await _repository.load();
    for (final configuration in loaded) {
      _configurations[configuration.channelId] = configuration;
    }
    final used = <QuickStashShortcut>[
      _quickStashSettings.settings.globalShortcut,
    ];
    for (final configuration in loaded) {
      if (!configuration.quickPaletteEnabled) continue;
      final channel = await _channels.getChannelById(configuration.channelId);
      if (channel == null || channel.isDeleted) {
        _errors[configuration.channelId] = 'Channel is unavailable.';
        continue;
      }
      if (!configuration.globalShortcut.isValid ||
          configuration.globalShortcut.physicalKey == null) {
        _errors[configuration.channelId] = 'Saved shortcut is invalid.';
        continue;
      }
      if (used.any(configuration.globalShortcut.hasSameChord)) {
        _errors[configuration.channelId] =
            'Shortcut conflicts with another palette.';
        continue;
      }
      if (_hotkeys.isSupported) {
        try {
          await _register(configuration);
        } catch (_) {
          _errors[configuration.channelId] =
              'The saved shortcut is unavailable.';
          continue;
        }
      }
      used.add(configuration.globalShortcut);
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> configure(String channelId, QuickStashShortcut shortcut) async {
    await initialize();
    _errors.remove(channelId);
    if (!shortcut.isValid || shortcut.physicalKey == null) {
      return _fail(channelId, 'Use a modifier combination or a function key.');
    }
    final channel = await _channels.getChannelById(channelId);
    if (channel == null || channel.isDeleted) {
      return _fail(channelId, 'Channel is unavailable.');
    }
    if (shortcut.hasSameChord(_quickStashSettings.settings.globalShortcut)) {
      return _fail(channelId, 'This shortcut is already used by Quick Stash.');
    }
    for (final configuration in _configurations.values) {
      if (configuration.channelId != channelId &&
          configuration.quickPaletteEnabled &&
          shortcut.hasSameChord(configuration.globalShortcut)) {
        return _fail(
          channelId,
          'This shortcut is already used by another Channel.',
        );
      }
    }

    final previous = _configurations[channelId];
    final replacement = QuickChannelConfiguration(
      channelId: channelId,
      globalShortcut: shortcut,
    );
    final sameRegisteredChord =
        previous != null &&
        previous.quickPaletteEnabled &&
        previous.globalShortcut.hasSameChord(shortcut);
    if (_hotkeys.isSupported && !sameRegisteredChord) {
      try {
        await _register(replacement);
      } catch (_) {
        return _fail(channelId, 'This shortcut is unavailable.');
      }
    }

    final next = Map<String, QuickChannelConfiguration>.of(_configurations)
      ..[channelId] = replacement;
    try {
      await _repository.save(next.values);
    } catch (_) {
      if (_hotkeys.isSupported && !sameRegisteredChord) {
        await _hotkeys.unregister(shortcut);
        if (previous != null && previous.quickPaletteEnabled) {
          _registeredShortcuts[channelId] = previous.globalShortcut;
        } else {
          _registeredShortcuts.remove(channelId);
        }
      }
      return _fail(channelId, 'The shortcut could not be saved.');
    }
    if (_hotkeys.isSupported &&
        previous != null &&
        previous.quickPaletteEnabled &&
        !sameRegisteredChord) {
      await _hotkeys.unregister(previous.globalShortcut);
    }
    _configurations
      ..clear()
      ..addAll(next);
    _errors.remove(channelId);
    notifyListeners();
    return true;
  }

  Future<void> disable(String channelId) async {
    await initialize();
    final previous = _configurations[channelId];
    if (previous == null || !previous.quickPaletteEnabled) return;
    final replacement = previous.copyWith(quickPaletteEnabled: false);
    final next = Map<String, QuickChannelConfiguration>.of(_configurations)
      ..[channelId] = replacement;
    await _repository.save(next.values);
    if (_hotkeys.isSupported) {
      final registered = _registeredShortcuts.remove(channelId);
      if (registered != null) await _hotkeys.unregister(registered);
    }
    _configurations
      ..clear()
      ..addAll(next);
    _errors.remove(channelId);
    notifyListeners();
  }

  void clearError(String channelId) {
    if (_errors.remove(channelId) != null) notifyListeners();
  }

  Future<void> _register(QuickChannelConfiguration configuration) async {
    await _hotkeys.register(
      configuration.globalShortcut,
      () => _onGlobalShortcut(configuration.channelId),
    );
    _registeredShortcuts[configuration.channelId] =
        configuration.globalShortcut;
  }

  bool _fail(String channelId, String message) {
    _errors[channelId] = message;
    notifyListeners();
    return false;
  }

  @override
  void dispose() {
    _quickStashSettings.setShortcutConflictChecker(null);
    if (_hotkeys.isSupported) {
      for (final shortcut in _registeredShortcuts.values) {
        unawaited(_hotkeys.unregister(shortcut));
      }
    }
    super.dispose();
  }
}
