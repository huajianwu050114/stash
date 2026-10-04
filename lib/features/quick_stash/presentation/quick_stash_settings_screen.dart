import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../domain/quick_stash_settings.dart';

class QuickStashSettingsScreen extends ConsumerStatefulWidget {
  const QuickStashSettingsScreen({super.key});

  @override
  ConsumerState<QuickStashSettingsScreen> createState() =>
      _QuickStashSettingsScreenState();
}

class _QuickStashSettingsScreenState
    extends ConsumerState<QuickStashSettingsScreen> {
  final FocusNode _recorderFocus = FocusNode(debugLabel: 'shortcut-recorder');
  bool _recording = false;

  @override
  void dispose() {
    _recorderFocus.dispose();
    super.dispose();
  }

  void _startRecording() {
    ref.read(quickStashSettingsControllerProvider).clearShortcutError();
    setState(() => _recording = true);
    _recorderFocus.requestFocus();
  }

  KeyEventResult _recordKey(KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    if (_isModifier(event.physicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final modifiers = <QuickShortcutModifier>{
      if (keyboard.isControlPressed) QuickShortcutModifier.control,
      if (keyboard.isShiftPressed) QuickShortcutModifier.shift,
      if (keyboard.isAltPressed) QuickShortcutModifier.alt,
      if (keyboard.isMetaPressed) QuickShortcutModifier.meta,
    };
    final shortcut = QuickStashShortcut(
      keyId: event.physicalKey.usbHidUsage,
      keyLabel: event.physicalKey.debugName ?? event.logicalKey.keyLabel,
      modifiers: modifiers,
    );
    unawaited(_commitShortcut(shortcut));
    return KeyEventResult.handled;
  }

  Future<void> _commitShortcut(QuickStashShortcut shortcut) async {
    final saved = await ref
        .read(quickStashSettingsControllerProvider)
        .changeShortcut(shortcut);
    if (saved && mounted) setState(() => _recording = false);
  }

  bool _isModifier(PhysicalKeyboardKey key) {
    final usage = key.usbHidUsage & 0xffff;
    return usage >= 0xe0 && usage <= 0xe7;
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ref.watch(appearanceProvider).value ?? ThemeMode.system;
    final settings = ref.watch(quickStashSettingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListenableBuilder(
            listenable: settings,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
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
                Text(
                  'Quick Stash Shortcut',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (!settings.shortcutSupported)
                  const Text('Global shortcuts are available on Windows.')
                else ...[
                  Focus(
                    focusNode: _recorderFocus,
                    onKeyEvent: (_, event) => _recordKey(event),
                    child: OutlinedButton.icon(
                      key: const Key('shortcut-recorder'),
                      onPressed: _startRecording,
                      icon: Icon(
                        _recording
                            ? Icons.keyboard_alt_outlined
                            : Icons.keyboard_outlined,
                      ),
                      label: Text(
                        _recording
                            ? 'Press shortcut…'
                            : settings.settings.globalShortcut.displayLabel,
                      ),
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
}
