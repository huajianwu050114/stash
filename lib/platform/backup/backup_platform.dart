import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

abstract interface class BackupFilePicker {
  Future<String?> chooseBackupDestination({
    required String initialDirectory,
    required String suggestedFileName,
  });

  Future<String?> chooseBackupToRestore({String? initialDirectory});
}

class SystemBackupFilePicker implements BackupFilePicker {
  const SystemBackupFilePicker();

  @override
  Future<String?> chooseBackupDestination({
    required String initialDirectory,
    required String suggestedFileName,
  }) => FilePicker.saveFile(
    dialogTitle: 'Create Stash Backup',
    initialDirectory: initialDirectory,
    fileName: suggestedFileName,
    type: FileType.custom,
    allowedExtensions: const ['stashbackup'],
    lockParentWindow: true,
  );

  @override
  Future<String?> chooseBackupToRestore({String? initialDirectory}) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Restore Stash Backup',
      initialDirectory: initialDirectory,
      type: FileType.custom,
      allowedExtensions: const ['stashbackup'],
      allowMultiple: false,
      withData: false,
      lockParentWindow: true,
    );
    return result?.files.single.path;
  }
}

abstract interface class BackupDirectoryResolver {
  Future<Directory> defaultBackupDirectory();
}

class DocumentsBackupDirectoryResolver implements BackupDirectoryResolver {
  const DocumentsBackupDirectoryResolver();

  @override
  Future<Directory> defaultBackupDirectory() async => Directory(
    path.join((await getApplicationDocumentsDirectory()).path, 'Stash Backups'),
  );
}

abstract interface class BackupFolderActions {
  Future<void> openFolder(Directory directory);
}

class SystemBackupFolderActions implements BackupFolderActions {
  const SystemBackupFolderActions();

  @override
  Future<void> openFolder(Directory directory) async {
    await directory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [directory.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [directory.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [directory.path]);
      return;
    }
    throw UnsupportedError('Opening backup folders is not supported here.');
  }
}
