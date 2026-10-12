import 'package:path/path.dart' as path;

import 'attachment_type.dart';

class Attachment {
  const Attachment({
    required this.id,
    required this.itemId,
    required this.mimeType,
    required this.originalFileName,
    required this.relativePath,
    required this.byteSize,
    required this.createdAt,
    required this.deletedAt,
  });

  final String id;
  final String itemId;
  final String mimeType;
  final String? originalFileName;
  final String relativePath;
  final int? byteSize;
  final DateTime createdAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  bool get isImage => attachmentKindFor(mimeType, originalFileName).isImage;

  AttachmentKind get kind => attachmentKindFor(mimeType, originalFileName);

  String get displayName {
    final name = originalFileName?.trim();
    return name == null || name.isEmpty ? 'File' : name;
  }

  String get extension {
    final value = path.extension(displayName);
    return value.isEmpty ? '' : value.substring(1).toUpperCase();
  }
}
