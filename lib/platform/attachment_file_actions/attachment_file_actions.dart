import 'dart:io';

abstract interface class AttachmentFileActions {
  bool get canShowInFolder;

  Future<void> open(File file);

  Future<void> showInFolder(File file);
}

class SystemAttachmentFileActions implements AttachmentFileActions {
  const SystemAttachmentFileActions();

  @override
  bool get canShowInFolder => Platform.isWindows || Platform.isMacOS;

  @override
  Future<void> open(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('Attachment file is unavailable.', file.path);
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [file.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [file.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [file.path]);
      return;
    }
    throw UnsupportedError('Opening attachments is not supported here.');
  }

  @override
  Future<void> showInFolder(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('Attachment file is unavailable.', file.path);
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', file.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', ['-R', file.path]);
      return;
    }
    throw UnsupportedError('Show in folder is not supported here.');
  }
}
