import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'file_attachment_ingestor.dart';

abstract interface class FilePickerGateway {
  Future<List<ImportedFileData>> pickFiles();
}

class SystemFilePickerGateway implements FilePickerGateway {
  const SystemFilePickerGateway();

  @override
  Future<List<ImportedFileData>> pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      withData: false,
      allowMultiple: true,
      dialogTitle: 'Attach files',
      lockParentWindow: true,
    );
    if (result == null) return const [];
    return [
      for (final picked in result.files)
        if (picked.path != null)
          ImportedFileData.localFile(File(picked.path!), fileName: picked.name),
    ];
  }
}
