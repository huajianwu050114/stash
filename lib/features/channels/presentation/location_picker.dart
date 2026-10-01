import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../domain/channel.dart';

class LocationSelection {
  const LocationSelection(this.channelId);
  final String? channelId;
}

Future<LocationSelection?> showLocationPicker(
  BuildContext context, {
  required WidgetRef ref,
  bool includeInbox = true,
  String? excludedChannelId,
  String? currentChannelId,
}) async {
  final channels = await ref
      .read(channelRepositoryProvider)
      .getActiveChannels();
  if (!context.mounted) return null;
  final excluded = _descendantIds(channels, excludedChannelId);
  final ordered = _orderedChannels(channels)
      .where((entry) => !excluded.contains(entry.channel.id))
      .toList();
  return showModalBottomSheet<LocationSelection>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                'Choose location',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                key: const Key('location-picker'),
                children: [
                  if (includeInbox)
                    ListTile(
                      key: const Key('location-inbox'),
                      leading: const Icon(Icons.inbox_outlined),
                      title: const Text('Inbox'),
                      trailing: currentChannelId == null
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(
                        sheetContext,
                        const LocationSelection(null),
                      ),
                    ),
                  if (!includeInbox)
                    ListTile(
                      key: const Key('location-root'),
                      leading: const Icon(Icons.account_tree_outlined),
                      title: const Text('Root'),
                      trailing: currentChannelId == null
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(
                        sheetContext,
                        const LocationSelection(null),
                      ),
                    ),
                  for (final entry in ordered)
                    ListTile(
                      key: Key('location-${entry.channel.id}'),
                      contentPadding: EdgeInsets.only(
                        left: 16 + entry.depth * 24,
                        right: 16,
                      ),
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(entry.channel.name),
                      trailing: currentChannelId == entry.channel.id
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(
                        sheetContext,
                        LocationSelection(entry.channel.id),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Set<String> _descendantIds(List<Channel> channels, String? rootId) {
  if (rootId == null) return const {};
  final result = <String>{rootId};
  var changed = true;
  while (changed) {
    changed = false;
    for (final channel in channels) {
      if (channel.parentId != null &&
          result.contains(channel.parentId) &&
          result.add(channel.id)) {
        changed = true;
      }
    }
  }
  return result;
}

List<_ChannelEntry> _orderedChannels(List<Channel> channels) {
  final byParent = <String?, List<Channel>>{};
  for (final channel in channels) {
    byParent.putIfAbsent(channel.parentId, () => []).add(channel);
  }
  for (final children in byParent.values) {
    children.sort((a, b) => a.name.compareTo(b.name));
  }
  final result = <_ChannelEntry>[];
  void visit(String? parentId, int depth) {
    for (final child in byParent[parentId] ?? const <Channel>[]) {
      result.add(_ChannelEntry(child, depth));
      visit(child.id, depth + 1);
    }
  }

  visit(null, 0);
  return result;
}

class _ChannelEntry {
  const _ChannelEntry(this.channel, this.depth);
  final Channel channel;
  final int depth;
}
