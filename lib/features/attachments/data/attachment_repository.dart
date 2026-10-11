import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/attachment.dart';

class AttachmentRepository {
  factory AttachmentRepository(
    AppDatabase db, {
    required Directory storageRoot,
  }) => AttachmentRepository._(db, storageRoot);

  AttachmentRepository._(this._db, this._storageRoot);

  final AppDatabase _db;
  final Directory _storageRoot;
  static final Uuid _uuid = Uuid();

  Future<Attachment> importImage({
    required String itemId,
    required Uint8List bytes,
    required String mimeType,
    String? originalFileName,
    String? id,
  }) async {
    if (bytes.isEmpty) throw ArgumentError('Image bytes must not be empty.');
    final extension = _extensionFor(mimeType, originalFileName);
    final attachmentId = id ?? _uuid.v4();
    final relativePath = path.join('attachments', '$attachmentId.$extension');
    final file = await _resolveRelativePath(relativePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    final now = DateTime.now();
    try {
      await _db
          .into(_db.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: attachmentId,
              itemId: itemId,
              mimeType: mimeType,
              originalFileName: Value(originalFileName),
              relativePath: relativePath,
              byteSize: Value(bytes.length),
              createdAt: now,
            ),
          );
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return Attachment(
      id: attachmentId,
      itemId: itemId,
      mimeType: mimeType,
      originalFileName: originalFileName,
      relativePath: relativePath,
      byteSize: bytes.length,
      createdAt: now,
      deletedAt: null,
    );
  }

  Future<Attachment?> getAttachmentById(String id) async => (await (_db.select(
    _db.attachments,
  )..where((row) => row.id.equals(id))).getSingleOrNull())?.toAttachment();

  Future<List<Attachment>> getAttachmentsForItem(String itemId) async {
    final rows =
        await (_db.select(_db.attachments)
              ..where(
                (row) => row.itemId.equals(itemId) & row.deletedAt.isNull(),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
            .get();
    return rows.map((row) => row.toAttachment()).toList();
  }

  Future<File?> resolveAttachmentFile(String attachmentId) async {
    final attachment = await getAttachmentById(attachmentId);
    if (attachment == null || attachment.isDeleted) return null;
    final file = await _resolveRelativePath(attachment.relativePath);
    return await file.exists() ? file : null;
  }

  /// Removes only explicitly staged imports, never an Item's full attachment
  /// directory. Callers track IDs imported during the current editor session.
  Future<void> cleanupStagedAttachments(Iterable<String> attachmentIds) async {
    for (final id in attachmentIds.toSet()) {
      final record = await (_db.select(
        _db.attachments,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (record == null) continue;
      final file = await _resolveRelativePath(record.relativePath);
      await _deleteWithRetry(file);
      await (_db.delete(
        _db.attachments,
      )..where((row) => row.id.equals(id))).go();
    }
  }

  /// Best-effort cleanup for interrupted new editors. Existing and tombstoned
  /// Items both count as owners, so their files are never removed here.
  Future<int> cleanupOrphans({required DateTime olderThan}) async {
    final records = await (_db.select(
      _db.attachments,
    )..where((row) => row.createdAt.isSmallerThanValue(olderThan))).get();
    var removed = 0;
    for (final record in records) {
      final owner = await (_db.select(
        _db.items,
      )..where((row) => row.id.equals(record.itemId))).getSingleOrNull();
      if (owner != null) continue;
      await cleanupStagedAttachments([record.id]);
      removed++;
    }
    return removed;
  }

  Future<File> _resolveRelativePath(String relativePath) async {
    if (path.isAbsolute(relativePath)) {
      throw StateError('Attachment paths must be relative.');
    }
    final root = _storageRoot;
    final resolved = path.normalize(path.join(root.path, relativePath));
    if (!path.isWithin(root.path, resolved)) {
      throw StateError('Attachment path escapes managed storage.');
    }
    return File(resolved);
  }

  Future<void> _deleteWithRetry(File file) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!await file.exists()) return;
      try {
        await file.delete();
        return;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  static String _extensionFor(String mimeType, String? originalFileName) {
    return switch (mimeType.toLowerCase()) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => _extensionFromName(originalFileName),
    };
  }

  static String _extensionFromName(String? name) {
    final extension = name == null ? '' : path.extension(name).toLowerCase();
    if (const {'.png', '.jpg', '.jpeg', '.gif', '.webp'}.contains(extension)) {
      return extension == '.jpeg' ? 'jpg' : extension.substring(1);
    }
    throw ArgumentError.value(name, 'originalFileName', 'Unsupported image.');
  }
}

extension on AttachmentRecord {
  Attachment toAttachment() => Attachment(
    id: id,
    itemId: itemId,
    mimeType: mimeType,
    originalFileName: originalFileName,
    relativePath: relativePath,
    byteSize: byteSize,
    createdAt: createdAt,
    deletedAt: deletedAt,
  );
}
