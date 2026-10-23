typedef JsonMap = Map<String, Object?>;

abstract final class _PayloadCodec {
  static String string(JsonMap json, String key) {
    final value = json[key];
    if (value is! String) throw FormatException('$key must be a string.');
    return value;
  }

  static String? nullableString(JsonMap json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('$key must be a string or null.');
    }
    return value;
  }

  static int integer(JsonMap json, String key) {
    final value = json[key];
    if (value is! int) throw FormatException('$key must be an integer.');
    return value;
  }

  static bool boolean(JsonMap json, String key) {
    final value = json[key];
    if (value is! bool) throw FormatException('$key must be a boolean.');
    return value;
  }

  static DateTime dateTime(JsonMap json, String key) =>
      DateTime.parse(string(json, key)).toUtc();

  static DateTime? nullableDateTime(JsonMap json, String key) {
    final value = nullableString(json, key);
    return value == null ? null : DateTime.parse(value).toUtc();
  }

  static List<String> strings(JsonMap json, String key) {
    final value = json[key];
    if (value is! List || value.any((entry) => entry is! String)) {
      throw FormatException('$key must be a string list.');
    }
    return List.unmodifiable(value.cast<String>());
  }

  static String timestamp(DateTime value) => value.toUtc().toIso8601String();
}

class ItemSyncPayload {
  ItemSyncPayload({
    required this.id,
    required this.title,
    required this.content,
    required this.note,
    required this.channelId,
    required this.documentJson,
    required List<String> tags,
    required this.isPinned,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.serverRevision,
  }) : tags = List.unmodifiable(tags);

  final String id;
  final String? title;
  final String content;
  final String? note;
  final String? channelId;
  final String? documentJson;
  final List<String> tags;
  final bool isPinned;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  /// Optimistic-concurrency metadata, separate from user-authored content.
  final int serverRevision;

  JsonMap toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'note': note,
    'channelId': channelId,
    'documentJson': documentJson,
    'tags': tags,
    'isPinned': isPinned,
    'createdAt': _PayloadCodec.timestamp(createdAt),
    'updatedAt': _PayloadCodec.timestamp(updatedAt),
    'deletedAt': deletedAt == null ? null : _PayloadCodec.timestamp(deletedAt!),
    'serverRevision': serverRevision,
  };

  factory ItemSyncPayload.fromJson(JsonMap json) => ItemSyncPayload(
    id: _PayloadCodec.string(json, 'id'),
    title: _PayloadCodec.nullableString(json, 'title'),
    content: _PayloadCodec.string(json, 'content'),
    note: _PayloadCodec.nullableString(json, 'note'),
    channelId: _PayloadCodec.nullableString(json, 'channelId'),
    documentJson: _PayloadCodec.nullableString(json, 'documentJson'),
    tags: _PayloadCodec.strings(json, 'tags'),
    isPinned: _PayloadCodec.boolean(json, 'isPinned'),
    createdAt: _PayloadCodec.dateTime(json, 'createdAt'),
    updatedAt: _PayloadCodec.dateTime(json, 'updatedAt'),
    deletedAt: _PayloadCodec.nullableDateTime(json, 'deletedAt'),
    serverRevision: _PayloadCodec.integer(json, 'serverRevision'),
  );
}

class ChannelSyncPayload {
  const ChannelSyncPayload({
    required this.id,
    required this.name,
    required this.parentId,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.serverRevision,
  });

  final String id;
  final String name;
  final String? parentId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final int serverRevision;

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'createdAt': _PayloadCodec.timestamp(createdAt),
    'updatedAt': _PayloadCodec.timestamp(updatedAt),
    'deletedAt': deletedAt == null ? null : _PayloadCodec.timestamp(deletedAt!),
    'serverRevision': serverRevision,
  };

  factory ChannelSyncPayload.fromJson(JsonMap json) => ChannelSyncPayload(
    id: _PayloadCodec.string(json, 'id'),
    name: _PayloadCodec.string(json, 'name'),
    parentId: _PayloadCodec.nullableString(json, 'parentId'),
    createdAt: _PayloadCodec.dateTime(json, 'createdAt'),
    updatedAt: _PayloadCodec.dateTime(json, 'updatedAt'),
    deletedAt: _PayloadCodec.nullableDateTime(json, 'deletedAt'),
    serverRevision: _PayloadCodec.integer(json, 'serverRevision'),
  );
}

/// Portable attachment metadata only. Device paths and blob bytes are absent.
class AttachmentSyncPayload {
  const AttachmentSyncPayload({
    required this.id,
    required this.itemId,
    required this.mimeType,
    required this.originalFileName,
    required this.byteSize,
    required this.sha256,
    required this.createdAt,
    required this.deletedAt,
    required this.serverRevision,
  });

  final String id;
  final String itemId;
  final String mimeType;
  final String? originalFileName;
  final int? byteSize;
  final String? sha256;
  final DateTime createdAt;
  final DateTime? deletedAt;
  final int serverRevision;

  JsonMap toJson() => {
    'id': id,
    'itemId': itemId,
    'mimeType': mimeType,
    'originalFileName': originalFileName,
    'byteSize': byteSize,
    'sha256': sha256,
    'createdAt': _PayloadCodec.timestamp(createdAt),
    'deletedAt': deletedAt == null ? null : _PayloadCodec.timestamp(deletedAt!),
    'serverRevision': serverRevision,
  };

  factory AttachmentSyncPayload.fromJson(JsonMap json) => AttachmentSyncPayload(
    id: _PayloadCodec.string(json, 'id'),
    itemId: _PayloadCodec.string(json, 'itemId'),
    mimeType: _PayloadCodec.string(json, 'mimeType'),
    originalFileName: _PayloadCodec.nullableString(json, 'originalFileName'),
    byteSize: json['byteSize'] == null
        ? null
        : _PayloadCodec.integer(json, 'byteSize'),
    sha256: _PayloadCodec.nullableString(json, 'sha256'),
    createdAt: _PayloadCodec.dateTime(json, 'createdAt'),
    deletedAt: _PayloadCodec.nullableDateTime(json, 'deletedAt'),
    serverRevision: _PayloadCodec.integer(json, 'serverRevision'),
  );
}
