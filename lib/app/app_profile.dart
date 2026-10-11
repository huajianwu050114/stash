enum AppProfile {
  stable,
  dev;

  String get displayName => switch (this) {
    AppProfile.stable => 'Stash',
    AppProfile.dev => 'Stash Dev',
  };

  String get storageDirectoryName => switch (this) {
    AppProfile.stable => 'Stash',
    AppProfile.dev => 'StashDev',
  };

  String get preferenceNamespace => switch (this) {
    AppProfile.stable => 'stable',
    AppProfile.dev => 'dev',
  };

  String get trayIdentifier => switch (this) {
    AppProfile.stable => 'stash.desktop.stable',
    AppProfile.dev => 'stash.desktop.dev',
  };

  bool get isDevelopment => this == AppProfile.dev;
  bool get globalShortcutsEnabledByDefault => this == AppProfile.stable;
}
