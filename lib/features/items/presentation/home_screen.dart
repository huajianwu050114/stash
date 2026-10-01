import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../channels/domain/channel.dart';
import '../../channels/presentation/location_picker.dart';
import '../domain/item.dart';
import 'item_detail_screen.dart';
import 'item_editor_screen.dart';

enum _ViewKind { inbox, pinned, channel }

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  _ViewKind _selectedKind = _ViewKind.inbox;
  String? _selectedChannelId;

  void _openChannel(BuildContext context, Channel channel, bool wide) {
    if (wide) {
      setState(() {
        _selectedKind = _ViewKind.channel;
        _selectedChannelId = channel.id;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelScreen(channelId: channel.id),
        ),
      );
    }
  }

  void _openSpecial(BuildContext context, _ViewKind kind, bool wide) {
    if (wide) {
      setState(() {
        _selectedKind = kind;
        _selectedChannelId = null;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _ItemsLocationScreen(kind: kind),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 72,
          titleSpacing: 24,
          title: Text(
            'Stash',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
          ),
          actions: [
            FilledButton.icon(
              key: const Key('new-item-button'),
              onPressed: () => _createItem(context, null),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add item'),
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: SafeArea(
          top: false,
          child: wide
              ? Row(
                  key: const Key('wide-browser'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 300,
                      child: _RootPane(
                        compact: true,
                        selectedKind: _selectedKind,
                        selectedChannelId: _selectedChannelId,
                        onSpecial: (kind) => _openSpecial(context, kind, true),
                        onChannel: (channel) =>
                            _openChannel(context, channel, true),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: switch (_selectedKind) {
                        _ViewKind.inbox => const _ItemsPane(
                          title: 'Inbox',
                          kind: _ViewKind.inbox,
                        ),
                        _ViewKind.pinned => const _ItemsPane(
                          title: 'Pinned',
                          kind: _ViewKind.pinned,
                        ),
                        _ViewKind.channel => _ChannelPane(
                          channelId: _selectedChannelId!,
                          onOpenChannel: (channel) =>
                              _openChannel(context, channel, true),
                          onDeleted: () => setState(() {
                            _selectedKind = _ViewKind.inbox;
                            _selectedChannelId = null;
                          }),
                        ),
                      },
                    ),
                  ],
                )
              : _RootPane(
                  compact: false,
                  selectedKind: null,
                  selectedChannelId: null,
                  onSpecial: (kind) => _openSpecial(context, kind, false),
                  onChannel: (channel) => _openChannel(context, channel, false),
                ),
        ),
      );
    },
  );
}

class _RootPane extends ConsumerWidget {
  const _RootPane({
    required this.compact,
    required this.selectedKind,
    required this.selectedChannelId,
    required this.onSpecial,
    required this.onChannel,
  });

  final bool compact;
  final _ViewKind? selectedKind;
  final String? selectedChannelId;
  final ValueChanged<_ViewKind> onSpecial;
  final ValueChanged<Channel> onChannel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(rootChannelsProvider);
    final inbox = ref.watch(inboxItemsProvider);
    return ListView(
      key: const Key('root-browser'),
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 24,
        12,
        compact ? 12 : 24,
        48,
      ),
      children: [
        _LocationTile(
          key: const Key('open-inbox'),
          icon: Icons.inbox_outlined,
          title: 'Inbox',
          subtitle: 'Things you saved without filing',
          selected: selectedKind == _ViewKind.inbox,
          onTap: () => onSpecial(_ViewKind.inbox),
        ),
        _LocationTile(
          key: const Key('open-pinned'),
          icon: Icons.push_pin_outlined,
          title: 'Pinned',
          subtitle: 'Important items from everywhere',
          selected: selectedKind == _ViewKind.pinned,
          onTap: () => onSpecial(_ViewKind.pinned),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'Channels',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('new-root-channel'),
              onPressed: () => _createChannel(context, ref, null),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('New channel'),
            ),
          ],
        ),
        channels.when(
          data: (values) => Column(
            children: [
              for (final channel in values)
                _ChannelTile(
                  channel: channel,
                  selected: channel.id == selectedChannelId,
                  onTap: () => onChannel(channel),
                ),
              if (values.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('No channels yet.'),
                  ),
                ),
            ],
          ),
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const Text('Channels could not be loaded.'),
        ),
        if (!compact) ...[
          const SizedBox(height: 28),
          inbox.when(
            data: (items) => _RootInboxSections(items: items),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Text('Inbox could not be loaded.'),
          ),
        ],
      ],
    );
  }
}

