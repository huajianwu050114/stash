import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:path/path.dart' as path;
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/attachments/data/attachment_repository.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/sync/application/sync_engine.dart';
import 'package:stash/features/sync/data/cloudflare_sync_remote.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  final config = CloudflareSyncConfig.fromProcessEnvironment();
  final remote = CloudflareSyncRemote(config: config);
  final runId = const Uuid().v4();
  final a = await _Device.create('a', remote);
  final b = await _Device.create('b', remote);
  try {
    final channelId = 'smoke-channel-$runId';
    final itemId = 'smoke-item-$runId';
    final attachmentId = 'smoke-attachment-$runId';
    await a.channels.createRootChannel(id: channelId, name: 'S3 smoke');
    await a.items.createItem(
      id: itemId,
      channelId: channelId,
      content: 'from A',
    );
    _requireClean(await a.engine.syncOnce(), 'A initial push');
    _requireClean(await b.engine.syncOnce(), 'B initial pull');

    final source = File(path.join(a.root.path, 'fixture.bin'));
    await source.writeAsBytes([1, 2, 3, 4]);
    await a.attachments.importFile(
      id: attachmentId,
      itemId: itemId,
      sourceFile: source,
      originalFileName: 'fixture.bin',
    );
    const codec = ItemDocumentCodec();
    final document = Document.fromJson([
      {'insert': 'cloud attachment\n'},
      {'insert': BlockEmbed.custom(StashFileEmbed(attachmentId)).toJson()},
      {'insert': '\n'},
    ]);
    await a.items.updateItem(itemId, document: codec.snapshot(document));
    _requireClean(await a.engine.syncOnce(), 'A attachment push');
    _requireClean(await b.engine.syncOnce(), 'B attachment pull');
    final downloaded = await b.attachments.resolveAttachmentFile(attachmentId);
    if (downloaded == null || !(await downloaded.exists())) {
      throw StateError('B did not install the attachment.');
    }

    await a.items.updateItem(itemId, content: 'A conflict winner');
    await b.items.updateItem(itemId, content: 'B offline edit');
    _requireClean(await a.engine.syncOnce(), 'A conflict push');
    final conflict = await b.engine.syncOnce();
    if (conflict.conflicts.length != 1) {
      throw StateError(
        'Expected one B conflict, got ${conflict.conflicts.length}.',
      );
    }
    stdout.writeln('S3 smoke PASS: two-device, attachment, conflict.');
  } finally {
    remote.close();
    await a.close();
    await b.close();
  }
}

void _requireClean(SyncCycleResult result, String stage) {
  if (result.errors.isNotEmpty || result.conflicts.isNotEmpty) {
    throw StateError(
      '$stage failed: errors=${result.errors.length}, conflicts=${result.conflicts.length}',
    );
  }
}

class _Device {
  _Device(this.db, this.root, this.remote)
    : channels = ChannelRepository(db),
      items = ItemRepository(db),
      attachments = AttachmentRepository(db, storageRoot: root),
      engine = SyncEngine(remote, database: db, storageRoot: root);

  static Future<_Device> create(
    String name,
    CloudflareSyncRemote remote,
  ) async {
    return _Device(
      AppDatabase(NativeDatabase.memory()),
      await Directory.systemTemp.createTemp('stash-s3-$name-'),
      remote,
    );
  }

  final AppDatabase db;
  final Directory root;
  final CloudflareSyncRemote remote;
  final ChannelRepository channels;
  final ItemRepository items;
  final AttachmentRepository attachments;
  final SyncEngine engine;

  Future<void> close() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
