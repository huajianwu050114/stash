import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';
import 'package:stash/app/app_profile.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/core/storage/app_storage_paths.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/backup/data/backup_archive.dart';
import 'package:stash/features/backup/data/backup_service.dart';
import 'package:stash/features/backup/data/backup_validator.dart';
import 'package:stash/features/backup/data/pending_restore_store.dart';
import 'package:stash/features/backup/data/pre_migration_backup.dart';
import 'package:stash/features/backup/data/restore_coordinator.dart';
import 'package:stash/features/backup/data/startup_restore_applier.dart';
import 'package:stash/features/backup/domain/backup_exception.dart';
import 'package:stash/features/backup/domain/backup_manifest.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/platform/backup/backup_platform.dart';

void main() {
  group('backup creation and validation', () {
    late _Fixture fixture;

    setUp(() async => fixture = await _Fixture.create());
    tearDown(() => fixture.dispose());

    test('empty Dev profile produces a valid standalone archive', () async {
      final stableMarker = await fixture.createStableMarker();
      await fixture.storage.lanIdentityDirectory.create(recursive: true);
      await File(
        path.join(fixture.storage.lanIdentityDirectory.path, 'pairing-secret'),
      ).writeAsString('test-only-secret-that-must-not-enter-backup');
      await fixture.storage.lanRelayDatabaseFile.writeAsBytes([1, 2, 3]);
      final output = File(path.join(fixture.support.path, 'empty.stashbackup'));

      final summary = await fixture.backupService.createBackup(
        destinationFile: output,
      );
      final extraction = Directory(path.join(fixture.support.path, 'check'));
      final validated = await fixture.validator.validateArchive(
        archiveFile: output,
        extractionDirectory: extraction,
      );

      expect(summary.manifest.format, BackupManifest.formatName);
      expect(summary.manifest.formatVersion, 1);
      expect(summary.manifest.sourceProfile, 'dev');
      expect(
        summary.manifest.databaseSchemaVersion,
        AppDatabase.currentSchemaVersion,
      );
      expect(summary.manifest.itemCount, 0);
      expect(summary.manifest.channelCount, 0);
      expect(summary.manifest.attachmentCount, 0);
      expect(validated.manifest.databaseSha256, hasLength(64));
      expect(await stableMarker.readAsString(), 'stable-untouched');
      expect(
        await File(path.join(extraction.path, 'marker.txt')).exists(),
        isFalse,
      );
      expect(
        await Directory(path.join(extraction.path, 'sync')).exists(),
        isFalse,
      );
      final snapshot = sqlite3.open(
        path.join(extraction.path, 'database', 'stash.sqlite'),
        mode: OpenMode.readOnly,
      );
      try {
        expect(
          snapshot.select('PRAGMA integrity_check').first.values.first,
          'ok',
        );
      } finally {
        snapshot.close();
      }
    });

    test('mixed Items, hierarchy, duplicate names, unknown files, and large files round-trip', () async {
      final seeded = await fixture.seedMixedContent();
      final output = File(path.join(fixture.support.path, 'mixed.stashbackup'));

      final summary = await fixture.backupService.createBackup(
        destinationFile: output,
      );
      final extraction = Directory(
        path.join(fixture.support.path, 'mixed-out'),
      );
      final validated = await fixture.validator.validateArchive(
        archiveFile: output,
        extractionDirectory: extraction,
      );

      expect(summary.manifest.itemCount, 1);
      expect(summary.manifest.channelCount, 2);
      expect(summary.manifest.attachmentCount, seeded.attachmentIds.length);
      expect(validated.manifest.files, hasLength(seeded.attachmentIds.length));
      expect(
        validated.manifest.files.map((entry) => entry.sha256),
        everyElement(matches(RegExp(r'^[0-9a-f]{64}$'))),
      );
      expect(
        validated.manifest.files.any((entry) => entry.size >= 2 * 1024 * 1024),
        isTrue,
      );
      final snapshot = sqlite3.open(
        path.join(extraction.path, 'database', 'stash.sqlite'),
        mode: OpenMode.readOnly,
      );
      try {
        final item = snapshot.select(
          'SELECT document_json FROM items WHERE id = ?',
          ['mixed-item'],
        ).single;
        final document = item['document_json'] as String;
        for (final id in seeded.attachmentIds) {
          expect(document, contains(id));
        }
        final duplicateNames = snapshot.select(
          "SELECT original_file_name FROM attachments "
          "WHERE original_file_name = 'report.pdf'",
        );
        expect(duplicateNames, hasLength(2));
      } finally {
        snapshot.close();
      }
    });

    test(
      'missing referenced attachment fails without a successful output',
      () async {
        final seeded = await fixture.seedMixedContent(minimal: true);
        final attachment = await fixture.attachments.getAttachmentById(
          seeded.attachmentIds.first,
        );
        await File(
          path.join(fixture.storage.root.path, attachment!.relativePath),
        ).delete();
        final output = File(
          path.join(fixture.support.path, 'missing.stashbackup'),
        );

        await expectLater(
          fixture.backupService.createBackup(destinationFile: output),
          throwsA(
            isA<BackupException>().having(
              (error) => error.failure,
              'failure',
              BackupFailure.missingAttachment,
            ),
          ),
        );

        expect(await output.exists(), isFalse);
        if (await fixture.storage.backupStagingDirectory.exists()) {
          expect(
            await fixture.storage.backupStagingDirectory.list().toList(),
            isEmpty,
          );
        }
      },
    );

    test(
      'copy, snapshot, and archive failures clean temporary staging',
      () async {
        await fixture.seedMixedContent(minimal: true);
        final copyFailure = fixture.service(
          fileCopier: (_, _) async => throw const FileSystemException('copy'),
        );
        await expectLater(
          copyFailure.createBackup(
            destinationFile: File(
              path.join(fixture.support.path, 'copy.stashbackup'),
            ),
          ),
          throwsA(isA<BackupException>()),
        );

        final snapshotFailure = fixture.service(
          snapshotter: const _CorruptSnapshotter(),
        );
        await expectLater(
          snapshotFailure.createBackup(
            destinationFile: File(
              path.join(fixture.support.path, 'snapshot.stashbackup'),
            ),
          ),
          throwsA(isA<BackupException>()),
        );

        final archiveFailure = fixture.service(
          archiveCodec: const _ThrowingArchiveCodec(),
        );
        await expectLater(
          archiveFailure.createBackup(
            destinationFile: File(
              path.join(fixture.support.path, 'archive.stashbackup'),
            ),
          ),
          throwsA(isA<BackupException>()),
        );

        if (await fixture.storage.backupStagingDirectory.exists()) {
          expect(
            await fixture.storage.backupStagingDirectory.list().toList(),
            isEmpty,
          );
        }
        expect(
          await fixture.support
              .list()
              .where((entry) => entry.path.contains('.partial-'))
              .toList(),
          isEmpty,
        );
      },
    );

    test(
      'checksum mismatch, invalid manifest, and future schema are rejected',
      () async {
        final seeded = await fixture.seedMixedContent(minimal: true);
        final output = File(
          path.join(fixture.support.path, 'valid.stashbackup'),
        );
        await fixture.backupService.createBackup(destinationFile: output);
        final extraction = Directory(
          path.join(fixture.support.path, 'mutated'),
        );
        await const ZipBackupArchiveCodec().extract(
          archiveFile: output,
          destination: extraction,
        );
        final attachment = await fixture.attachments.getAttachmentById(
          seeded.attachmentIds.first,
        );
        await File(path.join(extraction.path, attachment!.relativePath))
            .writeAsBytes([99], mode: FileMode.append);
        await expectLater(
          fixture.validator.validateDirectory(
            dataRoot: extraction,
            manifestFile: File(path.join(extraction.path, 'manifest.json')),
          ),
          throwsA(isA<BackupException>()),
        );

        await extraction.delete(recursive: true);
        await const ZipBackupArchiveCodec().extract(
          archiveFile: output,
          destination: extraction,
        );
        final manifestFile = File(path.join(extraction.path, 'manifest.json'));
        final json = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;
        json['formatVersion'] = 999;
        await manifestFile.writeAsString(jsonEncode(json));
        await expectLater(
          fixture.validator.validateDirectory(
            dataRoot: extraction,
            manifestFile: manifestFile,
          ),
          throwsA(
            isA<BackupException>().having(
              (error) => error.failure,
              'failure',
              BackupFailure.unsupportedFormat,
            ),
          ),
        );

        json['formatVersion'] = 1;
        json['databaseSchemaVersion'] = AppDatabase.currentSchemaVersion + 1;
        await manifestFile.writeAsString(jsonEncode(json));
        await expectLater(
          fixture.validator.validateDirectory(
            dataRoot: extraction,
            manifestFile: manifestFile,
          ),
          throwsA(
            isA<BackupException>().having(
              (error) => error.failure,
              'failure',
              BackupFailure.newerSchema,
            ),
          ),
        );

        await manifestFile.writeAsString('{not-json');
        await expectLater(
          fixture.validator.validateDirectory(
            dataRoot: extraction,
            manifestFile: manifestFile,
          ),
          throwsA(
            isA<BackupException>().having(
              (error) => error.failure,
              'failure',
              BackupFailure.corrupted,
            ),
          ),
        );
      },
    );

    test('corrupt ZIP and path traversal entries are rejected', () async {
      final output = File(path.join(fixture.support.path, 'valid.stashbackup'));
      await fixture.backupService.createBackup(destinationFile: output);
      final corrupt = File(
        path.join(fixture.support.path, 'corrupt.stashbackup'),
      );
      await output.copy(corrupt.path);
      await corrupt.writeAsBytes([1, 2, 3], mode: FileMode.writeOnly);
      await expectLater(
        fixture.validator.validateArchive(
          archiveFile: corrupt,
          extractionDirectory: Directory(
            path.join(fixture.support.path, 'bad'),
          ),
        ),
        throwsA(isA<BackupException>()),
      );

      final traversal = File(
        path.join(fixture.support.path, 'traversal.stashbackup'),
      );
      final encoder = ZipFileEncoder()..create(traversal.path);
      encoder.addArchiveFile(ArchiveFile.string('../escape.txt', 'unsafe'));
      await encoder.close();
      await expectLater(
        const ZipBackupArchiveCodec().extract(
          archiveFile: traversal,
          destination: Directory(
            path.join(fixture.support.path, 'traversal-out'),
          ),
        ),
        throwsA(
          isA<BackupException>().having(
            (error) => error.failure,
            'failure',
            BackupFailure.invalidPath,
          ),
        ),
      );
      expect(
        await File(path.join(fixture.support.path, 'escape.txt')).exists(),
        isFalse,
      );
    });
  });

  group('staged restore and profile isolation', () {
    late _Fixture fixture;

    setUp(() async => fixture = await _Fixture.create());
    tearDown(() => fixture.dispose());

    test(
      'pre-restore backup, pending process boundary, and startup swap succeed',
      () async {
        final seeded = await fixture.seedMixedContent();
        final source = File(
          path.join(fixture.support.path, 'before.stashbackup'),
        );
        await fixture.backupService.createBackup(destinationFile: source);
        await fixture.items.createItem(id: 'later-item', content: 'disappear');
        final stableMarker = await fixture.createStableMarker();
        final coordinator = fixture.restoreCoordinator();

        final inspected = await coordinator.inspectBackup(source);
        expect(inspected.manifest.itemCount, 1);
        final prepared = await coordinator.prepareRestore(source);
        expect(await File(prepared.safetyBackupPath).exists(), isTrue);
        final safetyExtraction = Directory(
          path.join(fixture.support.path, 'safety-check'),
        );
        final safety = await fixture.validator.validateArchive(
          archiveFile: File(prepared.safetyBackupPath),
          extractionDirectory: safetyExtraction,
        );
        expect(safety.manifest.itemCount, 2);

        final pendingFromNewProcess = await PendingRestoreStore(
          storage: fixture.storage,
        ).read();
        expect(pendingFromNewProcess, isNotNull);
        expect(pendingFromNewProcess!.profile, AppProfile.dev);
        await fixture.closeDatabase();

        final session = await StartupRestoreApplier(
          storage: fixture.storage,
          validator: fixture.validator,
          pendingStore: PendingRestoreStore(storage: fixture.storage),
        ).applyPending();
        expect(session, isNotNull);
        final restored = AppDatabase.open(storage: fixture.storage);
        await restored.customSelect('PRAGMA quick_check').get();
        final restoredItems = ItemRepository(restored);
        expect(await restoredItems.getItemById('mixed-item'), isNotNull);
        expect(await restoredItems.getItemById('later-item'), isNull);
        for (final id in seeded.attachmentIds) {
          expect(
            await AttachmentRepository(
              restored,
              storageRoot: fixture.storage.root,
            ).resolveAttachmentFile(id),
            isNotNull,
          );
        }
        await restored.close();
        await session!.commit();

        expect(await fixture.storage.pendingRestoreFile.exists(), isFalse);
        expect(await stableMarker.readAsString(), 'stable-untouched');
      },
    );

    test('an empty backup safely replaces a non-empty Dev profile', () async {
      final source = File(
        path.join(fixture.support.path, 'empty-source.stashbackup'),
      );
      await fixture.backupService.createBackup(destinationFile: source);
      await fixture.items.createItem(id: 'temporary', content: 'remove me');
      await fixture.restoreCoordinator().prepareRestore(source);
      await fixture.closeDatabase();

      final session = await StartupRestoreApplier(
        storage: fixture.storage,
        validator: fixture.validator,
        pendingStore: PendingRestoreStore(storage: fixture.storage),
      ).applyPending();
      final restored = AppDatabase.open(storage: fixture.storage);
      await restored.customSelect('PRAGMA quick_check').get();
      expect(await restored.select(restored.items).get(), isEmpty);
      await restored.close();
      await session!.commit();
    });

    test('failed startup verification rolls back the old profile', () async {
      await fixture.items.createItem(id: 'before', content: 'before');
      final source = File(
        path.join(fixture.support.path, 'rollback.stashbackup'),
      );
      await fixture.backupService.createBackup(destinationFile: source);
      await fixture.items.createItem(
        id: 'must-survive',
        content: 'old current',
      );
      final coordinator = fixture.restoreCoordinator();
      await coordinator.prepareRestore(source);
      await fixture.closeDatabase();

      final session = await StartupRestoreApplier(
        storage: fixture.storage,
        validator: fixture.validator,
        pendingStore: PendingRestoreStore(storage: fixture.storage),
      ).applyPending();
      expect(session, isNotNull);
      await session!.rollback();

      final oldDatabase = AppDatabase.open(storage: fixture.storage);
      await oldDatabase.customSelect('PRAGMA quick_check').get();
      final oldItems = ItemRepository(oldDatabase);
      expect(await oldItems.getItemById('must-survive'), isNotNull);
      await oldDatabase.close();
      expect(await fixture.storage.pendingRestoreFile.exists(), isFalse);
    });

    test('Dev pending metadata cannot be applied to Stable', () async {
      await fixture.items.createItem(id: 'before', content: 'before');
      final source = File(
        path.join(fixture.support.path, 'profile.stashbackup'),
      );
      await fixture.backupService.createBackup(destinationFile: source);
      await fixture.restoreCoordinator().prepareRestore(source);
      final stableStorage = AppStoragePaths.fromSupportDirectory(
        profile: AppProfile.stable,
        supportDirectory: fixture.support,
      );
      await stableStorage.maintenanceDirectory.create(recursive: true);
      await fixture.storage.pendingRestoreFile.copy(
        stableStorage.pendingRestoreFile.path,
      );

      await expectLater(
        PendingRestoreStore(storage: stableStorage).read(),
        throwsA(isA<BackupException>()),
      );
      expect(await stableStorage.root.exists(), isFalse);
    });
  });

  test(
    'pre-migration boundary backs up an older schema without bumping it',
    () async {
      final support = await Directory.systemTemp.createTemp('stash-migration-');
      addTearDown(() => support.delete(recursive: true));
      final storage = AppStoragePaths.fromSupportDirectory(
        profile: AppProfile.dev,
        supportDirectory: support,
      );
      await storage.ensureCreated();
      final raw = sqlite3.open(storage.databaseFile.path);
      raw.execute('''
      CREATE TABLE items (id TEXT PRIMARY KEY, content TEXT NOT NULL);
      CREATE TABLE channels (id TEXT PRIMARY KEY, name TEXT NOT NULL);
      INSERT INTO items VALUES ('legacy', 'kept');
      PRAGMA user_version = 2;
    ''');
      raw.close();
      final backupDirectory = Directory(path.join(support.path, 'backups'));
      final service = BackupService(
        profile: AppProfile.dev,
        storage: storage,
        appVersion: 'test',
        currentSchemaVersion: AppDatabase.currentSchemaVersion,
      );
      final result = await PreMigrationBackupCoordinator(
        storage: storage,
        backupService: service,
        backupDirectoryResolver: _FixedDirectoryResolver(backupDirectory),
        currentSchemaVersion: AppDatabase.currentSchemaVersion,
        clock: () => DateTime.utc(2026, 10, 14, 12),
      ).createIfNeeded();

      expect(result, isNotNull);
      expect(result!.manifest.databaseSchemaVersion, 2);
      final unchanged = sqlite3.open(
        storage.databaseFile.path,
        mode: OpenMode.readOnly,
      );
      try {
        expect(unchanged.userVersion, 2);
      } finally {
        unchanged.close();
      }
    },
  );
}