class _RootInboxSections extends StatelessWidget {
  const _RootInboxSections({required this.items});
  final List<Item> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyItems(
        key: const Key('empty-home'),
        title: 'Nothing stashed yet',
        body: 'Save it now. You can organize it later.',
        actionLabel: 'Add your first item',
        onAdd: () => _createItem(context, null),
      );
    }
    final pinned = items.where((item) => item.isPinned).toList();
    final recent = items.where((item) => !item.isPinned).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pinned.isNotEmpty)
          _ItemSection(
            key: const Key('pinned-section'),
            title: 'Pinned',
            items: pinned,
          ),
        if (pinned.isNotEmpty && recent.isNotEmpty) const SizedBox(height: 28),
        if (recent.isNotEmpty)
          _ItemSection(
            key: const Key('recent-section'),
            title: 'Recent in Inbox',
            items: recent,
          ),
      ],
    );
  }
}

class _ItemsLocationScreen extends StatelessWidget {
  const _ItemsLocationScreen({required this.kind});
  final _ViewKind kind;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(kind == _ViewKind.inbox ? 'Inbox' : 'Pinned')),
    body: _ItemsPane(
      title: kind == _ViewKind.inbox ? 'Inbox' : 'Pinned',
      kind: kind,
    ),
  );
}

class _ItemsPane extends ConsumerWidget {
  const _ItemsPane({required this.title, required this.kind});
  final String title;
  final _ViewKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = kind == _ViewKind.pinned
        ? ref.watch(pinnedItemsProvider)
        : ref.watch(inboxItemsProvider);
    return _ContentFrame(
      title: title,
      actions: kind == _ViewKind.inbox
          ? [
              FilledButton.icon(
                key: const Key('add-inbox-item'),
                onPressed: () => _createItem(context, null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add item'),
              ),
            ]
          : const [],
      child: items.when(
        data: (values) => values.isEmpty
            ? _EmptyItems(
                title: kind == _ViewKind.pinned
                    ? 'Nothing pinned yet'
                    : 'Inbox is empty',
                body: kind == _ViewKind.pinned
                    ? 'Pinned items from every channel appear here.'
                    : 'Save something now and organize it later.',
                actionLabel: kind == _ViewKind.inbox ? 'Add item' : null,
                onAdd: kind == _ViewKind.inbox
                    ? () => _createItem(context, null)
                    : null,
              )
            : _ItemSection(title: 'Items', items: values),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Items could not be loaded.')),
      ),
    );
  }
}

class ChannelScreen extends StatelessWidget {
  const ChannelScreen({super.key, required this.channelId});
  final String channelId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: _ChannelPane(
      channelId: channelId,
      onOpenChannel: (channel) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelScreen(channelId: channel.id),
        ),
      ),
      onDeleted: () => Navigator.of(context).pop(),
    ),
  );
}

class _ChannelPane extends ConsumerWidget {
  const _ChannelPane({
    required this.channelId,
    required this.onOpenChannel,
    required this.onDeleted,
  });

  final String channelId;
  final ValueChanged<Channel> onOpenChannel;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(channelId));
    final children = ref.watch(childChannelsProvider(channelId));
    final items = ref.watch(channelItemsProvider(channelId));
    return channel.when(
      data: (value) {
        if (value == null || value.isDeleted) {
          return const Center(
            child: Text('This channel is no longer available.'),
          );
        }
        return _ContentFrame(
          title: value.name,
          breadcrumbs: _Breadcrumbs(channelId: channelId),
          actions: [
            if (value.parentId != null)
              OutlinedButton.icon(
                key: const Key('channel-up'),
                onPressed: () async {
                  final parent = await ref
                      .read(channelRepositoryProvider)
                      .getChannelById(value.parentId!);
                  if (parent != null && !parent.isDeleted) {
                    onOpenChannel(parent);
                  }
                },
                icon: const Icon(Icons.arrow_upward_rounded),
                label: const Text('Up'),
              ),
            FilledButton.icon(
              key: const Key('add-channel-item'),
              onPressed: () => _createItem(context, channelId),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add item'),
            ),
            OutlinedButton.icon(
              key: const Key('new-subchannel'),
              onPressed: () => _createChannel(context, ref, channelId),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('New subchannel'),
            ),
            PopupMenuButton<String>(
              key: const Key('channel-menu'),
              tooltip: 'Channel actions',
              onSelected: (action) =>
                  _manageChannel(context, ref, value, action, onDeleted),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'move', child: Text('Move')),
                PopupMenuItem(
                  key: Key('delete-channel-action'),
                  value: 'delete',
                  child: Text('Delete'),
                ),
              ],
            ),
          ],
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              children.when(
                data: (values) => values.isEmpty
                    ? const SizedBox.shrink()
                    : _ChannelSection(channels: values, onOpen: onOpenChannel),
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => const Text('Subchannels could not be loaded.'),
              ),
              items.when(
                data: (values) => values.isEmpty
                    ? (children.value?.isEmpty ?? true)
                          ? _EmptyItems(
                              title: 'This channel is empty',
                              body: 'Add an item or create a subchannel.',
                              actionLabel: 'Add item',
                              onAdd: () => _createItem(context, channelId),
                            )
                          : const SizedBox(height: 24)
                    : Padding(
                        padding: const EdgeInsets.only(top: 28),
                        child: _ItemSection(title: 'Items', items: values),
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => const Text('Items could not be loaded.'),
              ),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const Center(child: Text('Channel could not be loaded.')),
    );
  }
}

