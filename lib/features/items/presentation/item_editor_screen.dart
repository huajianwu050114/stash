import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
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
  late final TextEditingController _contentController;
  late final TextEditingController _titleController;
  late final TextEditingController _noteController;
  late final TextEditingController _tagsController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _contentController = TextEditingController(text: item?.content ?? '');
    _titleController = TextEditingController(text: item?.title ?? '');
    _noteController = TextEditingController(text: item?.note ?? '');
    _tagsController = TextEditingController(text: item?.tags.join(', ') ?? '');
  }

  @override
  void dispose() {
    _contentController.dispose();
    _titleController.dispose();
    _noteController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  bool get _canSave => _contentController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave || _saving) return;
    setState(() => _saving = true);
    final repository = ref.read(itemRepositoryProvider);
    final content = _contentController.text;
    final title = _optionalText(_titleController.text);
    final note = _optionalText(_noteController.text);
    final tags = _parseTags(_tagsController.text);
    try {
      final original = widget.item;
      if (original == null) {
        await repository.createItem(
          content: content,
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
          content: content == original.content ? null : content,
          note: note == original.note
              ? const FieldUpdate.unchanged()
              : FieldUpdate.set(note),
          tags: listEquals(tags, original.tags) ? null : tags,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this item.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              children: [
                TextField(
                  key: const Key('content-field'),
                  controller: _contentController,
                  autofocus: !widget.isEditing,
                  minLines: 7,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Content',
                    hintText: 'Paste or type anything worth keeping',
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Optional details',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('title-field'),
                  controller: _titleController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('note-field'),
                  controller: _noteController,
                  minLines: 3,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Note'),
                ),
                const SizedBox(height: 16),
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
