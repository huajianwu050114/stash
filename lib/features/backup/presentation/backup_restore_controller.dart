import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../platform/backup/backup_platform.dart';
import '../data/backup_preferences.dart';
import '../data/backup_service.dart';
import '../data/restore_coordinator.dart';
import '../domain/backup_exception.dart';
import '../domain/backup_manifest.dart';

class BackupRestoreController extends ChangeNotifier {
  BackupRestoreController({
    required this.backupService,
    required this.restoreCoordinator,
    required this.preferences,
    required this.filePicker,
    required this.directoryResolver,
    required this.folderActions,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final BackupService backupService;
  final RestoreCoordinator restoreCoordinator;
  final BackupPreferences preferences;
  final BackupFilePicker filePicker;
  final BackupDirectoryResolver directoryResolver;
  final BackupFolderActions folderActions;
  final DateTime Function() _clock;

  bool _busy = false;
  String? _status;
  String? _error;
  LastBackupStatus? _lastBackup;
  BackupSummary? _restoreCandidate;

  bool get busy => _busy;
  String? get status => _status;
  String? get error => _error;
  LastBackupStatus? get lastBackup => _lastBackup;
  BackupSummary? get restoreCandidate => _restoreCandidate;

  Future<void> initialize() async {
    _lastBackup = await preferences.loadLastBackup();
    notifyListeners();
  }

  Future<BackupSummary?> createBackup() async {
    if (_busy) return null;
    return _run(() async {
      final folder = await _preferredFolder();
      await folder.create(recursive: true);
      final selected = await filePicker.chooseBackupDestination(
        initialDirectory: folder.path,
        suggestedFileName: 'Stash-Backup-${_timestamp(_clock())}.stashbackup',
      );
      if (selected == null) return null;
      final summary = await backupService.createBackup(
        destinationFile: File(selected),
        onProgress: (stage) {
          _status = stage.label;
          notifyListeners();
        },
      );
      _lastBackup = LastBackupStatus(
        path: summary.archivePath,
        createdAt: summary.manifest.createdAtUtc,
      );
      await preferences.saveSuccessfulBackup(
        path: summary.archivePath,
        createdAt: summary.manifest.createdAtUtc,
      );
      await preferences.saveLastFolder(path.dirname(summary.archivePath));
      return summary;
    });
  }

  Future<BackupSummary?> selectRestore() async {
    if (_busy) return null;
    return _run(() async {
      final folder = await _preferredFolder();
      final selected = await filePicker.chooseBackupToRestore(
        initialDirectory: folder.path,
      );
      if (selected == null) return null;
      _status = 'Validating backup…';
      notifyListeners();
      final summary = await restoreCoordinator.inspectBackup(File(selected));
      _restoreCandidate = summary;
      await preferences.saveLastFolder(path.dirname(selected));
      return summary;
    });
  }

  Future<PreparedRestore?> prepareSelectedRestore() async {
    final candidate = _restoreCandidate;
    if (_busy || candidate == null) return null;
    return _run(() async {
      _status = 'Creating safety backup…';
      notifyListeners();
      final prepared = await restoreCoordinator.prepareRestore(
        File(candidate.archivePath),
      );
      _restoreCandidate = null;
      _status = 'Backup is ready to restore. Restart Stash to finish.';
      return prepared;
    });
  }

  Future<void> openBackupFolder() async {
    if (_busy) return;
    try {
      await folderActions.openFolder(await _preferredFolder());
    } catch (error) {
      _error = 'Backup folder could not be opened.';
      notifyListeners();
    }
  }

  Future<T?> _run<T>(Future<T?> Function() operation) async {
    _busy = true;
    _status = null;
    _error = null;
    notifyListeners();
    try {
      return await operation();
    } on BackupException catch (error) {
      _error = error.userMessage;
      return null;
    } catch (_) {
      _error = 'Backup operation failed.';
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<Directory> _preferredFolder() async {
    final saved = await preferences.loadLastFolder();
    return saved == null
        ? directoryResolver.defaultBackupDirectory()
        : Directory(saved);
  }
}

String _timestamp(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}-'
      '${local.hour.toString().padLeft(2, '0')}'
      '${local.minute.toString().padLeft(2, '0')}'
      '${local.second.toString().padLeft(2, '0')}';
}