class _Fixture {
  _Fixture._({
    required this.support,
    required this.storage,
    required this.database,
  }) : items = ItemRepository(database),
       channels = ChannelRepository(database),
       attachments = AttachmentRepository(database, storageRoot: storage.root),
       validator = const BackupValidator(
         archiveCodec: ZipBackupArchiveCodec(),
         currentSchemaVersion: AppDatabase.currentSchemaVersion,
       ),
       backupService = BackupService(
         profile: AppProfile.dev,
         storage: storage,
         appVersion: '0.5.0-test',
         currentSchemaVersion: AppDatabase.currentSchemaVersion,
         clock: _fixedClock,
       );

  static Future<_Fixture> create() async {
    final support = await Directory.systemTemp.createTemp('stash-backup-test-');
    final storage = AppStoragePaths.fromSupportDirectory(
      profile: AppProfile.dev,
      supportDirectory: support,
    );
    await storage.ensureCreated();
    final database = AppDatabase.open(storage: storage);
    await database.customSelect('PRAGMA user_version').get();
    return _Fixture._(support: support, storage: storage, database: database);
  }

  final Directory support;
  final AppStoragePaths storage;
  AppDatabase database;
  final ItemRepository items;
  final ChannelRepository channels;
  final AttachmentRepository attachments;
  final BackupValidator validator;
  final BackupService backupService;
  bool _databaseClosed = false;

