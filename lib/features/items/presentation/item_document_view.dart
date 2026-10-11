import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../attachments/data/attachment_repository.dart';
import '../../attachments/presentation/stash_image_embed_builder.dart';
import '../data/item_document_codec.dart';

class ItemDocumentView extends StatefulWidget {
  const ItemDocumentView({
    super.key,
    required this.documentJson,
    required this.legacyText,
    required this.attachmentRepository,
  });

  final String? documentJson;
  final String legacyText;
  final AttachmentRepository attachmentRepository;

  @override
  State<ItemDocumentView> createState() => _ItemDocumentViewState();
}

class _ItemDocumentViewState extends State<ItemDocumentView> {
  static const _codec = ItemDocumentCodec();
  late QuillController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _makeController();
  }

  @override
  void didUpdateWidget(covariant ItemDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentJson != widget.documentJson ||
        oldWidget.legacyText != widget.legacyText) {
      _controller.dispose();
      _controller = _makeController();
    }
  }

  QuillController _makeController() => QuillController(
    document: _codec.decode(
      documentJson: widget.documentJson,
      legacyText: widget.legacyText,
    ),
    selection: const TextSelection.collapsed(offset: 0),
    readOnly: true,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QuillEditor.basic(
    key: const Key('document-view'),
    controller: _controller,
    config: QuillEditorConfig(
      scrollable: false,
      enableInteractiveSelection: true,
      padding: EdgeInsets.zero,
      showCodeBlockLineNumbers: false,
      embedBuilders: [
        StashImageEmbedBuilder(
          widget.attachmentRepository,
          maxWidth: 420,
          maxHeight: 340,
          cacheWidth: 840,
          expandWidth: false,
        ),
      ],
    ),
  );
}
