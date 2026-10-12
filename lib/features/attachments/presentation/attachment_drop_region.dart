import 'dart:async';

import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../data/file_attachment_ingestor.dart';
import '../data/image_import_sources.dart';
import '../domain/attachment_type.dart';
import 'drop_environment.dart';

typedef DroppedImagesCallback = Future<void> Function(
  List<ImportedImageData> images,
);
typedef DroppedFilesCallback = Future<void> Function(
  List<ImportedFileData> files,
);
typedef DroppedTextCallback = FutureOr<void> Function(String text);

class AttachmentDropRegion extends StatefulWidget {
  const AttachmentDropRegion({
    super.key,
    required this.child,
    required this.onImagesDropped,
    required this.onFilesDropped,
    this.onTextDropped,
    this.onError,
    this.label = 'Drop to stash',
  });

  final Widget child;
  final DroppedImagesCallback onImagesDropped;
  final DroppedFilesCallback onFilesDropped;
  final DroppedTextCallback? onTextDropped;
  final VoidCallback? onError;
  final String label;

  @override
  State<AttachmentDropRegion> createState() => _AttachmentDropRegionState();
}

class _AttachmentDropRegionState extends State<AttachmentDropRegion> {
  static const _imageFormats = <FileFormat>[
    Formats.png,
    Formats.jpeg,
    Formats.gif,
    Formats.webp,
  ];
  static const _genericFileFormats = <FileFormat>[
    Formats.pdf,
    Formats.doc,
    Formats.docx,
    Formats.ppt,
    Formats.pptx,
    Formats.xls,
    Formats.xlsx,
    Formats.plainTextFile,
    Formats.md,
    Formats.csv,
    Formats.json,
    Formats.zip,
    Formats.rar,
    Formats.sevenZip,
    Formats.tar,
    Formats.gzip,
    Formats.bzip2,
    Formats.xz,
    Formats.webUnknown,
  ];
  static const _formats = <DataFormat>[
    ..._imageFormats,
    ..._genericFileFormats,
    Formats.fileUri,
    Formats.plainText,
  ];

  bool _draggingOver = false;

  bool _containsImage(DropSession session) =>
      session.items.any((item) => _imageFormats.any(item.canProvide));

  bool _containsFile(DropSession session) => session.items.any((item) {
    if (_imageFormats.any(item.canProvide)) return false;
    return item.canProvide(Formats.fileUri) ||
        _genericFileFormats.any(item.canProvide);
  });

  bool _containsText(DropSession session) =>
      widget.onTextDropped != null &&
      session.items.any((item) => item.canProvide(Formats.plainText));

  DropOperation _onDropOver(DropOverEvent event) {
    final accepted =
        _containsImage(event.session) ||
        _containsFile(event.session) ||
        _containsText(event.session);
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
    final pendingFiles = _readFiles(event);
    final pendingText = _readText(event);
    unawaited(_finishDrop(pendingImages, pendingFiles, pendingText));
  }

  Future<void> _finishDrop(
    Future<List<ImportedImageData>> pendingImages,
    Future<List<ImportedFileData>> pendingFiles,
    Future<List<String>> pendingText,
  ) async {
    try {
      final images = await pendingImages;
      final files = await pendingFiles;
      if (images.isNotEmpty) await widget.onImagesDropped(images);
      if (files.isNotEmpty) await widget.onFilesDropped(files);
      if (images.isNotEmpty || files.isNotEmpty) return;
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

  Future<List<ImportedFileData>> _readFiles(PerformDropEvent event) {
    final pending = <Future<ImportedFileData?>>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || _imageFormats.any(reader.canProvide)) continue;
      final knownFormats = reader.getFormats(_genericFileFormats);
      if (knownFormats.isEmpty && !reader.canProvide(Formats.fileUri)) continue;
      final format = knownFormats.isEmpty
          ? null
          : knownFormats.first as FileFormat;
      final completer = Completer<ImportedFileData?>();
      final progress = reader.getFile(format, (file) async {
        try {
          final fileName = file.fileName ?? await reader.getSuggestedName();
          completer.complete(
            ImportedFileData.stream(
              file.getStream(),
              mimeType: format == null
                  ? inferAttachmentMimeType(fileName)
                  : _mimeType(format, fileName: fileName),
              fileName: fileName,
              onDiscard: file.close,
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
        .then((files) => files.whereType<ImportedFileData>().toList());
  }

  Future<List<String>> _readText(PerformDropEvent event) {
    if (widget.onTextDropped == null) return Future.value(const []);
    final pending = <Future<String?>>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null ||
          _imageFormats.any(reader.canProvide) ||
          reader.canProvide(Formats.fileUri) ||
          _genericFileFormats.any(reader.canProvide) ||
          !reader.canProvide(Formats.plainText)) {
        continue;
      }
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

  static String _mimeType(FileFormat format, {String? fileName}) {
    if (identical(format, Formats.jpeg)) return 'image/jpeg';
    if (identical(format, Formats.gif)) return 'image/gif';
    if (identical(format, Formats.webp)) return 'image/webp';
    if (identical(format, Formats.png)) return 'image/png';
    if (identical(format, Formats.pdf)) return 'application/pdf';
    if (identical(format, Formats.doc)) return 'application/msword';
    if (identical(format, Formats.docx)) {
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    }
    if (identical(format, Formats.ppt)) return 'application/vnd.ms-powerpoint';
    if (identical(format, Formats.pptx)) {
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    }
    if (identical(format, Formats.xls)) return 'application/vnd.ms-excel';
    if (identical(format, Formats.xlsx)) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (identical(format, Formats.csv)) return 'text/csv';
    if (identical(format, Formats.json)) return 'application/json';
    if (identical(format, Formats.zip)) return 'application/zip';
    if (identical(format, Formats.rar)) return 'application/vnd.rar';
    if (identical(format, Formats.sevenZip)) {
      return 'application/x-7z-compressed';
    }
    return inferAttachmentMimeType(fileName);
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
                key: const Key('attachment-drop-overlay'),
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
