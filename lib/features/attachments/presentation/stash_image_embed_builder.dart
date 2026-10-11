import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../items/data/item_document_codec.dart';
import '../data/attachment_repository.dart';
import 'stash_image_drag_source.dart';

class StashImageEmbedBuilder extends EmbedBuilder {
  const StashImageEmbedBuilder(this.repository);

  final AttachmentRepository repository;

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
        child: FutureBuilder<Uint8List?>(
          future: _loadBytes(attachmentId),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return Container(
                height: 120,
                alignment: Alignment.center,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Text('Image unavailable'),
              );
            }
            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 520),
              child: Image.memory(
                bytes,
                width: double.infinity,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 120,
                  child: Center(child: Text('Image unavailable')),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<Uint8List?> _loadBytes(String attachmentId) async {
    final file = await repository.resolveAttachmentFile(attachmentId);
    return file?.readAsBytes();
  }
}
