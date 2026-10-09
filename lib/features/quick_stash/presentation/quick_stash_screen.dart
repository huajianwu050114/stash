import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/providers.dart';
import '../../attachments/data/attachment_repository.dart';
import '../../attachments/data/image_import_sources.dart';
import '../../attachments/presentation/stash_image_embed_builder.dart';
import '../../items/data/item_document_codec.dart';
import '../domain/quick_stash_settings.dart';

class QuickStashScreen extends ConsumerStatefulWidget {
  const QuickStashScreen({super.key});

  @override
  ConsumerState<QuickStashScreen> createState() => _QuickStashScreenState();
}

class _QuickStashScreenState extends ConsumerState<QuickStashScreen> {
  static const _codec = ItemDocumentCodec();
  static final Uuid _uuid = Uuid();

  late String _itemId;
  late QuillController _documentController;
  late final FocusNode _documentFocusNode;
  late final ScrollController _documentScrollController;
  late final AttachmentRepository _attachments;
  late final ClipboardReaderGateway _clipboard;
  late final ImagePickerGateway _imagePicker;
  final Set<String> _sessionAttachmentIds = {};
  bool _saving = false;
  bool _discarding = false;
  bool _focusRestoreScheduled = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _attachments = ref.read(attachmentRepositoryProvider);
    _clipboard = ref.read(clipboardReaderProvider);
    _imagePicker = ref.read(imagePickerProvider);
    _documentFocusNode = FocusNode(debugLabel: 'quick-stash-document');
    _documentScrollController = ScrollController();
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _startBlankSession();
    _restoreEditorFocus();
  }

  void _startBlankSession() {
    _itemId = _uuid.v4();
    final document = _codec.fromPlainText('');
    _documentController = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    )..addListener(_documentChanged);
  }

  void _documentChanged() {
    if (mounted) setState(() => _message = null);
  }

  @override
  void dispose() {
    _documentController
      ..removeListener(_documentChanged)
      ..dispose();
    _documentFocusNode.dispose();
    _documentScrollController.dispose();
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    if (_sessionAttachmentIds.isNotEmpty) {
      unawaited(_cleanupStagedBestEffort());
    }
    super.dispose();
  }

  Future<void> _cleanupStagedBestEffort() async {
    try {
      await _attachments.cleanupStagedAttachments(_sessionAttachmentIds);
    } catch (_) {
      // AttachmentRepository's age-gated orphan cleanup is the fallback.
    }
  }

  ItemDocumentSnapshot get _snapshot =>
      _codec.snapshot(_documentController.document);

  Future<bool> _saveSession() async {
    if (_saving) return false;
    final snapshot = _snapshot;
    if (!snapshot.hasMeaningfulBody) {
      setState(() => _message = 'Add text or an image before saving.');
      return false;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await ref
          .read(itemRepositoryProvider)
          .createItem(id: _itemId, document: snapshot, channelId: null);
      final unused = _sessionAttachmentIds.difference(
        snapshot.imageAttachmentIds,
      );
      if (unused.isNotEmpty) {
        try {
          await _attachments.cleanupStagedAttachments(unused);
        } catch (_) {
          // The Item is already durable; orphan cleanup can retry later.
        }
      }
      _sessionAttachmentIds.clear();
      _resetSession();
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _message = 'Could not save this item.';
        });
      }
      return false;
    }
  }

  void _resetSession() {
    final previous = _documentController;
    previous.removeListener(_documentChanged);
    _startBlankSession();
    previous.dispose();
    if (mounted) {
      setState(() {
        _saving = false;
        _message = null;
      });
    }
  }

  Future<void> _submitAndHide() async {
    if (await _saveSession()) {
      await ref.read(quickStashControllerProvider).hideQuick();
    }
  }

  Future<void> _discardAndHide() async {
    if (_discarding || _saving) return;
    _discarding = true;
    final staged = Set<String>.of(_sessionAttachmentIds);
    _sessionAttachmentIds.clear();
    _resetSession();
    try {
      final oldDocumentUnmounted = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => oldDocumentUnmounted.complete(),
      );
      await oldDocumentUnmounted.future;
      await _attachments.cleanupStagedAttachments(staged);
      await ref.read(quickStashControllerProvider).hideQuick();
      if (mounted) setState(() => _discarding = false);
    } catch (_) {
      _sessionAttachmentIds.addAll(staged);
      if (mounted) {
        setState(() {
          _discarding = false;
          _message = 'Could not discard this capture.';
        });
      }
    }
  }

  Future<void> _expand() async {
    if (_snapshot.hasMeaningfulBody && !await _saveSession()) return;
    if (_sessionAttachmentIds.isNotEmpty) {
      await _attachments.cleanupStagedAttachments(_sessionAttachmentIds);
      _sessionAttachmentIds.clear();
      _resetSession();
    }
    await ref.read(quickStashControllerProvider).showFull();
  }

  Future<void> _insertPickedImage() async {
    final insertionSelection = _documentController.selection;
    try {
      final image = await _imagePicker.pickImage();
      if (image != null) {
        await _importAndInsert(image, insertionSelection: insertionSelection);
      }
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not insert this image.');
    } finally {
      _restoreEditorFocus(insertionSelection);
    }
  }

  Future<void> _paste() async {
    final insertionSelection = _documentController.selection;
    try {
      final image = await _clipboard.readImage();
      if (image != null) {
        await _importAndInsert(image, insertionSelection: insertionSelection);
        return;
      }
      final text = await _clipboard.readPlainText();
      if (text != null && text.isNotEmpty) {
        _insertText(text, insertionSelection: insertionSelection);
      }
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not paste from clipboard.');
    } finally {
      _restoreEditorFocus(insertionSelection);
    }
  }

  Future<void> _importAndInsert(
    ImportedImageData image, {
    TextSelection? insertionSelection,
  }) async {
    final attachment = await _attachments.importImage(
      itemId: _itemId,
      bytes: image.bytes,
      mimeType: image.mimeType,
      originalFileName: image.fileName,
    );
    _sessionAttachmentIds.add(attachment.id);
    final selection = _clampSelection(
      insertionSelection ?? _documentController.selection,
    );
    final index = selection.start;
    final length = selection.end - index;
    _documentController
      ..replaceText(
        index,
        length,
        BlockEmbed.custom(StashImageEmbed(attachment.id)),
        null,
      )
      ..moveCursorToPosition(index + 1);
    if (mounted) setState(() {});
    _restoreEditorFocus();
  }

  void _insertText(String text, {TextSelection? insertionSelection}) {
    final selection = _clampSelection(
      insertionSelection ?? _documentController.selection,
    );
    final index = selection.start;
    final length = selection.end - index;
    _documentController.replaceText(
      index,
      length,
      text,
      TextSelection.collapsed(offset: index + text.length),
    );
    _restoreEditorFocus();
  }

  TextSelection _clampSelection(TextSelection selection) {
    final maxOffset = math.max(0, _documentController.document.length - 1);
    int safeOffset(int offset) =>
        offset < 0 ? maxOffset : offset.clamp(0, maxOffset).toInt();
    return TextSelection(
      baseOffset: safeOffset(selection.baseOffset),
      extentOffset: safeOffset(selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  void _restoreEditorFocus([TextSelection? preferredSelection]) {
    if (!mounted || _focusRestoreScheduled) return;
    _focusRestoreScheduled = true;
    final targetController = _documentController;
    final requestedSelection = preferredSelection ?? targetController.selection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusRestoreScheduled = false;
      if (!mounted ||
          !identical(targetController, _documentController) ||
          !_documentFocusNode.canRequestFocus) {
        return;
      }
      final currentSelection = targetController.selection;
      final restoredSelection = _clampSelection(requestedSelection);
      if (restoredSelection != currentSelection) {
        targetController.updateSelection(restoredSelection, ChangeSource.local);
      }
      _documentFocusNode.requestFocus();
    });
  }

  void _afterCurrentKey(Future<void> Function() action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(action());
    });
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _afterCurrentKey(_discardAndHide);
      return true;
    }
    return false;
  }

  KeyEventResult _handleKey(KeyEvent event, QuickCaptureSubmitMode submitMode) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (keyboard.isControlPressed || keyboard.isMetaPressed)) {
      unawaited(_paste());
      return KeyEventResult.handled;
    }
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter) return KeyEventResult.ignored;
    if (keyboard.isShiftPressed) {
      _insertText('\n');
      return KeyEventResult.handled;
    }
    final shouldSubmit = switch (submitMode) {
      QuickCaptureSubmitMode.enter => true,
      QuickCaptureSubmitMode.controlEnter =>
        keyboard.isControlPressed || keyboard.isMetaPressed,
    };
    if (!shouldSubmit) {
      _insertText('\n');
      return KeyEventResult.handled;
    }
    _afterCurrentKey(_submitAndHide);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(quickStashSettingsControllerProvider);
    final imageBuilder = StashImageEmbedBuilder(_attachments);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final submitMode = settings.settings.submitMode;
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        'Stash',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const Key('quick-expand'),
                        tooltip: 'Expand to Full Stash',
                        onPressed: _saving ? null : _expand,
                        icon: const Icon(Icons.open_in_new_rounded),
                      ),
                      IconButton(
                        key: const Key('quick-close'),
                        tooltip: 'Discard and hide',
                        onPressed: _discarding || _saving
                            ? null
                            : _discardAndHide,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  Text(
                    'Throw it in…',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: QuillEditor.basic(
                          key: const Key('quick-content-field'),
                          controller: _documentController,
                          focusNode: _documentFocusNode,
                          scrollController: _documentScrollController,
                          config: QuillEditorConfig(
                            scrollable: false,
                            autoFocus: true,
                            minHeight: 300,
                            placeholder: 'Paste or type anything…',
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            showCodeBlockLineNumbers: false,
                            embedBuilders: [imageBuilder],
                            // ignore: experimental_member_use
                            onKeyPressed: (event, _) =>
                                _handleKey(event, submitMode),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _message!,
                      key: const Key('quick-message'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        key: const Key('quick-insert-image'),
                        tooltip: 'Insert image',
                        onPressed: _insertPickedImage,
                        icon: const Icon(Icons.image_outlined),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          submitMode == QuickCaptureSubmitMode.enter
                              ? 'Shift+Enter for newline'
                              : 'Enter for newline · Ctrl+Enter to save',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const Icon(Icons.inbox_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'Inbox',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: const Key('quick-save'),
                        tooltip: 'Save to Inbox',
                        onPressed: _saving ? null : _submitAndHide,
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_upward_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
