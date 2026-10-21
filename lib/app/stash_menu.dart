import 'package:flutter/material.dart';

class StashMenuAction<T> {
  const StashMenuAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
    this.dividerBefore = false,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
  final bool dividerBefore;
  final Key? key;
}

Future<T?> showStashMenu<T>(
  BuildContext context, {
  required Offset globalPosition,
  required List<StashMenuAction<T>> actions,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final localPosition = overlay.globalToLocal(globalPosition);
  final entries = <PopupMenuEntry<T>>[];
  for (final action in actions) {
    if (action.dividerBefore) {
      entries.add(const PopupMenuDivider(height: 7));
    }
    entries.add(
      PopupMenuItem<T>(
        key: action.key,
        value: action.value,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: _StashMenuRow(action: action),
      ),
    );
  }
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      localPosition.dx,
      localPosition.dy,
      overlay.size.width - localPosition.dx,
      overlay.size.height - localPosition.dy,
    ),
    items: entries,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    elevation: 6,
    shadowColor: Colors.black.withValues(alpha: 0.28),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    constraints: const BoxConstraints(minWidth: 150, maxWidth: 240),
    clipBehavior: Clip.antiAlias,
    requestFocus: true,
  );
}

class StashMenuButton<T> extends StatelessWidget {
  const StashMenuButton({
    super.key,
    required this.actions,
    required this.onSelected,
    required this.tooltip,
    this.icon = Icons.more_horiz_rounded,
    this.label,
  });

  final List<StashMenuAction<T>> actions;
  final ValueChanged<T> onSelected;
  final String tooltip;
  final IconData icon;
  final String? label;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final position = button.localToGlobal(Offset(0, button.size.height));
    final selected = await showStashMenu<T>(
      context,
      globalPosition: position,
      actions: actions,
    );
    if (selected != null) onSelected(selected);
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (buttonContext) {
      if (label != null) {
        return FilledButton.tonalIcon(
          onPressed: () => _open(buttonContext),
          icon: Icon(icon, size: 18),
          label: Text(label!),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
        );
      }
      return IconButton(
        tooltip: tooltip,
        onPressed: () => _open(buttonContext),
        icon: Icon(icon, size: 20),
        visualDensity: VisualDensity.compact,
      );
    },
  );
}

class _StashMenuRow<T> extends StatelessWidget {
  const _StashMenuRow({required this.action});

  final StashMenuAction<T> action;

  @override
  Widget build(BuildContext context) {
    final color = action.destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
      child: IconTheme.merge(
        data: IconThemeData(color: color, size: 17),
        child: Row(
          children: [
            if (action.icon != null) ...[
              Icon(action.icon),
              const SizedBox(width: 9),
            ],
            Flexible(child: Text(action.label)),
          ],
        ),
      ),
    );
  }
}
