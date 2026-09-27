import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Minimal Phase 1 shell. The real product UI arrives in later phases; this
/// screen only proves that the app starts, the database opens, and the
/// reactive Drift-backed stream is wired through Riverpod.
class StashApp extends StatelessWidget {
  const StashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stash',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeItems = ref.watch(activeItemsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Stash')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Local foundation ready',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            activeItems.when(
              data: (items) => Text(
                '${items.length} active item${items.length == 1 ? '' : 's'}',
              ),
              loading: () => const Text('Opening database…'),
              error: (_, _) => const Text('Database unavailable'),
            ),
          ],
        ),
      ),
    );
  }
}
