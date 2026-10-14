import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_profile.dart';
import '../domain/backup_manifest.dart';
import 'backup_restore_controller.dart';

class BackupRestoreSection extends StatelessWidget {
  const BackupRestoreSection({
    super.key,
    required this.controller,
    required this.profile,
  });

  final BackupRestoreController controller;
  final AppProfile profile;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final last = controller.lastBackup;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Backup & Restore',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Protects Items, Channels, documents, and managed attachments. '
            'Device settings and shortcuts are not included.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('create-backup'),
                onPressed: controller.busy
                    ? null
                    : () => unawaited(_createBackup(context)),
                icon: const Icon(Icons.backup_outlined),
                label: const Text('Create Backup'),
              ),
              OutlinedButton.icon(
                key: const Key('restore-backup'),
                onPressed: controller.busy
                    ? null
                    : () => unawaited(_selectRestore(context)),
                icon: const Icon(Icons.restore_outlined),
                label: const Text('Restore Backup'),
              ),
              TextButton.icon(
                key: const Key('open-backup-folder'),
                onPressed: controller.busy
                    ? null
                    : () => unawaited(controller.openBackupFolder()),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open Backup Folder'),
              ),
            ],
          ),
          if (controller.busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(key: Key('backup-progress')),
          ],
          if (controller.status != null) ...[
            const SizedBox(height: 8),
            Text(controller.status!, key: const Key('backup-status')),
          ],
          if (controller.error != null) ...[
            const SizedBox(height: 8),
            Text(
              controller.error!,
              key: const Key('backup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            last == null
                ? 'Last successful backup: Never'
                : 'Last successful backup: '
                      '${_formatTime(last.createdAt.toLocal())}',
            key: const Key('last-backup-time'),
          ),
          if (last != null)
            Text(
              'Backup location: ${last.path}',
              key: const Key('last-backup-location'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      );
    },
  );

  Future<void> _createBackup(BuildContext context) async {
    final summary = await controller.createBackup();
    if (!context.mounted || summary == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Backup complete: ${summary.archivePath} '
          '(${_formatBytes(summary.archiveSize)})',
        ),
      ),
    );
  }

  Future<void> _selectRestore(BuildContext context) async {
    final summary = await controller.selectRestore();
    if (!context.mounted || summary == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('restore-summary-dialog'),
        title: const Text('Restore Backup'),
        content: _RestoreSummary(summary: summary, profile: profile),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-restore'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Create safety backup and continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final prepared = await controller.prepareSelectedRestore();
    if (!context.mounted || prepared == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('restore-ready-dialog'),
        title: const Text('Restart required'),
        content: Text(
          'Backup is ready to restore. Close and relaunch '
          '${profile.displayName} to finish.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _RestoreSummary extends StatelessWidget {
  const _RestoreSummary({required this.summary, required this.profile});

  final BackupSummary summary;
  final AppProfile profile;

  @override
  Widget build(BuildContext context) {
    final manifest = summary.manifest;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Backup created: ${_formatTime(manifest.createdAtUtc.toLocal())}'),
        Text('App version: ${manifest.appVersion}'),
        Text('Schema version: ${manifest.databaseSchemaVersion}'),
        Text('Items: ${manifest.itemCount}'),
        Text('Channels: ${manifest.channelCount}'),
        Text('Attachments: ${manifest.attachmentCount}'),
        Text('Total size: ${_formatBytes(summary.archiveSize)}'),
        const SizedBox(height: 16),
        Text(
          'This will replace the current ${profile.displayName} data.',
          key: const Key('restore-replacement-warning'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    );
  }
}

String _formatTime(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
