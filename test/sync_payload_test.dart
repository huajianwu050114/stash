import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/sync/domain/sync_models.dart';
import 'package:stash/features/sync/domain/sync_payloads.dart';

void main() {
  final createdAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
  final updatedAt = DateTime.utc(2026, 2, 3, 4, 5, 6);
  final deletedAt = DateTime.utc(2026, 3, 4, 5, 6, 7);

  test('Item payload round-trips portable state', () {
    final payload = ItemSyncPayload(
      id: 'item',
      title: 'Title',
      content: 'Body',
      note: 'Note',
      channelId: 'channel',
      documentJson: '{"version":1}',
      tags: ['a', 'b'],
      isPinned: true,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
      serverRevision: 8,
    );

    expect(
      ItemSyncPayload.fromJson(payload.toJson()).toJson(),
      payload.toJson(),
    );
  });

  test('Channel payload round-trips without device UI state', () {
    final payload = ChannelSyncPayload(
      id: 'channel',
      name: 'Channel',
      parentId: 'parent',
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: null,
      serverRevision: 3,
    );

    final json = payload.toJson();
    expect(ChannelSyncPayload.fromJson(json).toJson(), json);
    expect(json, isNot(contains('isExpanded')));
    expect(json, isNot(contains('sidebarWidth')));
    expect(json, isNot(contains('hotkey')));
  });

  test('Attachment payload excludes local paths and blob bytes', () {
    final payload = AttachmentSyncPayload(
      id: 'attachment',
      itemId: 'item',
      mimeType: 'application/pdf',
      originalFileName: 'paper.pdf',
      byteSize: 42,
      sha256: 'abc123',
      createdAt: createdAt,
      deletedAt: deletedAt,
      serverRevision: 5,
    );

    final json = payload.toJson();
    expect(AttachmentSyncPayload.fromJson(json).toJson(), json);
    expect(json, isNot(contains('relativePath')));
    expect(json, isNot(contains('absolutePath')));
    expect(json, isNot(contains('blob')));
    expect(json['sha256'], 'abc123');
    final encoded = jsonEncode(json);
    expect(encoded, isNot(contains(r'C:\')));
    expect(encoded.toLowerCase(), isNot(contains('appdata')));
  });

  test('optimistic concurrency detects stale and idempotent mutations', () {
    expect(
      SyncConcurrency.evaluate(remoteRevision: 7, baseRevision: 7).outcome,
      SyncApplyOutcome.accepted,
    );
    expect(
      SyncConcurrency.evaluate(remoteRevision: 8, baseRevision: 7).outcome,
      SyncApplyOutcome.conflict,
    );
    expect(
      SyncConcurrency.evaluate(
        remoteRevision: 8,
        baseRevision: 7,
        mutationAlreadyApplied: true,
      ).outcome,
      SyncApplyOutcome.alreadyApplied,
    );
    expect(
      SyncConcurrency.evaluate(remoteRevision: 6, baseRevision: 7).outcome,
      SyncApplyOutcome.invalidDependency,
    );
  });
}
