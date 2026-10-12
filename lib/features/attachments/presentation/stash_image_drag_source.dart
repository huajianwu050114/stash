import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../data/attachment_repository.dart';
import 'drop_environment.dart';

class StashAttachmentDragItemFactory {
  const StashAttachmentDragItemFactory(this._repository);

  final AttachmentRepository _repository;

  Future<DragItem?> create(
    String attachmentId, {
    bool includeImageData = false,
  }) async {
    final attachment = await _repository.getAttachmentById(attachmentId);
    final file = await _repository.resolveAttachmentFile(attachmentId);
    if (attachment == null || attachment.isDeleted || file == null) return null;

    final item = DragItem(
      localData: {'stashAttachmentId': attachmentId},
      suggestedName: path.basename(attachment.originalFileName ?? file.path),
    );
    item.add(Formats.fileUri(file.uri));
    if (includeImageData && attachment.isImage) {
      final imageFormat = switch (attachment.mimeType.toLowerCase()) {
        'image/jpeg' => Formats.jpeg,
        'image/gif' => Formats.gif,
        'image/webp' => Formats.webp,
        _ => Formats.png,
      };
      item.add(imageFormat.lazy(file.readAsBytes));
    }
    return item;
  }
}

class StashImageDragItemFactory {
  const StashImageDragItemFactory(this._repository);

  final AttachmentRepository _repository;

  Future<DragItem?> create(String attachmentId) =>
      StashAttachmentDragItemFactory(_repository)
          .create(attachmentId, includeImageData: true);
}

class StashImageDragSource extends StatelessWidget {
  const StashImageDragSource({
    super.key,
    required this.attachmentId,
    required this.repository,
    required this.child,
  });

  final String attachmentId;
  final AttachmentRepository repository;
  final Widget child;

  bool get _supportedDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Widget build(BuildContext context) {
    if (isFlutterTestEnvironment || !_supportedDesktop) return child;
    final factory = StashImageDragItemFactory(repository);
    return DragItemWidget(
      dragItemProvider: (_) => factory.create(attachmentId),
      allowedOperations: () => const [DropOperation.copy],
      child: DraggableWidget(
        child: Tooltip(
          message: 'Drag image to another app',
          child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
        ),
      ),
    );
  }
}

class StashFileDragSource extends StatelessWidget {
  const StashFileDragSource({
    super.key,
    required this.attachmentId,
    required this.repository,
    required this.child,
  });

  final String attachmentId;
  final AttachmentRepository repository;
  final Widget child;

  bool get _supportedDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  Widget build(BuildContext context) {
    if (isFlutterTestEnvironment || !_supportedDesktop) return child;
    final factory = StashAttachmentDragItemFactory(repository);
    return DragItemWidget(
      dragItemProvider: (_) => factory.create(attachmentId),
      allowedOperations: () => const [DropOperation.copy],
      child: DraggableWidget(
        child: Tooltip(
          message: 'Drag file to another app',
          child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
        ),
      ),
    );
  }
}
