import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/desktop_shell_preferences.dart';
import '../../../app/providers.dart';
import '../../../app/dev_profile_badge.dart';
import '../../attachments/data/attachment_repository.dart';
import '../../channels/domain/channel.dart';
import '../../channels/presentation/location_picker.dart';
import '../data/item_document_codec.dart';
import '../domain/item.dart';
import '../../quick_stash/presentation/quick_stash_settings_screen.dart';
import 'item_detail_screen.dart';
import 'item_drag_drop.dart';
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

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const QuickStashSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final sidebarCollapsed =
          ref.watch(desktopSidebarCollapsedProvider).value ?? false;
      final savedSidebarWidth =
          ref.watch(desktopSidebarWidthProvider).value ??
          DesktopSidebarDimensions.defaultExpandedWidth;
      final viewportSidebarMaximum = (constraints.maxWidth - 480).clamp(
        DesktopSidebarDimensions.minimumExpandedWidth,
        DesktopSidebarDimensions.maximumExpandedWidth,
      );
      final expandedSidebarWidth = savedSidebarWidth.clamp(
        DesktopSidebarDimensions.minimumExpandedWidth,
        viewportSidebarMaximum,
      );
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: wide ? 48 : 60,
          titleSpacing: wide ? 16 : 20,
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Stash',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const DevProfileBadge(),
              ],
            ),
          ),
          actions: [
            PopupMenuButton<ThemeMode>(
              key: const Key('appearance-menu'),
              tooltip: 'Appearance',
              icon: const Icon(Icons.brightness_6_outlined),
              onSelected: (mode) =>
                  ref.read(appearanceProvider.notifier).setThemeMode(mode),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  key: Key('appearance-system'),
                  value: ThemeMode.system,
                  child: Text('System appearance'),
                ),
                PopupMenuItem(
                  key: Key('appearance-light'),
                  value: ThemeMode.light,
                  child: Text('Light'),
                ),
                PopupMenuItem(
                  key: Key('appearance-dark'),
                  value: ThemeMode.dark,
                  child: Text('Dark'),
                ),
              ],
            ),
            if (!wide)
              IconButton(
                key: const Key('settings-button'),
                tooltip: 'Settings',
                onPressed: () => _openSettings(context),
                icon: const Icon(Icons.settings_outlined),
              ),
            FilledButton.tonalIcon(
              key: const Key('new-item-button'),
              onPressed: () => _createItem(context, null),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: Text(wide ? 'New' : 'Add item'),
            ),
            SizedBox(width: wide ? 12 : 16),
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
                      key: const Key('desktop-sidebar'),
                      width: sidebarCollapsed
                          ? DesktopSidebarDimensions.collapsedWidth
                          : expandedSidebarWidth,
                      child: _RootPane(
                        compact: true,
                        collapsed: sidebarCollapsed,
                        selectedKind: _selectedKind,
                        selectedChannelId: _selectedChannelId,
                        onSpecial: (kind) => _openSpecial(context, kind, true),
                        onChannel: (channel) =>
                            _openChannel(context, channel, true),
                        onSettings: () => _openSettings(context),
                        onToggleCollapsed: () => ref
                            .read(desktopSidebarCollapsedProvider.notifier)
                            .setCollapsed(!sidebarCollapsed),
                      ),
                    ),
                    if (sidebarCollapsed)
                      const VerticalDivider(width: 1)
                    else
                      _DesktopSidebarResizeHandle(
                        key: const Key('desktop-sidebar-resize-handle'),
                        onDragUpdate: (delta) => ref
                            .read(desktopSidebarWidthProvider.notifier)
                            .previewWidth(expandedSidebarWidth + delta),
                        onDragEnd: () => ref
                            .read(desktopSidebarWidthProvider.notifier)
                            .persistWidth(),
                        onReset: () => ref
                            .read(desktopSidebarWidthProvider.notifier)
                            .resetWidth(),
                      ),
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
                  collapsed: false,
                  selectedKind: null,
                  selectedChannelId: null,
                  onSpecial: (kind) => _openSpecial(context, kind, false),
                  onChannel: (channel) => _openChannel(context, channel, false),
                  onSettings: () => _openSettings(context),
                ),
        ),
      );
    },
  );
}

