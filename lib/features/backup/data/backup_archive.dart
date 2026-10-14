import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;

import '../domain/backup_exception.dart';
import '../domain/backup_manifest.dart';

abstract interface class BackupArchiveCodec {
  Future<void> create({
    required Directory sourceDirectory,
    required BackupManifest manifest,
    required File outputFile,
  });

  Future<void> extract({
    required File archiveFile,
    required Directory destination,
  });
}

class ZipBackupArchiveCodec implements BackupArchiveCodec {
  const ZipBackupArchiveCodec();

  @override
  Future<void> create({
    required Directory sourceDirectory,
    required BackupManifest manifest,
    required File outputFile,
  }) async {
    await outputFile.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      encoder.create(outputFile.path, level: ZipFileEncoder.gzip);
      opened = true;
      await encoder.addFile(
        File(path.join(sourceDirectory.path, 'manifest.json')),
        'manifest.json',
      );
      await encoder.addFile(
        File(path.join(sourceDirectory.path, 'database', 'stash.sqlite')),
        'database/stash.sqlite',
      );
      for (final entry in manifest.files) {
        await encoder.addFile(
          File(_resolveInside(sourceDirectory, entry.path).path),
          entry.path,
        );
      }
      await encoder.close();
      opened = false;
    } catch (_) {
      if (opened) {
        try {
          await encoder.close();
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<void> extract({
    required File archiveFile,
    required Directory destination,
  }) async {
    await destination.create(recursive: true);
    final input = InputFileStream(archiveFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final seen = <String>{};
      for (final entry in archive.files) {
        final safeName = normalizeArchivePath(entry.name);
        if (!seen.add(safeName)) {
          throw BackupException(
            BackupFailure.corrupted,
            'Duplicate archive entry: $safeName',
          );
        }
        if (entry.isSymbolicLink) {
          throw BackupException(
            BackupFailure.invalidPath,
            'Archive symbolic links are not allowed: $safeName',
          );
        }
        final target = _resolveInside(destination, safeName);
        if (entry.isDirectory) {
          await Directory(target.path).create(recursive: true);
          continue;
        }
        await target.parent.create(recursive: true);
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
    } on BackupException {
      rethrow;
    } catch (error) {
      throw BackupException(
        BackupFailure.corrupted,
        'The backup archive could not be read.',
        error,
      );
    } finally {
      await input.close();
    }
  }
}

String normalizeArchivePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      path.posix.isAbsolute(value) ||
      path.windows.isAbsolute(value) ||
      RegExp(r'^[a-zA-Z]:').hasMatch(value)) {
    throw BackupException(
      BackupFailure.invalidPath,
      'Unsafe archive path: $value',
    );
  }
  final normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  final segments = normalized.split('/');
  if (normalized == '.' ||
      normalized.startsWith('../') ||
      segments.any((segment) => segment.isEmpty || segment == '..')) {
    throw BackupException(
      BackupFailure.invalidPath,
      'Unsafe archive path: $value',
    );
  }
  return normalized;
}

File _resolveInside(Directory root, String relativePath) {
  final safePath = normalizeArchivePath(relativePath);
  final resolved = path.normalize(
    path.joinAll([root.path, ...safePath.split('/')]),
  );
  if (!path.isWithin(root.path, resolved)) {
    throw BackupException(
      BackupFailure.invalidPath,
      'Archive path escapes staging: $relativePath',
    );
  }
  return File(resolved);
}
