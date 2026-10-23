import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../items/data/item_document_codec.dart';
import '../domain/attachment.dart';
import '../domain/attachment_type.dart';

class AttachmentRepository {
  factory AttachmentRepository(
    AppDatabase db, {
    required Directory storageRoot,
  }) => AttachmentRepository._(db, storageRoot);

  AttachmentRepository._(this._db, this._storageRoot);

  final AppDatabase _db;
  final Directory _storageRoot;
  static final Uuid _uuid = Uuid();
  static const ItemDocumentCodec _documentCodec = ItemDocumentCodec();

  Future<Attachment> importImage({
    required String itemId,
    required Uint8List bytes,
    required String mimeType,
    String? originalFileName,
    String? id,
  }) async {
    if (bytes.isEmpty) throw ArgumentError('Image bytes must not be empty.');
    final normalizedName = _sanitizeOriginalFileName(originalFileName);
    if (!attachmentKindFor(mimeType, normalizedName).isImage) {
      throw ArgumentError.value(
        originalFileName,
        'originalFileName',
        'Unsupported image.',
      );
    }
    final extension = _managedExtension(normalizedName, mimeType: mimeType);
    return _importStream(
      itemId: itemId,
      stream: Stream.value(bytes),
      mimeType: mimeType,
      originalFileName: normalizedName,
      extension: extension,
      id: id,
    );
  }

  /// Copies a normal local file into profile-managed storage without loading
  /// the whole source file into memory. The external source is never moved.
  Future<Attachment> importFile({
    required String itemId,
    required File sourceFile,
    String? mimeType,
    String? originalFileName,
    String? id,
  }) async {
    if (!await sourceFile.exists()) {
      throw FileSystemException(
        'Attachment source does not exist.',
        sourceFile.path,
      );
    }
    final normalizedName = _sanitizeOriginalFileName(
      originalFileName ?? path.basename(sourceFile.path),
    );
    final resolvedMime = _resolvedMimeType(mimeType, normalizedName);
    return _importStream(
      itemId: itemId,
      stream: sourceFile.openRead(),
      mimeType: resolvedMime,
      originalFileName: normalizedName,
      extension: _managedExtension(normalizedName, mimeType: resolvedMime),
      id: id,
    );
  }

  /// Streams a native/virtual drag source into managed storage. Callers must
  /// supply a single-use stream and do not need to buffer it first.
  Future<Attachment> importFileStream({
    required String itemId,
    required Stream<List<int>> stream,
    String? mimeType,
    String? originalFileName,
    String? id,
  }) {
    final normalizedName = _sanitizeOriginalFileName(originalFileName);
    final resolvedMime = _resolvedMimeType(mimeType, normalizedName);
    return _importStream(
      itemId: itemId,
      stream: stream,
      mimeType: resolvedMime,
      originalFileName: normalizedName,
      extension: _managedExtension(normalizedName, mimeType: resolvedMime),
      id: id,
    );
  }

  Future<Attachment> _importStream({
    required String itemId,
    required Stream<List<int>> stream,
    required String mimeType,
    required String? originalFileName,
    required String extension,
    String? id,
  }) async {
    final attachmentId = id ?? _uuid.v4();
    final suffix = extension.isEmpty ? '' : '.$extension';
    final relativePath = path.join('attachments', '$attachmentId$suffix');
    final file = await _resolveRelativePath(relativePath);
    if (await file.exists()) {
      throw StateError('Managed attachment already exists: $attachmentId');
    }
    await file.parent.create(recursive: true);
    var copiedBytes = 0;
    IOSink? sink;
    try {
      sink = file.openWrite(mode: FileMode.writeOnly);
      await sink.addStream(
        stream.map((chunk) {
          copiedBytes += chunk.length;
          return chunk;
        }),
      );
      await sink.flush();
      await sink.close();
      sink = null;
      if (copiedBytes == 0) {
        throw ArgumentError('Attachment file must not be empty.');
      }

      final now = DateTime.now();
      await _db
          .into(_db.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: attachmentId,
              itemId: itemId,
              mimeType: mimeType,
              originalFileName: Value(originalFileName),
              relativePath: relativePath,
              byteSize: Value(copiedBytes),
              createdAt: now,
            ),
          );
      return Attachment(
        id: attachmentId,
        itemId: itemId,
        mimeType: mimeType,
        originalFileName: originalFileName,
        relativePath: relativePath,
        byteSize: copiedBytes,
        createdAt: now,
        deletedAt: null,
      );
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await file.exists()) await _deleteWithRetry(file);
      rethrow;
    }
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
      if (await _isReferencedByOwner(record)) continue;
      final file = await _resolveRelativePath(record.relativePath);
      await _deleteWithRetry(file);
      await (_db.delete(
        _db.attachments,
      )..where((row) => row.id.equals(id))).go();
    }
  }

  /// Hard-deletes only active, unreferenced staged metadata and blobs.
  ///
  /// Committed attachments removed by an Item edit are already tombstoned by
  /// `ItemRepository`, so they are excluded here and retained for future sync
  /// acknowledgement, conflict handling, and storage garbage collection.
  Future<void> cleanupUnreferencedAttachments({
    required String itemId,
    required Set<String> referencedAttachmentIds,
  }) async {
    final attachments = await getAttachmentsForItem(itemId);
    final unused = attachments
        .where((attachment) => !referencedAttachmentIds.contains(attachment.id))
        .map((attachment) => attachment.id);
    await cleanupStagedAttachments(unused);
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

  Future<bool> _isReferencedByOwner(AttachmentRecord attachment) async {
    final owner = await (_db.select(
      _db.items,
    )..where((row) => row.id.equals(attachment.itemId))).getSingleOrNull();
    if (owner?.documentJson == null) return false;
    final snapshot = _documentCodec.snapshot(
      _documentCodec.decode(
        documentJson: owner!.documentJson,
        legacyText: owner.content,
      ),
    );
    return snapshot.attachmentIds.contains(attachment.id);
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

  static String _resolvedMimeType(String? mimeType, String? fileName) {
    final normalized = mimeType?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty
        ? inferAttachmentMimeType(fileName)
        : normalized;
  }

  static String _managedExtension(
    String? fileName, {
    required String mimeType,
  }) {
    var extension = fileName == null
        ? ''
        : path.extension(fileName).toLowerCase();
    if (extension.isEmpty && mimeType.startsWith('image/')) {
      extension = switch (mimeType) {
        'image/jpeg' => '.jpg',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        _ => '.png',
      };
    }
    if (!RegExp(r'^\.[a-z0-9][a-z0-9._+-]{0,19}$').hasMatch(extension)) {
      return '';
    }
    return extension.substring(1);
  }

  static String? _sanitizeOriginalFileName(String? value) {
    if (value == null) return null;
    final leaf = path.posix.basename(value.replaceAll('\\', '/')).trim();
    if (leaf.isEmpty || leaf == '.' || leaf == '..') return null;
    final sanitized = leaf.replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_');
    return sanitized.length <= 255 ? sanitized : sanitized.substring(0, 255);
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