class _DesktopSidebarResizeHandle extends StatefulWidget {
  const _DesktopSidebarResizeHandle({
    super.key,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
  });

  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  State<_DesktopSidebarResizeHandle> createState() =>
      _DesktopSidebarResizeHandleState();
}

class _DesktopSidebarResizeHandleState
    extends State<_DesktopSidebarResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  void _finishDrag() {
    if (_dragging) setState(() => _dragging = false);
    widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dividerColor = _dragging
        ? colorScheme.primary.withValues(alpha: 0.78)
        : _hovered
        ? colorScheme.outline.withValues(alpha: 0.72)
        : Theme.of(context).dividerColor;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (details) =>
            widget.onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => _finishDrag(),
        onHorizontalDragCancel: _finishDrag,
        onDoubleTap: widget.onReset,
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(width: _dragging ? 2 : 1, color: dividerColor),
          ),
        ),
      ),
    );
  }
}

class _RootPane extends ConsumerWidget {
  const _RootPane({
    required this.compact,
    required this.collapsed,
    required this.selectedKind,
    required this.selectedChannelId,
    required this.onSpecial,
    required this.onChannel,
    required this.onSettings,
    this.onToggleCollapsed,
  });

  final bool compact;
  final bool collapsed;
  final _ViewKind? selectedKind;
  final String? selectedChannelId;
  final ValueChanged<_ViewKind> onSpecial;
  final ValueChanged<Channel> onChannel;
  final VoidCallback onSettings;
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(rootChannelsProvider);
    final inbox = ref.watch(inboxItemsProvider);
    if (collapsed) {
      return _CollapsedRootPane(
        channels: channels,
        selectedKind: selectedKind,
        selectedChannelId: selectedChannelId,
        onSpecial: onSpecial,
        onChannel: onChannel,
        onSettings: onSettings,
        onExpand: onToggleCollapsed!,
      );
    }
    return ListView(
      key: const Key('root-browser'),
      padding: EdgeInsets.fromLTRB(compact ? 10 : 20, 8, compact ? 10 : 20, 32),
      children: [
        if (compact)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const Key('collapse-sidebar'),
              tooltip: 'Collapse sidebar',
              onPressed: onToggleCollapsed,
              icon: const Icon(Icons.chevron_left_rounded, size: 22),
            ),
          ),
        _ItemDropTarget(
          channelId: null,
          child: _LocationTile(
            key: const Key('open-inbox'),
            icon: Icons.inbox_outlined,
            title: 'Inbox',
            subtitle: 'Things you saved without filing',
            selected: selectedKind == _ViewKind.inbox,
            onTap: () => onSpecial(_ViewKind.inbox),
          ),
        ),
        _LocationTile(
          key: const Key('open-pinned'),
          icon: Icons.push_pin_outlined,
          title: 'Pinned',
          subtitle: 'Important items from everywhere',
          selected: selectedKind == _ViewKind.pinned,
          onTap: () => onSpecial(_ViewKind.pinned),
        ),
        const SizedBox(height: 18),
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
            if (compact)
              IconButton(
                key: const Key('new-root-channel'),
                tooltip: 'New channel',
                onPressed: () => _createChannel(context, ref, null),
                icon: const Icon(Icons.create_new_folder_outlined, size: 19),
              )
            else
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
        if (compact) ...[
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('sidebar-settings'),
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            leading: const Icon(Icons.settings_outlined, size: 20),
            title: const Text('Settings'),
            onTap: onSettings,
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 20),
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

class _CollapsedRootPane extends StatelessWidget {
  const _CollapsedRootPane({
    required this.channels,
    required this.selectedKind,
    required this.selectedChannelId,
    required this.onSpecial,
    required this.onChannel,
    required this.onSettings,
    required this.onExpand,
  });

