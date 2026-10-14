import 'dart:convert';

class BackupFileEntry {
  const BackupFileEntry({
    required this.path,
    required this.size,
    required this.sha256,
  });

  factory BackupFileEntry.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    final size = json['size'];
    final checksum = json['sha256'];
    if (path is! String || size is! int || checksum is! String) {
      throw const FormatException('Invalid backup file entry.');
    }
    return BackupFileEntry(path: path, size: size, sha256: checksum);
  }

  final String path;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
  };
}

class BackupManifest {
  const BackupManifest({
    required this.format,
    required this.formatVersion,
    required this.createdAtUtc,
    required this.appVersion,
    required this.databaseSchemaVersion,
    required this.sourceProfile,
    required this.itemCount,
    required this.channelCount,
    required this.attachmentCount,
    required this.databaseSha256,
    required this.files,
  });

  static const formatName = 'stash-backup';
  static const currentFormatVersion = 1;

  factory BackupManifest.fromJson(Map<String, Object?> json) {
    T require<T>(String key) {
      final value = json[key];
      if (value is! T) throw FormatException('Invalid manifest field: $key');
      return value;
    }

    final rawFiles = require<List<Object?>>('files');
    return BackupManifest(
      format: require<String>('format'),
      formatVersion: require<int>('formatVersion'),
      createdAtUtc: DateTime.parse(require<String>('createdAtUtc')).toUtc(),
      appVersion: require<String>('appVersion'),
      databaseSchemaVersion: require<int>('databaseSchemaVersion'),
      sourceProfile: require<String>('sourceProfile'),
      itemCount: require<int>('itemCount'),
      channelCount: require<int>('channelCount'),
      attachmentCount: require<int>('attachmentCount'),
      databaseSha256: require<String>('databaseSha256'),
      files: rawFiles
          .map(
            (entry) => BackupFileEntry.fromJson(
              (entry as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  factory BackupManifest.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('Backup manifest must be an object.');
    }
    return BackupManifest.fromJson(decoded.cast<String, Object?>());
  }

  final String format;
  final int formatVersion;
  final DateTime createdAtUtc;
  final String appVersion;
  final int databaseSchemaVersion;
  final String sourceProfile;
  final int itemCount;
  final int channelCount;
  final int attachmentCount;
  final String databaseSha256;
  final List<BackupFileEntry> files;

  Map<String, Object?> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'appVersion': appVersion,
    'databaseSchemaVersion': databaseSchemaVersion,
    'sourceProfile': sourceProfile,
    'itemCount': itemCount,
    'channelCount': channelCount,
    'attachmentCount': attachmentCount,
    'databaseSha256': databaseSha256,
    'files': files.map((entry) => entry.toJson()).toList(growable: false),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class BackupSummary {
  const BackupSummary({
    required this.manifest,
    required this.archivePath,
    required this.archiveSize,
  });

  final BackupManifest manifest;
  final String archivePath;
  final int archiveSize;
}
