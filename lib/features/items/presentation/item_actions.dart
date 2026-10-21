import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../channels/presentation/location_picker.dart';
import '../domain/item.dart';

class ItemActionController {
  const ItemActionController._();

  static Future<void> togglePin(
    BuildContext context,
    WidgetRef ref,
    Item item,
  ) async {
    try {
      await ref.read(itemRepositoryProvider).setPinned(item.id, !item.isPinned);
    } catch (_) {
      if (context.mounted) _showError(context, '无法更新条目。');
    }
  }

  static Future<void> move(
    BuildContext context,
    WidgetRef ref,
    Item item,
  ) async {
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
      if (context.mounted) _showError(context, '无法移动条目。');
    }
  }

  static Future<bool> delete(
    BuildContext context,
    WidgetRef ref,
    Item item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除此条目？'),
        content: const Text('此条目将从当前设备的 Stash 中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirm-delete-button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    try {
      await ref.read(itemRepositoryProvider).softDeleteItem(item.id);
      return true;
    } catch (_) {
      if (context.mounted) _showError(context, '无法删除条目。');
      return false;
    }
  }
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
