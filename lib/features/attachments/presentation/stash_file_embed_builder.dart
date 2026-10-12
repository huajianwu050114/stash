import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../../platform/attachment_file_actions/attachment_file_actions.dart';
import '../../items/data/item_document_codec.dart';
import '../data/attachment_repository.dart';
import '../domain/attachment.dart';
import '../domain/attachment_type.dart';
import 'stash_image_drag_source.dart';

class StashFileEmbedBuilder extends EmbedBuilder {
  const StashFileEmbedBuilder(
    this.repository, {
    required this.fileActions,
    this.maxWidth = 520,
  });

  final AttachmentRepository repository;
  final AttachmentFileActions fileActions;
  final double maxWidth;

  @override
  String get key => stashFileEmbedType;

  @override
  String toPlainText(Embed node) => '';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final attachmentId = embedContext.node.value.data;
    if (attachmentId is! String) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: StashFileCard(
          key: Key('attachment-file-$attachmentId'),
          attachmentId: attachmentId,
          repository: repository,
          fileActions: fileActions,
        ),
      ),
    );
  }
}

class StashFileCard extends StatefulWidget {
  const StashFileCard({
    super.key,
    required this.attachmentId,
    required this.repository,
    required this.fileActions,
    this.compact = false,
  });

  final String attachmentId;
  final AttachmentRepository repository;
  final AttachmentFileActions fileActions;
  final bool compact;

  @override
  State<StashFileCard> createState() => _StashFileCardState();
}

class _StashFileCardState extends State<StashFileCard> {
  late Future<_ResolvedAttachment?> _resolved;

  @override
  void initState() {
    super.initState();
    _resolved = _resolve();
  }

  @override
  void didUpdateWidget(covariant StashFileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        !identical(oldWidget.repository, widget.repository)) {
      _resolved = _resolve();
    }
  }

  Future<_ResolvedAttachment?> _resolve() async {
    final attachment = await widget.repository.getAttachmentById(
      widget.attachmentId,
    );
    if (attachment == null || attachment.isDeleted) return null;
    return _ResolvedAttachment(
      attachment,
      await widget.repository.resolveAttachmentFile(widget.attachmentId),
    );
  }

  Future<void> _open(File file) async {
    try {
      await widget.fileActions.open(file);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open this file.')),
      );
    }
  }

  Future<void> _showInFolder(File file) async {
    try {
      await widget.fileActions.showInFolder(file);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not show this file in its folder.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_ResolvedAttachment?>(
    future: _resolved,
    builder: (context, snapshot) {
      final resolved = snapshot.data;
      if (resolved == null) {
        return _MissingFileCard(attachmentId: widget.attachmentId);
      }
      final attachment = resolved.attachment;
      final file = resolved.file;
      final card = Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: file == null ? null : () => _open(file),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 10 : 12,
              vertical: widget.compact ? 8 : 10,
            ),
            child: Row(
              children: [
                Icon(_iconFor(attachment.kind), size: widget.compact ? 22 : 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.displayName,
                        key: Key('attachment-file-name-${attachment.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        file == null
                            ? 'File unavailable'
                            : _metadataLabel(attachment),
                        key: Key('attachment-file-metadata-${attachment.id}'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: file == null
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (file != null && widget.fileActions.canShowInFolder)
                  IconButton(
                    key: Key('attachment-file-menu-${attachment.id}'),
                    tooltip: 'Show in folder',
                    onPressed: () => _showInFolder(file),
                    icon: const Icon(Icons.folder_open_outlined, size: 20),
                  ),
                if (file == null) const Icon(Icons.error_outline, size: 20),
              ],
            ),
          ),
        ),
      );
      return StashFileDragSource(
        key: Key('attachment-file-drag-${attachment.id}'),
        attachmentId: attachment.id,
        repository: widget.repository,
        child: card,
      );
    },
  );
}

class _MissingFileCard extends StatelessWidget {
  const _MissingFileCard({required this.attachmentId});

  final String attachmentId;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('attachment-file-missing-$attachmentId'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Row(
      children: [
        Icon(Icons.insert_drive_file_outlined),
        SizedBox(width: 10),
        Expanded(child: Text('File unavailable')),
      ],
    ),
  );
}

class _ResolvedAttachment {
  const _ResolvedAttachment(this.attachment, this.file);

  final Attachment attachment;
  final File? file;
}

String formatAttachmentByteSize(int? bytes) {
  if (bytes == null) return 'Unknown size';
  if (bytes < 1024) return '$bytes B';
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) return '${_oneDecimal(kilobytes)} KB';
  final megabytes = kilobytes / 1024;
  if (megabytes < 1024) return '${_oneDecimal(megabytes)} MB';
  return '${_oneDecimal(megabytes / 1024)} GB';
}

String _oneDecimal(double value) =>
    value >= 10 ? value.round().toString() : value.toStringAsFixed(1);

String _metadataLabel(Attachment attachment) {
  final type = attachment.extension.isEmpty
      ? attachment.kind.name.toUpperCase()
      : attachment.extension;
  return '$type · ${formatAttachmentByteSize(attachment.byteSize)}';
}

IconData _iconFor(AttachmentKind kind) => switch (kind) {
  AttachmentKind.pdf => Icons.picture_as_pdf_outlined,
  AttachmentKind.document => Icons.description_outlined,
  AttachmentKind.spreadsheet => Icons.table_chart_outlined,
  AttachmentKind.presentation => Icons.slideshow_outlined,
  AttachmentKind.archive => Icons.folder_zip_outlined,
  AttachmentKind.text => Icons.code_outlined,
  AttachmentKind.image => Icons.image_outlined,
  AttachmentKind.generic => Icons.insert_drive_file_outlined,
};
