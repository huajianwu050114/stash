import 'package:path/path.dart' as path;

enum AttachmentKind {
  image,
  pdf,
  document,
  spreadsheet,
  presentation,
  archive,
  text,
  generic;

  bool get isImage => this == AttachmentKind.image;
}

AttachmentKind attachmentKindFor(String mimeType, String? fileName) {
  final normalizedMime = mimeType.toLowerCase();
  final extension = _extension(fileName);
  if (normalizedMime.startsWith('image/') ||
      _imageExtensions.contains(extension)) {
    return AttachmentKind.image;
  }
  if (normalizedMime == 'application/pdf' || extension == 'pdf') {
    return AttachmentKind.pdf;
  }
  if (_documentExtensions.contains(extension) ||
      normalizedMime.contains('word') ||
      normalizedMime == 'application/rtf') {
    return AttachmentKind.document;
  }
  if (_spreadsheetExtensions.contains(extension) ||
      normalizedMime.contains('spreadsheet') ||
      normalizedMime.contains('excel')) {
    return AttachmentKind.spreadsheet;
  }
  if (_presentationExtensions.contains(extension) ||
      normalizedMime.contains('presentation') ||
      normalizedMime.contains('powerpoint')) {
    return AttachmentKind.presentation;
  }
  if (_archiveExtensions.contains(extension) ||
      normalizedMime.contains('zip') ||
      normalizedMime.contains('archive') ||
      normalizedMime.contains('compressed')) {
    return AttachmentKind.archive;
  }
  if (normalizedMime.startsWith('text/') ||
      _textExtensions.contains(extension)) {
    return AttachmentKind.text;
  }
  return AttachmentKind.generic;
}

String inferAttachmentMimeType(String? fileName) {
  return switch (_extension(fileName)) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'txt' || 'log' => 'text/plain',
    'md' || 'markdown' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'yaml' || 'yml' => 'application/yaml',
    'xml' => 'application/xml',
    'html' || 'htm' => 'text/html',
    'zip' => 'application/zip',
    'rar' => 'application/vnd.rar',
    '7z' => 'application/x-7z-compressed',
    'tar' => 'application/x-tar',
    'gz' => 'application/gzip',
    _ => 'application/octet-stream',
  };
}

String _extension(String? fileName) {
  if (fileName == null) return '';
  final extension = path.extension(fileName).toLowerCase();
  return extension.startsWith('.') ? extension.substring(1) : extension;
}

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'};
const _documentExtensions = {'doc', 'docx', 'rtf', 'odt'};
const _spreadsheetExtensions = {'xls', 'xlsx', 'ods'};
const _presentationExtensions = {'ppt', 'pptx', 'odp'};
const _archiveExtensions = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'};
const _textExtensions = {
  'txt',
  'md',
  'markdown',
  'csv',
  'json',
  'yaml',
  'yml',
  'xml',
  'html',
  'htm',
  'dart',
  'js',
  'ts',
  'py',
  'java',
  'kt',
  'c',
  'cc',
  'cpp',
  'h',
  'hpp',
  'cs',
  'go',
  'rs',
  'sh',
  'ps1',
};
