import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../items/data/item_document_codec.dart';
import '../data/attachment_repository.dart';
import 'stash_image_drag_source.dart';

class StashImageEmbedBuilder extends EmbedBuilder {
  const StashImageEmbedBuilder(
    this.repository, {
    this.maxWidth = double.infinity,
    this.maxHeight = 520,
    this.cacheWidth,
    this.expandWidth = true,
  });

  final AttachmentRepository repository;
  final double maxWidth;
  final double maxHeight;
  final int? cacheWidth;
  final bool expandWidth;

  @override
  String get key => stashImageEmbedType;

  @override
  String toPlainText(Embed node) => '';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final attachmentId = embedContext.node.value.data;
    if (attachmentId is! String) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: Key('attachment-image-$attachmentId'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: StashImageDragSource(
        key: Key('attachment-drag-source-$attachmentId'),
        attachmentId: attachmentId,
        repository: repository,
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            key: Key('attachment-display-$attachmentId'),
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: FutureBuilder<Uint8List?>(
              future: _loadBytes(attachmentId),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null) {
                  return Container(
                    width: expandWidth ? double.infinity : 240,
                    height: 120,
                    alignment: Alignment.center,
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: const Text('Image unavailable'),
                  );
                }
                return Image.memory(
                  bytes,
                  width: expandWidth ? double.infinity : null,
                  fit: BoxFit.contain,
                  cacheWidth: cacheWidth,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 120,
                    child: Center(child: Text('Image unavailable')),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _loadBytes(String attachmentId) async {
    final file = await repository.resolveAttachmentFile(attachmentId);
    return file?.readAsBytes();
  }
}
