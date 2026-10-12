import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/dev_profile_badge.dart';
import '../../attachments/data/attachment_repository.dart';
import '../../attachments/presentation/stash_file_embed_builder.dart';
import '../../attachments/presentation/stash_image_drag_source.dart';
import '../../items/data/item_document_codec.dart';
import '../../items/domain/item.dart';
import '../../items/presentation/item_drag_drop.dart';

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
    height: 48,
    child: Padding(
      padding: const EdgeInsets.only(left: 14, right: 6),
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
          const DevProfileBadge(),
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

class _PaletteContents extends ConsumerStatefulWidget {
  const _PaletteContents({required this.items});

  final List<Item> items;

  @override
  ConsumerState<_PaletteContents> createState() => _PaletteContentsState();
}

class _PaletteContentsState extends ConsumerState<_PaletteContents> {
  late AttachmentRepository _repository;
  late List<String> _imageIds;
  late Future<_ResolvedPaletteImages> _resolvedImages;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(attachmentRepositoryProvider);
    _imageIds = _partitionPaletteItems(widget.items).images;
    _resolvedImages = _resolveImages();
  }

  @override
  void didUpdateWidget(covariant _PaletteContents oldWidget) {
    super.didUpdateWidget(oldWidget);
    final imageIds = _partitionPaletteItems(widget.items).images;
    if (!listEquals(imageIds, _imageIds)) {
      _imageIds = imageIds;
      _resolvedImages = _resolveImages();
    }
  }

  Future<_ResolvedPaletteImages> _resolveImages() async {
    final available = <_PaletteImageData>[];
    var missing = 0;
    for (final attachmentId in _imageIds) {
      try {
        final file = await _repository.resolveAttachmentFile(attachmentId);
        final bytes = await file?.readAsBytes();
        if (bytes == null || bytes.isEmpty) {
          missing++;
        } else {
          available.add(
            _PaletteImageData(attachmentId: attachmentId, bytes: bytes),
          );
        }
      } catch (_) {
        missing++;
      }
    }
    return _ResolvedPaletteImages(available: available, missing: missing);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ref.watch(attachmentRepositoryProvider);
    if (!identical(repository, _repository)) {
      _repository = repository;
      _resolvedImages = _resolveImages();
    }
    final partition = _partitionPaletteItems(widget.items);
    if (_imageIds.isEmpty &&
        partition.files.isEmpty &&
        partition.textItems.isEmpty) {
      return const _PaletteMessage('This Channel is empty.');
    }

    return FutureBuilder<_ResolvedPaletteImages>(
      future: _resolvedImages,
      builder: (context, snapshot) {
        final images = snapshot.data;
        return CustomScrollView(
          key: const Key('quick-channel-contents'),
          slivers: [
            if (snapshot.connectionState != ConnectionState.done &&
                _imageIds.isNotEmpty)
              const SliverToBoxAdapter(
                child: SizedBox(
                  height: 64,
                  child: Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            if (images != null && images.available.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                sliver: SliverToBoxAdapter(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final image in images.available)
                        SizedBox(
                          width: 144,
                          height: 112,
                          child: _PaletteImage(image: image),
                        ),
                    ],
                  ),
                ),
              ),
            if (images != null && images.missing > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                  child: Container(
                    key: const Key('quick-channel-missing-images'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.broken_image_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          images.missing == 1
                              ? '1 image unavailable'
                              : '${images.missing} images unavailable',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (partition.files.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'Files',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverList.separated(
                  itemCount: partition.files.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final attachmentId = partition.files[index];
                    return StashFileCard(
                      key: Key('quick-channel-file-$attachmentId'),
                      attachmentId: attachmentId,
                      repository: repository,
                      fileActions: ref.watch(attachmentFileActionsProvider),
                      compact: true,
                    );
                  },
                ),
              ),
            ],
            if (partition.textItems.isNotEmpty) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  (images?.available.isEmpty ?? true) && partition.files.isEmpty
                      ? 12
                      : 8,
                  16,
                  6,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'Text items',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ),
              SliverList.separated(
                itemCount: partition.textItems.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 16),
                itemBuilder: (context, index) {
                  final item = partition.textItems[index];
                  final title = item.title?.trim();
                  return StashTextDragSource(
                    key: Key('quick-channel-text-drag-${item.id}'),
                    text: item.content.trim().isEmpty
                        ? title ?? ''
                        : item.content,
                    child: ListTile(
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
                    ),
                  );
                },
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
        );
      },
    );
  }
}

class _PaletteImageData {
  const _PaletteImageData({required this.attachmentId, required this.bytes});

  final String attachmentId;
  final Uint8List bytes;
}

class _ResolvedPaletteImages {
  const _ResolvedPaletteImages({
    required this.available,
    required this.missing,
  });

  final List<_PaletteImageData> available;
  final int missing;
}

class _PaletteImage extends ConsumerWidget {
  const _PaletteImage({required this.image});

  final _PaletteImageData image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(attachmentRepositoryProvider);
    return StashImageDragSource(
      key: Key('quick-channel-image-${image.attachmentId}'),
      attachmentId: image.attachmentId,
      repository: repository,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Image.memory(
            image.bytes,
            fit: BoxFit.cover,
            cacheWidth: 288,
            cacheHeight: 224,
            errorBuilder: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image_outlined)),
          ),
        ),
      ),
    );
  }
}

({List<String> images, List<String> files, List<Item> textItems})
_partitionPaletteItems(List<Item> items) {
  const codec = ItemDocumentCodec();
  final images = <String>[];
  final files = <String>[];
  final textItems = <Item>[];
  for (final item in items) {
    try {
      final document = codec.decode(
        documentJson: item.documentJson,
        legacyText: item.content,
      );
      final snapshot = codec.snapshot(document);
      images.addAll(snapshot.imageAttachmentIds);
      files.addAll(snapshot.fileAttachmentIds);
      final hasText =
          item.content.trim().isNotEmpty ||
          (item.title?.trim().isNotEmpty ?? false);
      if (hasText || snapshot.attachmentIds.isEmpty) {
        textItems.add(item);
      }
    } catch (_) {
      textItems.add(item);
    }
  }
  return (images: images, files: files, textItems: textItems);
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
