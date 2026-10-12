import 'dart:io';

import '../domain/attachment.dart';
import 'attachment_repository.dart';

class ImportedFileData {
  const ImportedFileData._({
    required this.file,
    required this.stream,
    required this.mimeType,
    required this.fileName,
    required this.onDiscard,
  });

  factory ImportedFileData.localFile(
    File file, {
    String? mimeType,
    String? fileName,
  }) => ImportedFileData._(
    file: file,
    stream: null,
    mimeType: mimeType,
    fileName: fileName,
    onDiscard: null,
  );

  factory ImportedFileData.stream(
    Stream<List<int>> stream, {
    String? mimeType,
    String? fileName,
    void Function()? onDiscard,
  }) => ImportedFileData._(
    file: null,
    stream: stream,
    mimeType: mimeType,
    fileName: fileName,
    onDiscard: onDiscard,
  );

  final File? file;
  final Stream<List<int>>? stream;
  final String? mimeType;
  final String? fileName;
  final void Function()? onDiscard;

  void discard() => onDiscard?.call();
}

/// Imports a batch as one staged unit: if any source fails, every attachment
/// already copied by this batch is removed from managed storage and metadata.
class FileAttachmentIngestor {
  const FileAttachmentIngestor(this._attachments);

  final AttachmentRepository _attachments;

  Future<List<Attachment>> importFiles({
    required String itemId,
    required Iterable<ImportedFileData> files,
  }) async {
    final sources = files.toList(growable: false);
    final imported = <Attachment>[];
    try {
      for (final source in sources) {
        final localFile = source.file;
        final attachment = localFile != null
            ? await _attachments.importFile(
                itemId: itemId,
                sourceFile: localFile,
                mimeType: source.mimeType,
                originalFileName: source.fileName,
              )
            : await _attachments.importFileStream(
                itemId: itemId,
                stream: source.stream!,
                mimeType: source.mimeType,
                originalFileName: source.fileName,
              );
        imported.add(attachment);
      }
      return imported;
    } catch (_) {
      for (final source in sources) {
        source.discard();
      }
      await _attachments.cleanupStagedAttachments(
        imported.map((attachment) => attachment.id),
      );
      rethrow;
    }
  }
}
