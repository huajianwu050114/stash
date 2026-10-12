import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../channels/presentation/location_picker.dart';
import '../domain/item.dart';
import 'item_document_view.dart';
import 'item_editor_screen.dart';

class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(itemByIdProvider(itemId));
    return item.when(
      data: (value) {
        if (value == null || value.isDeleted) {
          return const _UnavailableItemScreen();
        }
        return _ItemDetail(item: value);
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, _) => const _UnavailableItemScreen(),
    );
  }
}

class _ItemDetail extends ConsumerWidget {
  const _ItemDetail({required this.item});

  final Item item;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: item.content));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  Future<void> _togglePin(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(itemRepositoryProvider).setPinned(item.id, !item.isPinned);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not update item.')));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this item?'),
        content: const Text('It will disappear from Stash on this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-delete-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(itemRepositoryProvider).softDeleteItem(item.id);
      if (context.mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not delete item.')));
    }
  }

  Future<void> _move(BuildContext context, WidgetRef ref) async {
    final selection = await showLocationPicker(
      context,
      ref: ref,
      currentChannelId: item.channelId,
    );
    if (selection == null || !context.mounted) return;
    try {
      await ref
          .read(itemRepositoryProvider)
          .moveItem(item.id, channelId: selection.channelId);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not move this item.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = item.title?.trim();
    final channel = item.channelId == null
        ? null
        : ref.watch(channelByIdProvider(item.channelId!));
    return Scaffold(
      appBar: AppBar(title: const Text('Item')),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                if (title != null && title.isNotEmpty) ...[
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 20),
                ],
                ItemDocumentView(
                  documentJson: item.documentJson,
                  legacyText: item.content,
                  attachmentRepository: ref.watch(attachmentRepositoryProvider),
                  fileActions: ref.watch(attachmentFileActionsProvider),
                ),
                if (item.note case final note?) ...[
                  if (note.trim().isNotEmpty) ...[
                    const SizedBox(height: 32),
                    Text('Note', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      note,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(height: 1.5),
                    ),
                  ],
                ],
                if (item.tags.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final tag in item.tags)
                        Text(
                          '#$tag',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Location: ${item.channelId == null ? 'Inbox' : channel?.value?.name ?? 'Channel'}',
                  key: const Key('item-location'),
                  style: _metadataStyle(context),
                ),
                const SizedBox(height: 36),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      key: const Key('copy-item-button'),
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy'),
                    ),
                    TextButton.icon(
                      key: const Key('edit-item-button'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ItemEditorScreen.edit(item: item),
                        ),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    ),
                    TextButton.icon(
                      key: const Key('move-item-button'),
                      onPressed: () => _move(context, ref),
                      icon: const Icon(Icons.drive_file_move_outline, size: 18),
                      label: const Text('Move'),
                    ),
                    TextButton.icon(
                      key: const Key('pin-item-button'),
                      onPressed: () => _togglePin(context, ref),
                      icon: Icon(
                        item.isPinned
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 18,
                      ),
                      label: Text(item.isPinned ? 'Unpin' : 'Pin'),
                    ),
                    TextButton.icon(
                      key: const Key('delete-item-button'),
                      onPressed: () => _delete(context, ref),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Text(
                  'Created ${_formatTimestamp(item.createdAt)}',
                  style: _metadataStyle(context),
                ),
                const SizedBox(height: 6),
                Text(
                  'Updated ${_formatTimestamp(item.updatedAt)}',
                  style: _metadataStyle(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle? _metadataStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.outline);

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

class _UnavailableItemScreen extends StatelessWidget {
  const _UnavailableItemScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: const Center(child: Text('This item is no longer available.')),
    );
  }
}
