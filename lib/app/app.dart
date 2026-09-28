import 'package:flutter/material.dart';

import '../features/items/presentation/home_screen.dart';

class StashApp extends StatelessWidget {
  const StashApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF365F4B);
    final colorScheme = ColorScheme.fromSeed(seedColor: seed);
    return MaterialApp(
      title: 'Stash',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: colorScheme.surface,
        appBarTheme: AppBarTheme(
          backgroundColor: colorScheme.surface,
          foregroundColor: colorScheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
