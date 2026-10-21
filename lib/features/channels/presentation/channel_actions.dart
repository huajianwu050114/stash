import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../domain/channel.dart';
import 'location_picker.dart';

enum ChannelAction { open, createChild, rename, move, delete }

class ChannelActionController {
  const ChannelActionController._();

  static Future<void> create(
    BuildContext context,
    WidgetRef ref, {
    required String? parentId,
  }) async {
    final name = await _nameDialog(
      context,
      title: parentId == null ? '新建频道' : '新建子频道',
    );
    if (name == null || !context.mounted) return;
    try {
      if (parentId == null) {
        await ref.read(channelRepositoryProvider).createRootChannel(name: name);
      } else {
        await ref
            .read(channelRepositoryProvider)
            .createChildChannel(name: name, parentId: parentId);
      }
    } catch (error) {
      if (context.mounted) _showError(context, error.toString());
    }
  }

  static Future<void> perform(
    BuildContext context,
    WidgetRef ref, {
    required Channel channel,
    required ChannelAction action,
    VoidCallback? onOpen,
    VoidCallback? onDeleted,
  }) async {
    if (action == ChannelAction.open) {
      onOpen?.call();
      return;
    }
    if (action == ChannelAction.createChild) {
      await create(context, ref, parentId: channel.id);
      return;
    }
    try {
      if (action == ChannelAction.rename) {
        final name = await _nameDialog(
          context,
          title: '重命名频道',
          initialValue: channel.name,
        );
        if (name != null) {
          await ref
              .read(channelRepositoryProvider)
              .renameChannel(channel.id, name);
        }
      } else if (action == ChannelAction.move) {
        final selection = await showLocationPicker(
          context,
          ref: ref,
          includeInbox: false,
          excludedChannelId: channel.id,
          currentChannelId: channel.parentId,
        );
        if (selection != null) {
          await ref
              .read(channelRepositoryProvider)
              .moveChannel(channel.id, parentId: selection.channelId);
        }
      } else if (action == ChannelAction.delete) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除此频道？'),
            content: const Text('仅可删除空频道。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              TextButton(
                key: const Key('confirm-delete-channel'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await ref
              .read(channelRepositoryProvider)
              .softDeleteChannel(channel.id);
          onDeleted?.call();
        }
      }
    } catch (error) {
      if (context.mounted) _showError(context, error.toString());
    }
  }
}

Future<String?> _nameDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
}) async {
  final controller = TextEditingController(text: initialValue);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('channel-name-field'),
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '名称'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(dialogContext, value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-channel'),
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, controller.text);
            }
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  return result;
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
