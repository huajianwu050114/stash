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
  final dark = brightness == Brightness.dark;
  final generated = ColorScheme.fromSeed(
    seedColor: const Color(0xFF676C71),
    brightness: brightness,
    surface: dark ? const Color(0xFF151617) : const Color(0xFFFAFAF9),
  );
  final scheme = dark
      ? generated.copyWith(
          primary: const Color(0xFFE6E8EA),
          onPrimary: const Color(0xFF1A1C1E),
          primaryContainer: const Color(0xFF34373A),
          onPrimaryContainer: const Color(0xFFF1F2F3),
          secondary: const Color(0xFFC1C4C7),
          onSecondary: const Color(0xFF24272A),
          secondaryContainer: const Color(0xFF303336),
          onSecondaryContainer: const Color(0xFFE8EAEC),
          tertiary: const Color(0xFFBEC2C5),
          tertiaryContainer: const Color(0xFF303336),
          surface: const Color(0xFF151617),
          surfaceDim: const Color(0xFF111213),
          surfaceBright: const Color(0xFF35373A),
          surfaceContainerLowest: const Color(0xFF101112),
          surfaceContainerLow: const Color(0xFF191A1C),
          surfaceContainer: const Color(0xFF1E2022),
          surfaceContainerHigh: const Color(0xFF25272A),
          surfaceContainerHighest: const Color(0xFF2D3033),
          outline: const Color(0xFF8A8D91),
          outlineVariant: const Color(0xFF414448),
        )
      : generated.copyWith(
          primary: const Color(0xFF24272A),
          onPrimary: const Color(0xFFFFFFFF),
          primaryContainer: const Color(0xFFDFE2E5),
          onPrimaryContainer: const Color(0xFF1D2023),
          secondary: const Color(0xFF555B60),
          onSecondary: const Color(0xFFFFFFFF),
          secondaryContainer: const Color(0xFFE5E8EA),
          onSecondaryContainer: const Color(0xFF24272A),
          tertiary: const Color(0xFF5A6065),
          tertiaryContainer: const Color(0xFFE3E6E8),
          surface: const Color(0xFFFAFAF9),
          surfaceDim: const Color(0xFFDADBD9),
          surfaceBright: const Color(0xFFFAFAF9),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFF4F4F2),
          surfaceContainer: const Color(0xFFEFEFED),
          surfaceContainerHigh: const Color(0xFFE8E9E7),
          surfaceContainerHighest: const Color(0xFFE1E3E1),
          outline: const Color(0xFF73777A),
          outlineVariant: const Color(0xFFC5C8CA),
        );
  final base = ThemeData(
    useMaterial3: true,
    visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Segoe UI Variable',
    fontFamilyFallback: const [
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
    ],
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
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.onSurface,
      selectedTileColor: scheme.secondaryContainer,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      textStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
    ),
  );
  final textTheme = base.textTheme.copyWith(
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    ),
  );
  return base.copyWith(textTheme: textTheme, primaryTextTheme: textTheme);
}
