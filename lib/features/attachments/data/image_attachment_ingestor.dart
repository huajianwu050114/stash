import '../domain/attachment.dart';
import 'attachment_repository.dart';
import 'image_import_sources.dart';

/// Shared boundary for every editor path that turns external image bytes into
/// managed Stash attachments. A failed batch does not leave partial imports.
class ImageAttachmentIngestor {
  const ImageAttachmentIngestor(this._attachments);

  final AttachmentRepository _attachments;

  Future<List<Attachment>> importImages({
    required String itemId,
    required Iterable<ImportedImageData> images,
  }) async {
    final imported = <Attachment>[];
    try {
      for (final image in images) {
        imported.add(
          await _attachments.importImage(
            itemId: itemId,
            bytes: image.bytes,
            mimeType: image.mimeType,
            originalFileName: image.fileName,
          ),
        );
      }
      return imported;
    } catch (_) {
      await _attachments.cleanupStagedAttachments(
        imported.map((attachment) => attachment.id),
      );
      rethrow;
    }
  }
}
