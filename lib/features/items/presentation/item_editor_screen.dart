import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/providers.dart';
import '../../attachments/data/attachment_repository.dart';
import '../../attachments/data/image_attachment_ingestor.dart';
import '../../attachments/data/image_import_sources.dart';
import '../../attachments/presentation/image_drop_region.dart';
import '../../attachments/presentation/stash_image_embed_builder.dart';
import '../data/item_document_codec.dart';
import '../data/item_repository.dart';
import '../domain/item.dart';

class ItemEditorScreen extends ConsumerStatefulWidget {
  const ItemEditorScreen.create({super.key, this.channelId}) : item = null;

  const ItemEditorScreen.edit({super.key, required this.item})
    : channelId = null;

  final Item? item;
  final String? channelId;

  bool get isEditing => item != null;

  @override
  ConsumerState<ItemEditorScreen> createState() => _ItemEditorScreenState();
}

class _ItemEditorScreenState extends ConsumerState<ItemEditorScreen> {
  static const _codec = ItemDocumentCodec();
  static final Uuid _uuid = Uuid();

  late final String _itemId;
  late final QuillController _documentController;
  late final FocusNode _documentFocusNode;
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  late final TextEditingController _tagsController;
  late final AttachmentRepository _attachments;
  late final ImageAttachmentIngestor _imageIngestor;
  late final ClipboardReaderGateway _clipboard;
  late final ImagePickerGateway _imagePicker;
  final Set<String> _sessionAttachmentIds = {};
  bool _detailsExpanded = false;
  bool _formattingExpanded = false;
  bool _saving = false;
  bool _saved = false;
  bool _discarding = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _itemId = item?.id ?? _uuid.v4();
    _attachments = ref.read(attachmentRepositoryProvider);
    _imageIngestor = ImageAttachmentIngestor(_attachments);
    _clipboard = ref.read(clipboardReaderProvider);
    _imagePicker = ref.read(imagePickerProvider);
    _documentFocusNode = FocusNode(debugLabel: 'item-document');
    final document = _codec.decode(
      documentJson: item?.documentJson,
      legacyText: item?.content ?? '',
    );
    _documentController = QuillController(
      document: document,
      selection: TextSelection.collapsed(
        offset: (document.length - 1).clamp(0, document.length),
      ),
    )..addListener(_documentChanged);
    _titleController = TextEditingController(text: item?.title ?? '');
    _noteController = TextEditingController(text: item?.note ?? '');
    _tagsController = TextEditingController(text: item?.tags.join(', ') ?? '');
  }

  void _documentChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _documentController
      ..removeListener(_documentChanged)
      ..dispose();
    _documentFocusNode.dispose();
    _titleController.dispose();
    _noteController.dispose();
    _tagsController.dispose();
    if (!_saved && _sessionAttachmentIds.isNotEmpty) {
      unawaited(_cleanupStagedBestEffort());
    }
    super.dispose();
  }

  Future<void> _cleanupStagedBestEffort() async {
    try {
      await _attachments.cleanupStagedAttachments(_sessionAttachmentIds);
    } catch (_) {
      // Interrupted editors are also covered by AttachmentRepository's
      // age-gated orphan cleanup.
    }
  }

  ItemDocumentSnapshot get _snapshot =>
      _codec.snapshot(_documentController.document);

  bool get _canSave => _snapshot.hasMeaningfulBody;

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);
    final repository = ref.read(itemRepositoryProvider);
    final snapshot = _snapshot;
    final title = _optionalText(_titleController.text);
    final note = _optionalText(_noteController.text);
    final tags = _parseTags(_tagsController.text);
    try {
      final original = widget.item;
      if (original == null) {
        await repository.createItem(
          id: _itemId,
          document: snapshot,
          title: title,
          note: note,
          tags: tags,
          channelId: widget.channelId,
        );
      } else {
        await repository.updateItem(
          original.id,
          title: title == original.title
              ? const FieldUpdate.unchanged()
              : FieldUpdate.set(title),
          document: snapshot,
          note: note == original.note
              ? const FieldUpdate.unchanged()
              : FieldUpdate.set(note),
          tags: listEquals(tags, original.tags) ? null : tags,
        );
      }
      _saved = true;
      final unused = _sessionAttachmentIds.difference(
        snapshot.imageAttachmentIds,
      );
      if (unused.isNotEmpty) {
        try {
          await _attachments.cleanupStagedAttachments(unused);
        } catch (_) {
          // The Item is already durably saved. A later orphan-cleanup pass can
          // retry removal without presenting a false save failure.
        }
      }
      _popAfterStateUpdate();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this item.')),
      );
    }
  }

  Future<void> _insertPickedImage() async {
    try {
      final image = await _imagePicker.pickImage();
      if (image != null) await _importAndInsertImages([image]);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not insert this image.')),
      );
    }
  }

  Future<void> _discardStagedAndPop() async {
    if (_discarding) return;
    _discarding = true;
    try {
      await _attachments.cleanupStagedAttachments(_sessionAttachmentIds);
      _sessionAttachmentIds.clear();
      _popAfterStateUpdate();
    } catch (_) {
      _discarding = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not discard staged images.')),
      );
    }
  }

  void _popAfterStateUpdate() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _paste() async {
    try {
      final image = await _clipboard.readImage();
      if (image != null) {
        await _importAndInsertImages([image]);
        return;
      }
      final text = await _clipboard.readPlainText();
      if (text != null && text.isNotEmpty) _insertText(text);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not paste from clipboard.')),
        );
      }
    }
  }

  Future<void> _importAndInsertImages(List<ImportedImageData> images) async {
    final imported = await _imageIngestor.importImages(
      itemId: _itemId,
      images: images,
    );
    _sessionAttachmentIds.addAll(imported.map((attachment) => attachment.id));
    final selection = _documentController.selection;
    var index = selection.start < 0 ? 0 : selection.start;
    var length = selection.end < 0 ? 0 : selection.end - index;
    for (final attachment in imported) {
      _documentController.replaceText(
        index,
        length,
        BlockEmbed.custom(StashImageEmbed(attachment.id)),
        null,
      );
      index++;
      length = 0;
    }
    _documentController.moveCursorToPosition(index);
    if (mounted) setState(() {});
  }

  void _showDropError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not import dropped image.')),
    );
  }

  void _handleDroppedText(String text) {
    _insertText(text);
    _documentFocusNode.requestFocus();
  }

  void _insertText(String text) {
    final selection = _documentController.selection;
    final documentEnd = _documentController.document.length - 1;
    final index = (selection.isValid ? selection.start : documentEnd).clamp(
      0,
      documentEnd,
    );
    final end = (selection.isValid ? selection.end : index).clamp(
      index,
      documentEnd,
    );
    _documentController.replaceText(
      index,
      end - index,
      text,
      TextSelection.collapsed(offset: index + text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageBuilder = StashImageEmbedBuilder(_attachments);
    return PopScope(
      canPop: _saved || _sessionAttachmentIds.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_discardStagedAndPop());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('cancel-editor-button'),
            tooltip: 'Cancel',
            onPressed: _discardStagedAndPop,
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(widget.isEditing ? 'Edit item' : 'New item'),
          actions: [
            TextButton(
              key: const Key('save-item-button'),
              onPressed: _canSave && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 36),
                children: [
                  TextField(
                    key: const Key('title-field'),
                    controller: _titleController,
                    textCapitalization: TextCapitalization.sentences,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.4,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'What is this?',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      IconButton(
                        key: const Key('formatting-toggle'),
                        tooltip: 'Formatting',
                        onPressed: () => setState(
                          () => _formattingExpanded = !_formattingExpanded,
                        ),
                        icon: const Icon(Icons.text_format_rounded),
                      ),
                      IconButton(
                        key: const Key('insert-image-button'),
                        tooltip: 'Insert image',
                        onPressed: _insertPickedImage,
                        icon: const Icon(Icons.image_outlined),
                      ),
                      const Spacer(),
                      Text(
                        'Paste text or images',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                  if (_formattingExpanded)
                    QuillSimpleToolbar(
                      controller: _documentController,
                      config: const QuillSimpleToolbarConfig(
                        multiRowsDisplay: true,
                        showDividers: false,
                        showFontFamily: false,
                        showFontSize: false,
                        showSmallButton: false,
                        showUnderLineButton: false,
                        showStrikeThrough: false,
                        showInlineCode: false,
                        showColorButton: false,
                        showBackgroundColorButton: false,
                        showClearFormat: false,
                        showAlignmentButtons: false,
                        showHeaderStyle: false,
                        showListCheck: false,
                        showQuote: false,
                        showIndent: false,
                        showSearchButton: false,
                        showSubscript: false,
                        showSuperscript: false,
                        showDirection: false,
                      ),
                    ),
                  ImageDropRegion(
                    key: const Key('full-editor-image-drop-region'),
                    onImagesDropped: _importAndInsertImages,
                    onTextDropped: _handleDroppedText,
                    onError: _showDropError,
                    child: QuillEditor.basic(
                      key: const Key('content-field'),
                      controller: _documentController,
                      focusNode: _documentFocusNode,
                      config: QuillEditorConfig(
                        scrollable: false,
                        autoFocus: !widget.isEditing,
                        minHeight: 320,
                        placeholder: 'Start typing or paste anything…',
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        showCodeBlockLineNumbers: false,
                        embedBuilders: [imageBuilder],
                        // Flutter Quill 11.6 exposes this hook as experimental,
                        // but it is its supported boundary for overriding Ctrl+V.
                        // ignore: experimental_member_use
                        onKeyPressed: (event, _) {
                          final keyboard = HardwareKeyboard.instance;
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.keyV &&
                              (keyboard.isControlPressed ||
                                  keyboard.isMetaPressed)) {
                            unawaited(_paste());
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    key: const Key('details-section'),
                    initiallyExpanded: false,
                    onExpansionChanged: (value) =>
                        setState(() => _detailsExpanded = value),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    title: const Text('Details'),
                    trailing: Icon(
                      _detailsExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.chevron_right_rounded,
                    ),
                    children: [
                      TextField(
                        key: const Key('note-field'),
                        controller: _noteController,
                        minLines: 2,
                        maxLines: null,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(labelText: 'Note'),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const Key('tags-field'),
                        controller: _tagsController,
                        decoration: const InputDecoration(
                          labelText: 'Tags',
                          helperText: 'Separate tags with commas',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _optionalText(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _parseTags(String value) {
  final tags = <String>[];
  for (final part in value.split(',')) {
    final tag = part.trim();
    if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
  }
  return tags;
}
