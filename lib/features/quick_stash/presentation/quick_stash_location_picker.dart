import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../channels/domain/channel.dart';

class QuickStashLocationSelection {
  const QuickStashLocationSelection({
    required this.channelId,
    required this.label,
  });

  final String? channelId;
  final String label;
}

class QuickStashLocationPickerController {
  VoidCallback? _moveUp;
  VoidCallback? _moveDown;
  VoidCallback? _select;
  VoidCallback? _close;
  bool Function()? _isCreatingChannel;

  bool get isCreatingChannel => _isCreatingChannel?.call() ?? false;

  void moveUp() => _moveUp?.call();
  void moveDown() => _moveDown?.call();
  void select() => _select?.call();
  void close() => _close?.call();

  void attach({
    required VoidCallback moveUp,
    required VoidCallback moveDown,
    required VoidCallback select,
    required VoidCallback close,
    required bool Function() isCreatingChannel,
  }) {
    _moveUp = moveUp;
    _moveDown = moveDown;
    _select = select;
    _close = close;
    _isCreatingChannel = isCreatingChannel;
  }

  void detach() {
    _moveUp = null;
    _moveDown = null;
    _select = null;
    _close = null;
    _isCreatingChannel = null;
  }
}

Future<QuickStashLocationSelection?> showQuickStashLocationPicker(
  BuildContext context, {
  required QuickStashLocationPickerController controller,
  required String? currentChannelId,
}) => showDialog<QuickStashLocationSelection>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.28),
  builder: (context) => _QuickStashLocationPicker(
    controller: controller,
    currentChannelId: currentChannelId,
  ),
);

class _QuickStashLocationPicker extends ConsumerStatefulWidget {
  const _QuickStashLocationPicker({
    required this.controller,
    required this.currentChannelId,
  });

  final QuickStashLocationPickerController controller;
  final String? currentChannelId;

  @override
  ConsumerState<_QuickStashLocationPicker> createState() =>
      _QuickStashLocationPickerState();
}

class _QuickStashLocationPickerState
    extends ConsumerState<_QuickStashLocationPicker> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'quick-location-search');
  final _scrollController = ScrollController();
  int _highlightedIndex = 0;
  bool _creatingChannel = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.attach(
      moveUp: () => _moveHighlight(-1),
      moveDown: () => _moveHighlight(1),
      select: _selectHighlighted,
      close: () => Navigator.of(context).pop(),
      isCreatingChannel: () => _creatingChannel,
    );
    _searchController.addListener(_searchChanged);
  }

  @override
  void dispose() {
    widget.controller.detach();
    _searchController
      ..removeListener(_searchChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _searchChanged() {
    if (!mounted) return;
    setState(() => _highlightedIndex = 0);
  }

  List<_LocationEntry> _visibleEntries(List<Channel> channels) {
    final entries = <_LocationEntry>[
      const _LocationEntry(channelId: null, label: '收件箱'),
      ..._quickStashChannelEntries(channels),
    ];
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return entries;
    return entries
        .where(
          (entry) =>
              entry.channelId == null ||
              entry.label.toLowerCase().contains(query),
        )
        .toList();
  }

  void _moveHighlight(int delta) {
    final channels =
        ref.read(activeChannelsProvider).value ?? const <Channel>[];
    final entries = _visibleEntries(channels);
    if (entries.isEmpty) return;
    setState(() {
      _highlightedIndex = (_highlightedIndex + delta)
          .clamp(0, entries.length - 1)
          .toInt();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = (_highlightedIndex * 36.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    });
  }

  void _selectHighlighted() {
    final channels =
        ref.read(activeChannelsProvider).value ?? const <Channel>[];
    final entries = _visibleEntries(channels);
    if (entries.isEmpty) return;
    final safeIndex = _highlightedIndex.clamp(0, entries.length - 1).toInt();
    _select(entries[safeIndex]);
  }

  void _select(_LocationEntry entry) {
    Navigator.of(context).pop(
      QuickStashLocationSelection(
        channelId: entry.channelId,
        label: entry.label,
      ),
    );
  }

  Future<void> _createRootChannel() async {
    setState(() {
      _creatingChannel = true;
      _error = null;
    });
    final name = await _showCreateChannelDialog(context);
    if (!mounted) return;
    if (name == null) {
      setState(() => _creatingChannel = false);
      _searchFocusNode.requestFocus();
      return;
    }
    try {
      final channel = await ref
          .read(channelRepositoryProvider)
          .createRootChannel(name: name);
      if (!mounted) return;
      Navigator.of(context).pop(
        QuickStashLocationSelection(channelId: channel.id, label: channel.name),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _creatingChannel = false;
        _error = '无法创建频道。';
      });
      _searchFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels =
        ref.watch(activeChannelsProvider).value ?? const <Channel>[];
    final entries = _visibleEntries(channels);
    if (_highlightedIndex >= entries.length) {
      _highlightedIndex = entries.isEmpty ? 0 : entries.length - 1;
    }
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const Key('quick-location-picker'),
      alignment: Alignment.bottomCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 24, 16, 72),
      backgroundColor: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 420),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 36,
                child: TextField(
                  key: const Key('quick-location-search'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '搜索频道',
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: ListView.builder(
                  key: const Key('quick-location-results'),
                  controller: _scrollController,
                  shrinkWrap: true,
                  itemExtent: 36,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final highlighted = index == _highlightedIndex;
                    final selected = entry.channelId == widget.currentChannelId;
                    return _LocationRow(
                      key: entry.channelId == null
                          ? const Key('quick-location-inbox')
                          : Key('quick-location-${entry.channelId}'),
                      entry: entry,
                      highlighted: highlighted,
                      selected: selected,
                      onHover: () => setState(() => _highlightedIndex = index),
                      onTap: () => _select(entry),
                    );
                  },
                ),
              ),
              const Divider(height: 9),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text(
                    _error!,
                    key: const Key('quick-location-error'),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.error),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('quick-create-channel'),
                  onPressed: _creatingChannel ? null : _createRootChannel,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('新建频道'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    super.key,
    required this.entry,
    required this.highlighted,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final _LocationEntry entry;
  final bool highlighted;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: Material(
        color: highlighted
            ? colors.onSurface.withValues(alpha: selected ? 0.13 : 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              children: [
                Icon(
                  entry.channelId == null
                      ? Icons.inbox_outlined
                      : Icons.folder_outlined,
                  size: 17,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    entry.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.check_rounded, size: 17),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> _showCreateChannelDialog(BuildContext context) async {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => const _CreateChannelDialog(),
  );
}

class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建频道'),
    content: TextField(
      key: const Key('quick-channel-name-field'),
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: '频道名称'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('quick-save-channel'),
        onPressed: _submit,
        child: const Text('创建'),
      ),
    ],
  );
}

List<_LocationEntry> _quickStashChannelEntries(List<Channel> channels) {
  final byId = {for (final channel in channels) channel.id: channel};
  String pathFor(Channel channel) {
    final names = <String>[];
    final seen = <String>{};
    Channel? cursor = channel;
    while (cursor != null && seen.add(cursor.id)) {
      names.add(cursor.name);
      cursor = cursor.parentId == null ? null : byId[cursor.parentId];
    }
    return names.reversed.join(' / ');
  }

  final entries = channels
      .map(
        (channel) =>
            _LocationEntry(channelId: channel.id, label: pathFor(channel)),
      )
      .toList();
  entries.sort((a, b) => a.label.compareTo(b.label));
  return entries;
}

class _LocationEntry {
  const _LocationEntry({required this.channelId, required this.label});

  final String? channelId;
  final String label;
}
