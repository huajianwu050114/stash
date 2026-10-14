enum BackupFailure {
  createFailed,
  missingAttachment,
  corrupted,
  unsupportedFormat,
  newerSchema,
  invalidPath,
  restorePreparationFailed,
  safetyBackupFailed,
  restoreRolledBack,
}

class BackupException implements Exception {
  const BackupException(this.failure, this.message, [this.cause]);

  final BackupFailure failure;
  final String message;
  final Object? cause;

  String get userMessage => switch (failure) {
    BackupFailure.createFailed => 'Backup could not be created.',
    BackupFailure.missingAttachment => message,
    BackupFailure.corrupted => 'The backup file is corrupted.',
    BackupFailure.unsupportedFormat => 'This backup format is not supported.',
    BackupFailure.newerSchema =>
      'This backup was created by a newer version of Stash.',
    BackupFailure.invalidPath => 'The backup file is corrupted.',
    BackupFailure.restorePreparationFailed => 'Restore could not be prepared.',
    BackupFailure.safetyBackupFailed =>
      'The safety backup could not be created.',
    BackupFailure.restoreRolledBack => 'Restore was rolled back.',
  };

  @override
  String toString() => 'BackupException($failure, $message)';
}
