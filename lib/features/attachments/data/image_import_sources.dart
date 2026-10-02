import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';

class ImportedImageData {
  const ImportedImageData({
    required this.bytes,
    required this.mimeType,
    this.fileName,
  });

  final Uint8List bytes;
  final String mimeType;
  final String? fileName;
}

abstract interface class ClipboardReaderGateway {
  Future<ImportedImageData?> readImage();
  Future<String?> readPlainText();
}

class SystemClipboardReaderGateway implements ClipboardReaderGateway {
  const SystemClipboardReaderGateway();

  @override
  Future<ImportedImageData?> readImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.png)) return null;
    final completer = Completer<ImportedImageData?>();
    final progress = reader.getFile(Formats.png, (file) async {
      try {
        completer.complete(
          ImportedImageData(
            bytes: await file.readAll(),
            mimeType: 'image/png',
            fileName: file.fileName,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }, onError: (error) => completer.completeError(error));
    return progress == null ? null : completer.future;
  }

  @override
  Future<String?> readPlainText() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    return (await clipboard.read()).readValue(Formats.plainText);
  }
}

abstract interface class ImagePickerGateway {
  Future<ImportedImageData?> pickImage();
}

class FilePickerImageGateway implements ImagePickerGateway {
  const FilePickerImageGateway();

  @override
  Future<ImportedImageData?> pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
      dialogTitle: 'Insert image',
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) return null;
    return ImportedImageData(
      bytes: bytes,
      mimeType: _mimeTypeFor(file.extension),
      fileName: file.name,
    );
  }

  static String _mimeTypeFor(String? extension) =>
      switch (extension?.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/png',
      };
}