class _ContentFrame extends StatelessWidget {
  const _ContentFrame({
    required this.title,
    required this.actions,
    required this.child,
    this.breadcrumbs,
  });
  final String title;
  final List<Widget> actions;
  final Widget child;
  final Widget? breadcrumbs;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 880),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (breadcrumbs != null) ...[
              breadcrumbs!,
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                ...actions,
              ],
            ),
            const SizedBox(height: 20),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
}

class _Breadcrumbs extends ConsumerWidget {
  const _Breadcrumbs({required this.channelId});
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final breadcrumbs = ref.watch(channelBreadcrumbsProvider(channelId));
    return breadcrumbs.when(
      data: (values) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text('Stash', style: Theme.of(context).textTheme.bodySmall),
            for (final channel in values) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.chevron_right_rounded, size: 16),
              ),
              Text(
                channel.name,
                key: Key('breadcrumb-${channel.id}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      loading: () => const SizedBox(height: 16),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ChannelSection extends StatelessWidget {
  const _ChannelSection({required this.channels, required this.onOpen});
  final List<Channel> channels;
  final ValueChanged<Channel> onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Channels', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      for (final channel in channels)
        _ChannelTile(channel: channel, onTap: () => onOpen(channel)),
    ],
  );
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    selected: selected,
    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.onTap,
    this.selected = false,
  });
  final Channel channel;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('channel-${channel.id}'),
    dense: true,
    selected: selected,
    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    leading: const Icon(Icons.folder_outlined),
    title: Text(channel.name),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

class _EmptyItems extends StatelessWidget {
  const _EmptyItems({
    super.key,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAdd,
  });
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (actionLabel != null && onAdd != null) ...[
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('empty-add-item'),
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(actionLabel!),
          ),
        ],
      ],
    ),
  );
}

class _ItemSection extends StatelessWidget {
  const _ItemSection({super.key, required this.title, required this.items});
  final String title;
  final List<Item> items;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      for (var index = 0; index < items.length; index++) ...[
        _ItemPreview(item: items[index]),
        if (index != items.length - 1) const Divider(height: 1),
      ],
    ],
  );
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
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null && title.isNotEmpty) ...[
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 5),
            ],
            Text(item.content, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (item.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                item.tags.map((tag) => '#$tag').join('  '),
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> _createItem(BuildContext context, String? channelId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ItemEditorScreen.create(channelId: channelId),
      ),
    );

Future<void> _createChannel(
  BuildContext context,
  WidgetRef ref,
  String? parentId,
) async {
  final name = await _nameDialog(context, title: 'New channel');
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

Future<void> _manageChannel(
  BuildContext context,
  WidgetRef ref,
  Channel channel,
  String action,
  VoidCallback onDeleted,
) async {
  try {
    if (action == 'rename') {
      final name = await _nameDialog(
        context,
        title: 'Rename channel',
        initialValue: channel.name,
      );
      if (name != null) {
        await ref
            .read(channelRepositoryProvider)
            .renameChannel(channel.id, name);
      }
    } else if (action == 'move') {
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
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete this channel?'),
          content: const Text('Only an empty channel can be deleted.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('confirm-delete-channel'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await ref.read(channelRepositoryProvider).softDeleteChannel(channel.id);
        onDeleted();
      }
    }
  } catch (error) {
    if (context.mounted) _showError(context, error.toString());
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
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(dialogContext, value);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-channel'),
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, controller.text);
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return result;
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
