import 'dart:async';

import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../data/image_import_sources.dart';
import 'drop_environment.dart';

typedef DroppedImagesCallback = Future<void> Function(
  List<ImportedImageData> images,
);
typedef DroppedTextCallback = FutureOr<void> Function(String text);

class ImageDropRegion extends StatefulWidget {
  const ImageDropRegion({
    super.key,
    required this.child,
    required this.onImagesDropped,
    this.onTextDropped,
    this.onError,
    this.label = 'Drop to stash',
  });

  final Widget child;
  final DroppedImagesCallback onImagesDropped;
  final DroppedTextCallback? onTextDropped;
  final VoidCallback? onError;
  final String label;

  @override
  State<ImageDropRegion> createState() => _ImageDropRegionState();
}

class _ImageDropRegionState extends State<ImageDropRegion> {
  static const _imageFormats = <FileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.gif,
    Formats.webp,
  ];
  static const _formats = <DataFormat>[..._imageFormats, Formats.plainText];

  bool _draggingOver = false;

  bool _containsImage(DropSession session) =>
      session.items.any((item) => _imageFormats.any(item.canProvide));

  bool _containsText(DropSession session) =>
      widget.onTextDropped != null &&
      session.items.any((item) => item.canProvide(Formats.plainText));

  DropOperation _onDropOver(DropOverEvent event) {
    final accepted =
        _containsImage(event.session) || _containsText(event.session);
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
    final pendingText = _readText(event);
    unawaited(_finishDrop(pendingImages, pendingText));
  }

  Future<void> _finishDrop(
    Future<List<ImportedImageData>> pendingImages,
    Future<List<String>> pendingText,
  ) async {
    try {
      final images = await pendingImages;
      if (images.isNotEmpty) {
        await widget.onImagesDropped(images);
        return;
      }
      final text = (await pendingText)
          .where((value) => value.isNotEmpty)
          .join('\n');
      if (text.isNotEmpty) await widget.onTextDropped?.call(text);
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
      final available = reader.getFormats(_imageFormats);
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

  Future<List<String>> _readText(PerformDropEvent event) {
    if (widget.onTextDropped == null) return Future.value(const []);
    final pending = <Future<String?>>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.plainText)) continue;
      final completer = Completer<String?>();
      final progress = reader.getValue<String>(
        Formats.plainText,
        (value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      );
      if (progress == null && !completer.isCompleted) {
        completer.complete(null);
      }
      pending.add(completer.future);
    }
    return Future.wait(pending)
        .then((values) => values.whereType<String>().toList());
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
                      const Icon(Icons.move_to_inbox_outlined),
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
