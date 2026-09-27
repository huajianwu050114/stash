import 'package:flutter/foundation.dart';

/// A single stashed piece of information.
///
/// One unified model for every kind of content Stash holds: URLs, API keys,
/// tokens, commands, IP addresses, code snippets, plain notes. There is no
/// item type, category, or sensitivity concept at this layer — all content
/// shares the same storage and display semantics.
class Item {
  Item({
    required this.id,
    required this.content,
    this.title,
    this.note,
    List<String> tags = const [],
    this.isPinned = false,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  }) : tags = List.unmodifiable(tags);

  /// Client-generated UUID. Stable for the lifetime of the item.
  final String id;

  /// Optional short label.
  final String? title;

  /// The stashed content itself. Never null, never blank.
  final String content;

  /// Optional extra context kept separate from [content].
  final String? note;

  /// Free-form tags, kept in the order they were provided.
  final List<String> tags;

  /// Whether the item floats to the top of lists (used by later UI phases).
  final bool isPinned;

  final DateTime createdAt;

  final DateTime updatedAt;

  /// Tombstone timestamp. When set, the item is deleted from the user's
  /// perspective but its row stays in the database.
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  @override
  bool operator ==(Object other) =>
      other is Item &&
      other.id == id &&
      other.title == title &&
      other.content == content &&
      other.note == note &&
      listEquals(other.tags, tags) &&
      other.isPinned == isPinned &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    content,
    note,
    Object.hashAll(tags),
    isPinned,
    createdAt,
    updatedAt,
    deletedAt,
  );
}