  BackupService service({
    BackupArchiveCodec archiveCodec = const ZipBackupArchiveCodec(),
    DatabaseSnapshotter snapshotter = const SqliteOnlineSnapshotter(),
    StreamFileCopier fileCopier = copyFileStreamed,
  }) => BackupService(
    profile: AppProfile.dev,
    storage: storage,
    appVersion: 'test',
    currentSchemaVersion: AppDatabase.currentSchemaVersion,
    archiveCodec: archiveCodec,
    snapshotter: snapshotter,
    fileCopier: fileCopier,
    clock: _fixedClock,
  );

  RestoreCoordinator restoreCoordinator() => RestoreCoordinator(
    storage: storage,
    backupService: backupService,
    validator: validator,
    pendingStore: PendingRestoreStore(storage: storage),
    backupDirectoryResolver: _FixedDirectoryResolver(
      Directory(path.join(support.path, 'backups')),
    ),
    clock: _fixedClock,
  );

  Future<_SeededContent> seedMixedContent({bool minimal = false}) async {
    final root = await channels.createRootChannel(
      id: 'root-channel',
      name: 'Root',
    );
    await channels.createChildChannel(
      id: 'child-channel',
      name: 'Child',
      parentId: root.id,
    );
    await items.createItem(
      id: 'mixed-item',
      content: 'placeholder',
      channelId: 'child-channel',
    );
    final ids = <String>[];
    final image = await attachments.importImage(
      id: 'image-id',
      itemId: 'mixed-item',
      bytes: Uint8List.fromList([137, 80, 78, 71]),
      mimeType: 'image/png',
      originalFileName: 'image.png',
    );
    ids.add(image.id);
    final sourceDirectory = Directory(path.join(support.path, 'sources'));
    await sourceDirectory.create(recursive: true);
    final specs = minimal
        ? const [('pdf-id', 'report.pdf', 32)]
        : const [
            ('pdf-id', 'report.pdf', 32),
            ('pdf-two-id', 'report.pdf', 48),
            ('docx-id', 'notes.docx', 64),
            ('pptx-id', 'slides.pptx', 80),
            ('xlsx-id', 'table.xlsx', 96),
            ('zip-id', 'archive.zip', 112),
            ('unknown-id', 'payload.weird', 128),
            ('large-id', 'large.bin', 2 * 1024 * 1024),
          ];
    for (final spec in specs) {
      final source = File(path.join(sourceDirectory.path, '${spec.$1}.source'));
      final sink = source.openWrite();
      var remaining = spec.$3;
      final chunk = Uint8List(64 * 1024);
      while (remaining > 0) {
        final count = remaining < chunk.length ? remaining : chunk.length;
        sink.add(Uint8List.sublistView(chunk, 0, count));
        remaining -= count;
      }
      await sink.close();
      final attachment = await attachments.importFile(
        id: spec.$1,
        itemId: 'mixed-item',
        sourceFile: source,
        originalFileName: spec.$2,
      );
      ids.add(attachment.id);
    }
    final operations = <Map<String, Object?>>[
      {'insert': 'mixed text'},
      {'insert': BlockEmbed.custom(const StashImageEmbed('image-id')).toJson()},
      for (final id in ids.where((value) => value != 'image-id'))
        {'insert': BlockEmbed.custom(StashFileEmbed(id)).toJson()},
      {'insert': '\n'},
    ];
    await items.updateItem(
      'mixed-item',
      document: const ItemDocumentCodec().snapshot(
        Document.fromJson(operations),
      ),
    );
    return _SeededContent(attachmentIds: ids);
  }

