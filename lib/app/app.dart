import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/items/presentation/home_screen.dart';
import '../features/quick_channel/presentation/quick_channel_palette.dart';
import '../features/quick_stash/application/quick_stash_controller.dart';
import '../features/quick_stash/presentation/quick_stash_screen.dart';
import 'providers.dart';

class StashApp extends ConsumerWidget {
  const StashApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appearanceProvider).value ?? ThemeMode.system;
    final quickStash = ref.watch(quickStashControllerProvider);
    ref.watch(quickStashSettingsControllerProvider);
    ref.watch(quickChannelControllerProvider);
    return ListenableBuilder(
      listenable: quickStash,
      builder: (context, _) => MaterialApp(
        title: 'Stash',
        debugShowCheckedModeBanner: false,
        themeMode: themeMode,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: switch (quickStash.surface) {
          StashSurface.quick => const QuickStashScreen(),
          StashSurface.quickChannel => QuickChannelPalette(
            channelId: quickStash.quickChannelId!,
          ),
          StashSurface.full => const HomeScreen(),
        },
      ),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  const seed = Color(0xFF527660);
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    surface: dark ? const Color(0xFF151815) : const Color(0xFFFAFBF8),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: dark ? const Color(0xFF343934) : const Color(0xFFE2E7E1),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: const OutlineInputBorder(),
      alignLabelWithHint: true,
      filled: false,
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? const Color(0xFF343934) : const Color(0xFFE2E7E1),
    ),
  );
}
