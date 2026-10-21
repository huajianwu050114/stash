import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../domain/item.dart';
import 'item_actions.dart';
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
        .showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _togglePin(BuildContext context, WidgetRef ref) async {
    await ItemActionController.togglePin(context, ref, item);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final deleted = await ItemActionController.delete(context, ref, item);
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _move(BuildContext context, WidgetRef ref) async {
    await ItemActionController.move(context, ref, item);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = item.title?.trim();
    final channel = item.channelId == null
        ? null
        : ref.watch(channelByIdProvider(item.channelId!));
    return Scaffold(
      appBar: AppBar(title: const Text('条目')),
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
                    Text('备注', style: Theme.of(context).textTheme.titleSmall),
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
                  '位置：${item.channelId == null ? '收件箱' : channel?.value?.name ?? '频道'}',
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
                      label: const Text('复制'),
                    ),
                    TextButton.icon(
                      key: const Key('edit-item-button'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ItemEditorScreen.edit(item: item),
                        ),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('编辑'),
                    ),
                    TextButton.icon(
                      key: const Key('move-item-button'),
                      onPressed: () => _move(context, ref),
                      icon: const Icon(Icons.drive_file_move_outline, size: 18),
                      label: const Text('移动'),
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
                      label: Text(item.isPinned ? '取消置顶' : '置顶'),
                    ),
                    TextButton.icon(
                      key: const Key('delete-item-button'),
                      onPressed: () => _delete(context, ref),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Text(
                  '创建于 ${_formatTimestamp(item.createdAt)}',
                  style: _metadataStyle(context),
                ),
                const SizedBox(height: 6),
                Text(
                  '更新于 ${_formatTimestamp(item.updatedAt)}',
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
      body: const Center(child: Text('条目不可用')),
    );
  }
}
