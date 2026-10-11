import 'dart:async';

import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../data/image_import_sources.dart';
import 'drop_environment.dart';

typedef DroppedImagesCallback = Future<void> Function(
  List<ImportedImageData> images,
);

class ImageDropRegion extends StatefulWidget {
  const ImageDropRegion({
    super.key,
    required this.child,
    required this.onImagesDropped,
    this.onError,
    this.label = 'Drop to stash',
  });

  final Widget child;
  final DroppedImagesCallback onImagesDropped;
  final VoidCallback? onError;
  final String label;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  static const _formats = <FileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.gif,
    Formats.webp,
  ];

  bool _draggingOver = false;

  bool _containsImage(DropSession session) =>
      session.items.any((item) => _formats.any(item.canProvide));

  DropOperation _onDropOver(DropOverEvent event) {
    final accepted = _containsImage(event.session);
    if (_draggingOver != accepted && mounted) {
      setState(() => _draggingOver = accepted);
    }
    if (!accepted ||
        !event.session.allowedOperations.contains(DropOperation.copy)) {
      return DropOperation.none;
    }
    return DropOperation.copy;
  }

  Future<void> _onPerformDrop(PerformDropEvent event) async {
    final pendingImages = _readImages(event);
    unawaited(_finishDrop(pendingImages));
  }

  Future<void> _finishDrop(Future<List<ImportedImageData>> pending) async {
    try {
      final images = await pending;
      if (images.isEmpty) return;
      await widget.onImagesDropped(images);
    } catch (_) {
      widget.onError?.call();
    } finally {
      if (mounted) setState(() => _draggingOver = false);
    }
  }

  Future<List<ImportedImageData>> _readImages(PerformDropEvent event) {
    final pending = <Future<ImportedImageData?>>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      final available = reader.getFormats(_formats);
      if (available.isEmpty) continue;
      final format = available.first as FileFormat;
      final completer = Completer<ImportedImageData?>();
      final progress = reader.getFile(format, (file) async {
        try {
          completer.complete(
            ImportedImageData(
              bytes: await file.readAll(),
              mimeType: _mimeType(format),
              fileName: file.fileName ?? await reader.getSuggestedName(),
            ),
          );
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      }, onError: (error) => completer.completeError(error));
      if (progress == null) completer.complete(null);
      pending.add(completer.future);
    }
    return Future.wait(pending)
        .then((images) => images.whereType<ImportedImageData>().toList());
  }

  static String _mimeType(FileFormat format) {
    if (identical(format, Formats.jpeg)) return 'image/jpeg';
    if (identical(format, Formats.gif)) return 'image/gif';
    if (identical(format, Formats.webp)) return 'image/webp';
    return 'image/png';
  }

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_draggingOver)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                key: const Key('image-drop-overlay'),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer
                      .withValues(alpha: 0.88),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_photo_alternate_outlined),
                      const SizedBox(width: 8),
                      Text(
                        widget.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    // The native drop engine is unavailable in flutter_tester. Data ingestion
    // remains covered independently while editor widget tests keep real UI.
    if (isFlutterTestEnvironment) return content;
    return DropRegion(
      formats: _formats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: _onDropOver,
      onDropEnter: (_) {
        if (mounted) setState(() => _draggingOver = true);
      },
      onDropLeave: (_) {
        if (mounted) setState(() => _draggingOver = false);
      },
      onPerformDrop: _onPerformDrop,
      child: content,
    );
  }
}
