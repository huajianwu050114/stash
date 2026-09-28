import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../domain/item.dart';
import 'item_detail_screen.dart';
import 'item_editor_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeItems = ref.watch(activeItemsProvider);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 76,
        titleSpacing: 24,
        title: Text(
          'Stash',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
        ),
        actions: [
          IconButton(
            key: const Key('new-item-button'),
            tooltip: 'New item',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ItemEditorScreen.create(),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: activeItems.when(
              data: (items) => _HomeContent(items: items),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const _HomeMessage(
                title: 'Stash could not be opened',
                body: 'Try closing and reopening the app.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({required this.items});

  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _HomeMessage(
        key: Key('empty-home'),
        title: 'Nothing stashed yet',
        body: 'Keep the useful thing before it gets away.',
      );
    }

    final pinned = items.where((item) => item.isPinned).toList();
    final recent = items.where((item) => !item.isPinned).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
      children: [
        if (pinned.isNotEmpty)
          _ItemSection(
            key: const Key('pinned-section'),
            title: 'Pinned',
            items: pinned,
          ),
        if (pinned.isNotEmpty && recent.isNotEmpty) const SizedBox(height: 36),
        if (recent.isNotEmpty)
          _ItemSection(
            key: const Key('recent-section'),
            title: 'Recent',
            items: recent,
          ),
      ],
    );
  }
}

class _HomeMessage extends StatelessWidget {
  const _HomeMessage({super.key, required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemSection extends StatelessWidget {
  const _ItemSection({super.key, required this.title, required this.items});

  final String title;
  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < items.length; index++) ...[
          _ItemPreview(item: items[index]),
          if (index != items.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }
}

class _ItemPreview extends StatelessWidget {
  const _ItemPreview({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final title = item.title?.trim();
    return InkWell(
      key: Key('item-preview-${item.id}'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ItemDetailScreen(itemId: item.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null && title.isNotEmpty) ...[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 5),
            ],
            Text(
              item.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            if (item.tags.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                item.tags.map((tag) => '#$tag').join('  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'Updated ${_formatDate(item.updatedAt)}',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
}
