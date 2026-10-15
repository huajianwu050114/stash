import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/items/presentation/home_screen.dart';
import '../features/quick_channel/presentation/quick_channel_palette.dart';
import '../features/quick_stash/application/quick_stash_controller.dart';
import '../features/quick_stash/presentation/quick_stash_screen.dart';
import 'providers.dart';

class StashApp extends ConsumerStatefulWidget {
  const StashApp({super.key});

  @override
  ConsumerState<StashApp> createState() => _StashAppState();
}

class _StashAppState extends ConsumerState<StashApp> {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _noticeScheduled = false;

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(appearanceProvider).value ?? ThemeMode.system;
    final profile = ref.watch(appProfileProvider);
    final quickStash = ref.watch(quickStashControllerProvider);
    ref.watch(quickStashSettingsControllerProvider);
    ref.watch(quickChannelControllerProvider);
    final startupNotice = ref.watch(startupRestoreNoticeProvider);
    if (startupNotice != null && !_noticeScheduled) {
      _noticeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _messengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(startupNotice)),
        );
      });
    }
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      title: profile.displayName,
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: createStashTheme(Brightness.light),
      darkTheme: createStashTheme(Brightness.dark),
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      home: StashSurfaceHost(controller: quickStash),
    );
  }
}

class StashSurfaceHost extends StatefulWidget {
  const StashSurfaceHost({super.key, required this.controller});

  final QuickStashController controller;

  @override
  State<StashSurfaceHost> createState() => _StashSurfaceHostState();
}

class _StashSurfaceHostState extends State<StashSurfaceHost> {
  final _fullNavigatorKey = GlobalKey<NavigatorState>();
  late bool _fullSurfaceInitialized =
      widget.controller.surface == StashSurface.full;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final surface = widget.controller.surface;
      if (surface == StashSurface.full) _fullSurfaceInitialized = true;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_fullSurfaceInitialized)
            Offstage(
              offstage: surface != StashSurface.full,
              child: TickerMode(
                enabled: surface == StashSurface.full,
                child: Navigator(
                  key: _fullNavigatorKey,
                  initialRoute: '/',
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => const HomeScreen(),
                  ),
                ),
              ),
            ),
          if (surface == StashSurface.quick)
            const QuickStashScreen(key: Key('quick-surface-host')),
          if (surface == StashSurface.quickChannel)
            QuickChannelPalette(
              key: const Key('quick-channel-surface-host'),
              channelId: widget.controller.quickChannelId!,
            ),
        ],
      );
    },
  );
}

ThemeData createStashTheme(Brightness brightness) {
  const seed = Color(0xFF527660);
  final dark = brightness == Brightness.dark;
  final generated = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    surface: dark ? const Color(0xFF151815) : const Color(0xFFFAFBF8),
  );
  final scheme = dark
      ? generated.copyWith(
          primary: const Color(0xFF86B394),
          onPrimary: const Color(0xFF12351F),
          primaryContainer: const Color(0xFF294A35),
          onPrimaryContainer: const Color(0xFFD0E8D6),
          secondary: const Color(0xFFB9C2BB),
          onSecondary: const Color(0xFF253029),
          secondaryContainer: const Color(0xFF2B3730),
          onSecondaryContainer: const Color(0xFFDCE8DF),
          tertiary: const Color(0xFFBFC3C7),
          tertiaryContainer: const Color(0xFF303438),
          surface: const Color(0xFF151617),
          surfaceDim: const Color(0xFF111213),
          surfaceBright: const Color(0xFF35373A),
          surfaceContainerLowest: const Color(0xFF101112),
          surfaceContainerLow: const Color(0xFF1B1C1E),
          surfaceContainer: const Color(0xFF202225),
          surfaceContainerHigh: const Color(0xFF27292C),
          surfaceContainerHighest: const Color(0xFF303236),
          outline: const Color(0xFF8A8D91),
          outlineVariant: const Color(0xFF45484C),
        )
      : generated.copyWith(
          surface: const Color(0xFFFAFBF8),
          surfaceDim: const Color(0xFFDADCD8),
          surfaceBright: const Color(0xFFFAFBF8),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFF5F6F3),
          surfaceContainer: const Color(0xFFEFF1ED),
          surfaceContainerHigh: const Color(0xFFE9EBE7),
          surfaceContainerHighest: const Color(0xFFE3E5E1),
          outline: const Color(0xFF747974),
          outlineVariant: const Color(0xFFC4C8C3),
          secondaryContainer: const Color(0xFFDCE9DF),
          onSecondaryContainer: const Color(0xFF22382A),
        );
  return ThemeData(
    useMaterial3: true,
    visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
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
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
  );
}
