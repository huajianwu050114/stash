import 'package:flutter/services.dart';

enum QuickCaptureSubmitMode { enter, controlEnter }

enum QuickShortcutModifier { control, shift, alt, meta }

class QuickStashShortcut {
  const QuickStashShortcut({
    required this.keyId,
    required this.keyLabel,
    this.modifiers = const {},
  });

  static const defaultShortcut = QuickStashShortcut(
    keyId: 0x0007002c,
    keyLabel: 'Space',
    modifiers: {QuickShortcutModifier.control, QuickShortcutModifier.shift},
  );

  final int keyId;
  final String keyLabel;
  final Set<QuickShortcutModifier> modifiers;

  bool get isFunctionKey {
    final usage = keyId & 0xffff;
    return (usage >= 0x3a && usage <= 0x45) || (usage >= 0x68 && usage <= 0x73);
  }

  bool get isValid => modifiers.isNotEmpty || isFunctionKey;

  bool hasSameChord(QuickStashShortcut other) =>
      keyId == other.keyId &&
      modifiers.length == other.modifiers.length &&
      modifiers.containsAll(other.modifiers);

  PhysicalKeyboardKey? get physicalKey =>
      PhysicalKeyboardKey.findKeyByCode(keyId);

  String get displayLabel => [
    if (modifiers.contains(QuickShortcutModifier.control)) 'Ctrl',
    if (modifiers.contains(QuickShortcutModifier.shift)) 'Shift',
    if (modifiers.contains(QuickShortcutModifier.alt)) 'Alt',
    if (modifiers.contains(QuickShortcutModifier.meta)) 'Win',
    keyLabel,
  ].join(' + ');

  Map<String, Object> toJson() => {
    'keyId': keyId,
    'keyLabel': keyLabel,
    'modifiers': modifiers.map((value) => value.name).toList(),
  };

  factory QuickStashShortcut.fromJson(Map<String, dynamic> json) {
    final keyId = json['keyId'];
    final keyLabel = json['keyLabel'];
    final modifierNames = json['modifiers'];
    if (keyId is! int || keyLabel is! String || modifierNames is! List) {
      throw const FormatException('Invalid Quick Stash shortcut.');
    }
    return QuickStashShortcut(
      keyId: keyId,
      keyLabel: keyLabel,
      modifiers: modifierNames
          .whereType<String>()
          .map(
            (name) => QuickShortcutModifier.values.firstWhere(
              (value) => value.name == name,
            ),
          )
          .toSet(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QuickStashShortcut &&
      other.keyId == keyId &&
      other.keyLabel == keyLabel &&
      other.modifiers.length == modifiers.length &&
      other.modifiers.containsAll(modifiers);

  @override
  int get hashCode =>
      Object.hash(keyId, keyLabel, Object.hashAllUnordered(modifiers));
}

class QuickStashSettings {
  const QuickStashSettings({
    this.globalShortcut = QuickStashShortcut.defaultShortcut,
    this.submitMode = QuickCaptureSubmitMode.enter,
    this.globalShortcutsEnabled = true,
  });

  final QuickStashShortcut globalShortcut;
  final QuickCaptureSubmitMode submitMode;
  final bool globalShortcutsEnabled;

  QuickStashSettings copyWith({
    QuickStashShortcut? globalShortcut,
    QuickCaptureSubmitMode? submitMode,
    bool? globalShortcutsEnabled,
  }) => QuickStashSettings(
    globalShortcut: globalShortcut ?? this.globalShortcut,
    submitMode: submitMode ?? this.submitMode,
    globalShortcutsEnabled:
        globalShortcutsEnabled ?? this.globalShortcutsEnabled,
  );
}
