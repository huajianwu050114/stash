import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../attachments/presentation/drop_environment.dart';
import '../domain/item.dart';

class StashItemDragData {
  const StashItemDragData({required this.itemId, this.sourceChannelId});

  static const itemIdKey = 'stashItemId';
  static const sourceChannelIdKey = 'sourceChannelId';

  final String itemId;
  final String? sourceChannelId;

  Map<String, Object?> toLocalData() => {
    itemIdKey: itemId,
    sourceChannelIdKey: sourceChannelId,
  };

  static StashItemDragData? fromLocalData(Object? value) {
    if (value is! Map) return null;
    final itemId = value[itemIdKey];
    final sourceChannelId = value[sourceChannelIdKey];
    if (itemId is! String ||
        (sourceChannelId != null && sourceChannelId is! String)) {
      return null;
    }
    return StashItemDragData(
      itemId: itemId,
      sourceChannelId: sourceChannelId as String?,
    );
  }
}

class StashItemDragItemFactory {
  const StashItemDragItemFactory();

  DragItem create(Item item) {
    final dragItem = DragItem(
      localData: StashItemDragData(
        itemId: item.id,
        sourceChannelId: item.channelId,
      ).toLocalData(),
    );
    if (item.content.trim().isNotEmpty) {
      dragItem.add(Formats.plainText(item.content));
    }
    return dragItem;
  }
}

class StashTextDragItemFactory {
  const StashTextDragItemFactory();

  DragItem create(String text) {
    final dragItem = DragItem();
    dragItem.add(Formats.plainText(text));
    return dragItem;
  }
}

class StashItemDragSource extends StatelessWidget {
  const StashItemDragSource({
    super.key,
    required this.item,
    required this.child,
  });

  final Item item;
  final Widget child;

  bool get _nativeSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Widget build(BuildContext context) {
    final payload = StashItemDragData(
      itemId: item.id,
      sourceChannelId: item.channelId,
    );
    if (isFlutterTestEnvironment) {
      return Draggable<StashItemDragData>(
        key: Key('item-drag-source-${item.id}'),
        data: payload,
        feedback: _ItemDragFeedback(item: item),
        childWhenDragging: Opacity(opacity: 0.45, child: child),
        child: child,
      );
    }
    if (!_nativeSupported) return child;
    const factory = StashItemDragItemFactory();
    return DragItemWidget(
      key: Key('item-drag-source-${item.id}'),
      dragItemProvider: (_) => factory.create(item),
      allowedOperations: () => const [DropOperation.move, DropOperation.copy],
      dragBuilder: (context, child) => _ItemDragFeedback(item: item),
      child: DraggableWidget(
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
      ),
    );
  }
}

class StashTextDragSource extends StatelessWidget {
  const StashTextDragSource({
    super.key,
    required this.text,
    required this.child,
  });

  final String text;
  final Widget child;

  bool get _nativeSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Widget build(BuildContext context) {
    if (isFlutterTestEnvironment || !_nativeSupported || text.isEmpty) {
      return child;
    }
    const factory = StashTextDragItemFactory();
    return DragItemWidget(
      dragItemProvider: (_) => factory.create(text),
      allowedOperations: () => const [DropOperation.copy],
      child: DraggableWidget(
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
      ),
    );
  }
}

class StashItemDropTarget extends StatefulWidget {
  const StashItemDropTarget({
    super.key,
    required this.channelId,
    required this.onMove,
    required this.child,
    this.onError,
  });

  final String? channelId;
  final Future<void> Function(StashItemDragData data) onMove;
  final VoidCallback? onError;
  final Widget child;

  @override
  State<StashItemDropTarget> createState() => _StashItemDropTargetState();
}

class _StashItemDropTargetState extends State<StashItemDropTarget> {
  bool _hovered = false;

  bool get _nativeSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  bool _canAccept(StashItemDragData? data) =>
      data != null && data.sourceChannelId != widget.channelId;

  Future<void> _move(StashItemDragData data) async {
    if (mounted) setState(() => _hovered = false);
    try {
      await widget.onMove(data);
    } catch (_) {
      widget.onError?.call();
    }
  }

  Iterable<StashItemDragData> _payloads(DropSession session) => session.items
      .map((item) => StashItemDragData.fromLocalData(item.localData))
      .whereType<StashItemDragData>();

  DropOperation _onDropOver(DropOverEvent event) {
    final accepted = _payloads(event.session).any(_canAccept);
    if (_hovered != accepted && mounted) setState(() => _hovered = accepted);
    if (!accepted) return DropOperation.none;
    if (event.session.allowedOperations.contains(DropOperation.move)) {
      return DropOperation.move;
    }
    if (event.session.allowedOperations.contains(DropOperation.copy)) {
      return DropOperation.copy;
    }
    return DropOperation.none;
  }

  Future<void> _onPerformDrop(PerformDropEvent event) async {
    for (final payload in _payloads(event.session)) {
      if (_canAccept(payload)) await _move(payload);
    }
  }

  Widget _decoratedChild(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    decoration: BoxDecoration(
      color: _hovered
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
    ),
    child: widget.child,
  );

  @override
  Widget build(BuildContext context) {
    final child = _decoratedChild(context);
    if (isFlutterTestEnvironment) {
      return DragTarget<StashItemDragData>(
        onWillAcceptWithDetails: (details) {
          final accepted = _canAccept(details.data);
          if (_hovered != accepted) setState(() => _hovered = accepted);
          return accepted;
        },
        onLeave: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        onAcceptWithDetails: (details) => _move(details.data),
        builder: (_, _, _) => child,
      );
    }
    if (!_nativeSupported) return child;
    return DropRegion(
      formats: const [],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: _onDropOver,
      onDropLeave: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      onPerformDrop: _onPerformDrop,
      child: child,
    );
  }
}

class _ItemDragFeedback extends StatelessWidget {
  const _ItemDragFeedback({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final title = item.title?.trim();
    final label = title?.isNotEmpty == true
        ? title!
        : item.content.trim().isEmpty
        ? 'Image item'
        : item.content;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
