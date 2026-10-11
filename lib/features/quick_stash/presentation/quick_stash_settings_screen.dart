import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../../../app/providers.dart';
import '../../channels/domain/channel.dart';
import '../../quick_channel/application/quick_channel_controller.dart';
import '../domain/quick_stash_settings.dart';
import 'quick_stash_hotkey_adapter.dart';

class QuickStashSettingsScreen extends ConsumerStatefulWidget {
  const QuickStashSettingsScreen({super.key});

  @override
  ConsumerState<QuickStashSettingsScreen> createState() =>
      _QuickStashSettingsScreenState();
}

class _QuickStashSettingsScreenState
    extends ConsumerState<QuickStashSettingsScreen> {
  bool _recording = false;
  String? _recordingChannelId;

  static const _defaultChannelShortcut = QuickStashShortcut(
    keyId: 0x00070042,
    keyLabel: 'F9',
  );

  void _startRecording() {
    ref.read(quickStashSettingsControllerProvider).clearShortcutError();
    setState(() => _recording = true);
  }

  void _recordHotKey(HotKey hotKey) {
    if (hotKey.physicalKey == PhysicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return;
    }
    final usage = hotKey.physicalKey.usbHidUsage & 0xffff;
    if (usage >= 0xe0 && usage <= 0xe7) return;
    unawaited(_commitShortcut(quickStashShortcutFromHotKey(hotKey)));
  }

  Future<void> _commitShortcut(QuickStashShortcut shortcut) async {
    await ref
        .read(quickStashSettingsControllerProvider)
        .changeShortcut(shortcut);
    if (mounted) setState(() => _recording = false);
  }

  void _startChannelRecording(String channelId) {
    ref.read(quickChannelControllerProvider).clearError(channelId);
    setState(() => _recordingChannelId = channelId);
  }

  void _recordChannelHotKey(String channelId, HotKey hotKey) {
    if (hotKey.physicalKey == PhysicalKeyboardKey.escape) {
      setState(() => _recordingChannelId = null);
      return;
    }
    final usage = hotKey.physicalKey.usbHidUsage & 0xffff;
    if (usage >= 0xe0 && usage <= 0xe7) return;
    unawaited(
      _commitChannelShortcut(channelId, quickStashShortcutFromHotKey(hotKey)),
    );
  }

  Future<void> _commitChannelShortcut(
    String channelId,
    QuickStashShortcut shortcut,
  ) async {
    await ref
        .read(quickChannelControllerProvider)
        .configure(channelId, shortcut);
    if (mounted) setState(() => _recordingChannelId = null);
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appearanceProvider).value ?? ThemeMode.system;
    final profile = ref.watch(appProfileProvider);
    final settings = ref.watch(quickStashSettingsControllerProvider);
    final quickChannels = ref.watch(quickChannelControllerProvider);
    final channels = ref.watch(activeChannelsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListenableBuilder(
            listenable: Listenable.merge([settings, quickChannels]),
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(
                  'Appearance',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  key: const Key('settings-appearance'),
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                  ],
                  selected: {appearance},
                  onSelectionChanged: (selection) => ref
                      .read(appearanceProvider.notifier)
                      .setThemeMode(selection.single),
                ),
                const SizedBox(height: 32),
                if (profile.isDevelopment) ...[
                  Text(
                    'Development Hotkeys',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    elevation: 0,
                    child: SwitchListTile(
                      key: const Key('dev-global-shortcuts-toggle'),
                      secondary: const Icon(Icons.developer_mode_outlined),
                      title: const Text('Enable global shortcuts in Dev'),
                      subtitle: const Text(
                        'Off by default so Stash Dev cannot take shortcuts '
                        'from Stable. Enable only when you intend to test '
                        'Dev hotkeys.',
                      ),
                      value: settings.globalShortcutsEnabled,
                      onChanged: (value) => unawaited(
                        settings.changeGlobalShortcutsEnabled(value),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
                Text(
                  'Quick Stash Shortcut',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (!settings.shortcutSupported)
                  const Text('Global shortcuts are available on Windows.')
                else ...[
                  if (_recording)
                    Container(
                      key: const Key('shortcut-recorder-input'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.keyboard_alt_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Press a shortcut'),
                                const SizedBox(height: 4),
                                HotKeyRecorder(
                                  initalHotKey: quickStashShortcutToHotKey(
                                    settings.settings.globalShortcut,
                                  ),
                                  onHotKeyRecorded: _recordHotKey,
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            key: const Key('shortcut-recorder-cancel'),
                            onPressed: () => setState(() => _recording = false),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      key: const Key('shortcut-recorder'),
                      onPressed: _startRecording,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: Text(
                        settings.settings.globalShortcut.displayLabel,
                      ),
                    ),
                  if (settings.shortcutError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      settings.shortcutError!,
                      key: const Key('shortcut-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 32),
                Text(
                  'Quick Channels',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Open any Channel as a lightweight palette from a global shortcut.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _buildQuickChannels(
                  context,
                  quickChannels: quickChannels,
                  channels: channels,
                ),
                const SizedBox(height: 32),
                Text(
                  'Quick Capture Submit Mode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                RadioGroup<QuickCaptureSubmitMode>(
                  groupValue: settings.settings.submitMode,
                  onChanged: (mode) {
                    if (mode != null) {
                      unawaited(settings.changeSubmitMode(mode));
                    }
                  },
                  child: const Column(
                    children: [
                      RadioListTile(
                        key: Key('submit-mode-enter'),
                        value: QuickCaptureSubmitMode.enter,
                        title: Text('Enter to submit'),
                        subtitle: Text('Shift+Enter inserts a newline'),
                      ),
                      RadioListTile(
                        key: Key('submit-mode-control-enter'),
                        value: QuickCaptureSubmitMode.controlEnter,
                        title: Text('Ctrl+Enter to submit'),
                        subtitle: Text('Enter inserts a newline'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuickChannels(
    BuildContext context, {
    required QuickChannelController quickChannels,
    required AsyncValue<List<Channel>> channels,
  }) {
    if (!quickChannels.shortcutSupported) {
      return const Text('Quick Channel shortcuts are available on Windows.');
    }
    return channels.when(
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => const Text('Channels could not be loaded.'),
      data: (values) {
        if (values.isEmpty) {
          return const Text('Create a Channel to add a quick palette.');
        }
        return Column(
          key: const Key('quick-channel-settings'),
          children: [
            for (final channel in values)
              _buildQuickChannelTile(context, quickChannels, channel),
          ],
        );
      },
    );
  }

  Widget _buildQuickChannelTile(
    BuildContext context,
    QuickChannelController controller,
    Channel channel,
  ) {
    final configuration = controller.configurationFor(channel.id);
    final enabled = configuration?.quickPaletteEnabled ?? false;
    final recording = _recordingChannelId == channel.id;
    final error = controller.errorFor(channel.id);
    return Card(
      key: Key('quick-channel-setting-${channel.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
        child: Column(
          children: [
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.folder_outlined),
              title: Text(channel.name),
              subtitle: Text(
                enabled
                    ? configuration!.globalShortcut.displayLabel
                    : 'Quick palette off',
              ),
              value: enabled,
              onChanged: (value) {
                if (value) {
                  _startChannelRecording(channel.id);
                } else {
                  unawaited(controller.disable(channel.id));
                }
              },
            ),
            if (recording)
              Container(
                key: Key('quick-channel-recorder-${channel.id}'),
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Press a shortcut'),
                          const SizedBox(height: 4),
                          HotKeyRecorder(
                            initalHotKey: quickStashShortcutToHotKey(
                              configuration?.globalShortcut ??
                                  _defaultChannelShortcut,
                            ),
                            onHotKeyRecorded: (hotKey) =>
                                _recordChannelHotKey(channel.id, hotKey),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _recordingChannelId = null),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: Key('quick-channel-shortcut-${channel.id}'),
                  onPressed: () => _startChannelRecording(channel.id),
                  icon: const Icon(Icons.keyboard_outlined, size: 18),
                  label: Text(enabled ? 'Change shortcut' : 'Set shortcut'),
                ),
              ),
            if (error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Text(
                    error,
                    key: Key('quick-channel-error-${channel.id}'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