  final AsyncValue<List<Channel>> channels;
  final _ViewKind? selectedKind;
  final String? selectedChannelId;
  final ValueChanged<_ViewKind> onSpecial;
  final ValueChanged<Channel> onChannel;
  final VoidCallback onSettings;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 4),
      IconButton(
        key: const Key('expand-sidebar'),
        tooltip: 'Expand sidebar',
        onPressed: onExpand,
        icon: const Icon(Icons.chevron_right_rounded, size: 22),
      ),
      const Divider(height: 9, indent: 8, endIndent: 8),
      Expanded(
        child: ListView(
          key: const Key('collapsed-root-browser'),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            _ItemDropTarget(
              channelId: null,
              child: _SidebarIconButton(
                key: const Key('open-inbox'),
                icon: Icons.inbox_outlined,
                tooltip: 'Inbox',
                selected: selectedKind == _ViewKind.inbox,
                onTap: () => onSpecial(_ViewKind.inbox),
              ),
            ),
            _SidebarIconButton(
              key: const Key('open-pinned'),
              icon: Icons.push_pin_outlined,
              tooltip: 'Pinned',
              selected: selectedKind == _ViewKind.pinned,
              onTap: () => onSpecial(_ViewKind.pinned),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Divider(height: 1),
            ),
            ...channels.when(
              data: (values) => [
                for (final channel in values)
                  _ItemDropTarget(
                    channelId: channel.id,
                    child: _SidebarIconButton(
                      key: Key('channel-${channel.id}'),
                      icon: Icons.folder_outlined,
                      tooltip: channel.name,
                      selected: selectedChannelId == channel.id,
                      onTap: () => onChannel(channel),
                    ),
                  ),
              ],
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              error: (_, _) => const [
                Tooltip(
                  message: 'Channels could not be loaded',
                  child: Icon(Icons.error_outline, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
      const Divider(height: 1, indent: 8, endIndent: 8),
      _SidebarIconButton(
        key: const Key('sidebar-settings'),
        icon: Icons.settings_outlined,
        tooltip: 'Settings',
        selected: false,
        onTap: onSettings,
      ),
      const SizedBox(height: 6),
    ],
  );
}

class _SidebarIconButton extends StatelessWidget {
  const _SidebarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            height: 42,
            child: Icon(
              icon,
              size: 20,
              color: selected
                  ? Theme.of(context).colorScheme.onSecondaryContainer
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ),
  );
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
                        padding: const EdgeInsets.only(top: 20),
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
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1080),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (breadcrumbs != null) ...[
              breadcrumbs!,
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                ...actions,
              ],
            ),
            const SizedBox(height: 10),
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
      const SizedBox(height: 6),
      for (final channel in channels)
        Padding(
          padding: const EdgeInsets.only(left: 10),
          child: _ChannelTile(
            channel: channel,
            nested: true,
            onTap: () => onOpen(channel),
          ),
        ),
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
    this.nested = false,
  });
  final Channel channel;
  final VoidCallback onTap;
  final bool selected;
  final bool nested;

  @override
  Widget build(BuildContext context) => _ItemDropTarget(
    channelId: channel.id,
    child: ListTile(
      key: Key('channel-${channel.id}'),
      dense: true,
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(
        nested ? Icons.folder_open_outlined : Icons.folder_outlined,
        size: 20,
      ),
      title: Text(channel.name),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
      onTap: onTap,
    ),
  );
}

class _ItemDropTarget extends ConsumerWidget {
  const _ItemDropTarget({required this.channelId, required this.child});

  final String? channelId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => StashItemDropTarget(
    channelId: channelId,
    onMove: (data) => ref
        .read(itemRepositoryProvider)
        .moveItem(data.itemId, channelId: channelId),
    onError: () => ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not move this item.'))),
    child: child,
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
    padding: const EdgeInsets.symmetric(vertical: 24),
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
          const SizedBox(height: 16),
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
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      key: const Key('item-list-content'),
      constraints: const BoxConstraints(maxWidth: 860),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (var index = 0; index < items.length; index++) ...[
            _ItemPreview(item: items[index]),
            if (index != items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    ),
  );
}

class _ItemPreview extends StatelessWidget {
  const _ItemPreview({required this.item});
  final Item item;
  static const _codec = ItemDocumentCodec();

