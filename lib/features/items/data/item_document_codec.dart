import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';

const String stashImageEmbedType = 'stash-image';
const String stashFileEmbedType = 'stash-file';

class StashImageEmbed extends CustomBlockEmbed {
  const StashImageEmbed(String attachmentId)
    : super(stashImageEmbedType, attachmentId);

  String get attachmentId => data;
}

class StashFileEmbed extends CustomBlockEmbed {
  const StashFileEmbed(String attachmentId)
    : super(stashFileEmbedType, attachmentId);

  String get attachmentId => data;
}

class ItemDocumentSnapshot {
  const ItemDocumentSnapshot({
    required this.documentJson,
    required this.plainText,
    required this.imageAttachmentIds,
    required this.fileAttachmentIds,
  });

  final String documentJson;
  final String plainText;
  final Set<String> imageAttachmentIds;
  final Set<String> fileAttachmentIds;

  Set<String> get attachmentIds =>
      Set.unmodifiable({...imageAttachmentIds, ...fileAttachmentIds});

  bool get hasMeaningfulBody =>
      plainText.trim().isNotEmpty || attachmentIds.isNotEmpty;
}

/// The single adapter between Flutter Quill and Stash's persisted format.
class ItemDocumentCodec {
  const ItemDocumentCodec();

  static const int currentVersion = 1;
  static const String format = 'quill-delta';

  Document decode({required String? documentJson, required String legacyText}) {
    if (documentJson == null) return fromPlainText(legacyText);
    final envelope = jsonDecode(documentJson) as Map<String, dynamic>;
    if (envelope['version'] != currentVersion || envelope['format'] != format) {
      throw const FormatException('Unsupported Stash document format.');
    }
    final operations = envelope['document'];
    if (operations is! List) {
      throw const FormatException('Document payload must be a list.');
    }
    return Document.fromJson(operations);
  }

  Document fromPlainText(String text) {
    final normalized = text.endsWith('\n') ? text : '$text\n';
    return Document.fromJson([
      {'insert': normalized},
    ]);
  }

  ItemDocumentSnapshot snapshot(Document document) {
    final operations = document.toDelta().toJson();
    final imageIds = <String>{};
    final fileIds = <String>{};
    for (final operation in operations) {
      final insert = operation['insert'];
      if (insert is Map) {
        final customJson = insert['custom'];
        if (customJson is! String) continue;
        final custom = CustomBlockEmbed.fromJsonString(customJson);
        if (custom.type == stashImageEmbedType) {
          imageIds.add(custom.data);
        } else if (custom.type == stashFileEmbedType) {
          fileIds.add(custom.data);
        }
      }
    }
    final plainTextBuffer = StringBuffer();
    for (final operation in operations) {
      final insert = operation['insert'];
      if (insert is String) plainTextBuffer.write(insert);
    }
    var plainText = plainTextBuffer.toString();
    if (plainText.endsWith('\n')) {
      plainText = plainText.substring(0, plainText.length - 1);
    }
    return ItemDocumentSnapshot(
      documentJson: jsonEncode({
        'version': currentVersion,
        'format': format,
        'document': operations,
      }),
      plainText: plainText,
      imageAttachmentIds: Set.unmodifiable(imageIds),
      fileAttachmentIds: Set.unmodifiable(fileIds),
    );
  }
}
