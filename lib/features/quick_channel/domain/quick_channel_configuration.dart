import '../../quick_stash/domain/quick_stash_settings.dart';

class QuickChannelConfiguration {
  const QuickChannelConfiguration({
    required this.channelId,
    required this.globalShortcut,
    this.quickPaletteEnabled = true,
  });

  final String channelId;
  final QuickStashShortcut globalShortcut;
  final bool quickPaletteEnabled;

  QuickChannelConfiguration copyWith({
    QuickStashShortcut? globalShortcut,
    bool? quickPaletteEnabled,
  }) => QuickChannelConfiguration(
    channelId: channelId,
    globalShortcut: globalShortcut ?? this.globalShortcut,
    quickPaletteEnabled: quickPaletteEnabled ?? this.quickPaletteEnabled,
  );

  Map<String, Object> toJson() => {
    'channelId': channelId,
    'globalShortcut': globalShortcut.toJson(),
    'quickPaletteEnabled': quickPaletteEnabled,
  };

  factory QuickChannelConfiguration.fromJson(Map<String, dynamic> json) {
    final channelId = json['channelId'];
    final shortcut = json['globalShortcut'];
    final enabled = json['quickPaletteEnabled'];
    if (channelId is! String || shortcut is! Map || enabled is! bool) {
      throw const FormatException('Invalid Quick Channel configuration.');
    }
    return QuickChannelConfiguration(
      channelId: channelId,
      globalShortcut: QuickStashShortcut.fromJson(
        Map<String, dynamic>.from(shortcut),
      ),
      quickPaletteEnabled: enabled,
    );
  }
}