  ItemDocumentSnapshot? get _documentSnapshot {
    try {
      final document = _codec.decode(
        documentJson: item.documentJson,
        legacyText: item.content,
      );
      return _codec.snapshot(document);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = item.title?.trim();
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final snapshot = _documentSnapshot;
    final imageAttachmentIds =
        snapshot?.imageAttachmentIds.toList() ?? const [];
    final fileAttachmentIds = snapshot?.fileAttachmentIds.toList() ?? const [];
    final colorScheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(10));
    final preview = Material(
      key: Key('item-surface-${item.id}'),
      color: Color.alphaBlend(
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
        colorScheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('item-preview-${item.id}'),
        borderRadius: radius,
        hoverColor: colorScheme.primary.withValues(alpha: 0.055),
        splashColor: colorScheme.primary.withValues(alpha: 0.10),
        highlightColor: colorScheme.primary.withValues(alpha: 0.075),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ItemDetailScreen(itemId: item.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null && title.isNotEmpty) ...[
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 5),
                    ],
                    if (item.content.trim().isNotEmpty)
                      Text(
                        item.content,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      )
                    else if (fileAttachmentIds.isNotEmpty)
                      _ItemFileSummary(
                        itemId: item.id,
                        attachmentIds: fileAttachmentIds,
                      )
                    else if (imageAttachmentIds.isNotEmpty)
                      Text(
                        imageAttachmentIds.length == 1
                            ? 'Image'
                            : '${imageAttachmentIds.length} images',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (item.content.trim().isNotEmpty &&
                        fileAttachmentIds.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _ItemFileSummary(
                        itemId: item.id,
                        attachmentIds: fileAttachmentIds,
                      ),
                    ],
                    if (item.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        item.tags.map((tag) => '#$tag').join('  '),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (imageAttachmentIds.isNotEmpty) ...[
                const SizedBox(width: 12),
                _ItemImageThumbnail(
                  itemId: item.id,
                  attachmentIds: imageAttachmentIds,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return desktop ? StashItemDragSource(item: item, child: preview) : preview;
  }
}

class _ItemFileSummary extends ConsumerWidget {
  const _ItemFileSummary({required this.itemId, required this.attachmentIds});

  final String itemId;
  final List<String> attachmentIds;

  Future<String> _label(AttachmentRepository repository) async {
    if (attachmentIds.length > 1) return '${attachmentIds.length} files';
    final attachment = await repository.getAttachmentById(attachmentIds.single);
    return attachment?.displayName ?? 'File unavailable';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<String>(
    future: _label(ref.watch(attachmentRepositoryProvider)),
    initialData: attachmentIds.length == 1
        ? '1 file'
        : '${attachmentIds.length} files',
    builder: (context, snapshot) => Row(
      key: Key('item-file-summary-$itemId'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.attach_file_rounded, size: 16),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            snapshot.data!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ItemImageThumbnail extends ConsumerStatefulWidget {
  const _ItemImageThumbnail({
    required this.itemId,
    required this.attachmentIds,
  });

  final String itemId;
  final List<String> attachmentIds;

  @override
  ConsumerState<_ItemImageThumbnail> createState() =>
      _ItemImageThumbnailState();
}

class _ItemImageThumbnailState extends ConsumerState<_ItemImageThumbnail> {
  late AttachmentRepository _repository;
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(attachmentRepositoryProvider);
    _bytes = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _ItemImageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentIds.first != widget.attachmentIds.first) {
      _bytes = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() async {
    final file = await _repository.resolveAttachmentFile(
      widget.attachmentIds.first,
    );
    return file?.readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(attachmentRepositoryProvider);
    if (!identical(repository, _repository)) {
      _repository = repository;
      _bytes = _loadBytes();
    }
    return SizedBox.square(
      key: Key('item-thumbnail-${widget.itemId}'),
      dimension: 80,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: FutureBuilder<Uint8List?>(
                future: _bytes,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const Icon(Icons.image_not_supported_outlined);
                  }
                  return Image.memory(
                    bytes,
                    key: Key(
                      'item-thumbnail-image-${widget.attachmentIds.first}',
                    ),
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    cacheWidth: 160,
                    cacheHeight: 160,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  );
                },
              ),
            ),
            if (widget.attachmentIds.length > 1)
              Positioned(
                right: 5,
                bottom: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      '+${widget.attachmentIds.length - 1}',
                      key: Key('item-thumbnail-count-${widget.itemId}'),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ),
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