  Future<File> createStableMarker() async {
    final stable = AppStoragePaths.fromSupportDirectory(
      profile: AppProfile.stable,
      supportDirectory: support,
    );
    await stable.root.create(recursive: true);
    final marker = File(path.join(stable.root.path, 'marker.txt'));
    await marker.writeAsString('stable-untouched');
    return marker;
  }

  Future<void> closeDatabase() async {
    if (_databaseClosed) return;
    await database.close();
    _databaseClosed = true;
  }

  Future<void> dispose() async {
    await closeDatabase();
    if (await support.exists()) await support.delete(recursive: true);
  }
}

class _SeededContent {
  const _SeededContent({required this.attachmentIds});
  final List<String> attachmentIds;
}

class _FixedDirectoryResolver implements BackupDirectoryResolver {
  const _FixedDirectoryResolver(this.directory);
  final Directory directory;

  @override
  Future<Directory> defaultBackupDirectory() async => directory;
}

class _CorruptSnapshotter implements DatabaseSnapshotter {
  const _CorruptSnapshotter();

  @override
  Future<void> createSnapshot({
    required File source,
    required File target,
  }) async {
    await target.parent.create(recursive: true);
    await target.writeAsBytes([1, 2, 3], flush: true);
  }
}

class _ThrowingArchiveCodec implements BackupArchiveCodec {
  const _ThrowingArchiveCodec();

  @override
  Future<void> create({
    required Directory sourceDirectory,
    required BackupManifest manifest,
    required File outputFile,
  }) async => throw const FileSystemException('archive');

  @override
  Future<void> extract({
    required File archiveFile,
    required Directory destination,
  }) async => throw const FileSystemException('archive');
}

DateTime _fixedClock() => DateTime.utc(2026, 10, 14, 12);
