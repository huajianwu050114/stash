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
}
