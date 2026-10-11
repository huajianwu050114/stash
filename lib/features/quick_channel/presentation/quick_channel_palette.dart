import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../attachments/data/attachment_repository.dart';
import '../../attachments/presentation/stash_image_drag_source.dart';
import '../../items/data/item_document_codec.dart';
import '../../items/domain/item.dart';

class QuickChannelPalette extends ConsumerWidget {
  const QuickChannelPalette({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(channelId));
    final items = ref.watch(channelItemsProvider(channelId));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            ref.read(quickStashControllerProvider).hideQuick(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                _PaletteHeader(
                  title: channel.value?.name ?? 'Quick Channel',
                  onClose: () =>
                      ref.read(quickStashControllerProvider).hideQuick(),
                ),
                const Divider(height: 1),
                Expanded(
                  child: channel.when(
                    data: (value) => value == null || value.isDeleted
                        ? const _PaletteMessage('Channel is unavailable.')
                        : items.when(
                            data: (value) => _PaletteContents(items: value),
                            loading: () => const Center(
                              child: CircularProgressIndicator(),
                            ),
                            error: (_, _) => const _PaletteMessage(
                              'Could not load this Channel.',
                            ),
                          ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, _) =>
                        const _PaletteMessage('Could not load this Channel.'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteHeader extends StatelessWidget {
  const _PaletteHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.only(left: 16, right: 8),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              key: const Key('quick-channel-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            key: const Key('quick-channel-close'),
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    ),
  );
}

class _PaletteContents extends ConsumerWidget {
  const _PaletteContents({required this.items});

  static const _codec = ItemDocumentCodec();
  final List<Item> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = <String>[];
    final textItems = <Item>[];
    for (final item in items) {
      try {
        final document = _codec.decode(
          documentJson: item.documentJson,
          legacyText: item.content,
        );
        final attachmentIds = _codec.snapshot(document).imageAttachmentIds;
        if (attachmentIds.isEmpty) {
          textItems.add(item);
        } else {
          images.addAll(attachmentIds);
        }
      } catch (_) {
        textItems.add(item);
      }
    }
    if (images.isEmpty && textItems.isEmpty) {
      return const _PaletteMessage('This Channel is empty.');
    }

    return CustomScrollView(
      key: const Key('quick-channel-contents'),
      slivers: [
        if (images.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: images.length,
              itemBuilder: (context, index) =>
                  _PaletteImage(attachmentId: images[index]),
            ),
          ),
        ],
        if (textItems.isNotEmpty) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, images.isEmpty ? 12 : 8, 16, 6),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Text items',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          SliverList.separated(
            itemCount: textItems.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
            itemBuilder: (context, index) {
              final item = textItems[index];
              final title = item.title?.trim();
              return ListTile(
                key: Key('quick-channel-text-${item.id}'),
                dense: true,
                title: Text(
                  title == null || title.isEmpty ? item.content : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: title == null || title.isEmpty
                    ? null
                    : Text(
                        item.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
              );
            },
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}

class _PaletteImage extends ConsumerStatefulWidget {
  const _PaletteImage({required this.attachmentId});

  final String attachmentId;

  @override
  ConsumerState<_PaletteImage> createState() => _PaletteImageState();
}

class _PaletteImageState extends ConsumerState<_PaletteImage> {
  late AttachmentRepository _repository;
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(attachmentRepositoryProvider);
    _bytes = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _PaletteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId) {
      _bytes = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() => _repository
      .resolveAttachmentFile(widget.attachmentId)
      .then((file) => file?.readAsBytes());

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(attachmentRepositoryProvider);
    if (!identical(repository, _repository)) {
      _repository = repository;
      _bytes = _loadBytes();
    }
    return StashImageDragSource(
      key: Key('quick-channel-image-${widget.attachmentId}'),
      attachmentId: widget.attachmentId,
      repository: repository,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: FutureBuilder<Uint8List?>(
            future: _bytes,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
                return const Center(child: Icon(Icons.image_outlined));
              }
              return Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: 360,
                errorBuilder: (_, _, _) =>
                    const Center(child: Icon(Icons.broken_image_outlined)),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PaletteMessage extends StatelessWidget {
  const _PaletteMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
