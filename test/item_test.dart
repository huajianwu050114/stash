import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/items/domain/item.dart';

Item item({String id = 'id', String content = 'content', List<String>? tags}) =>
    Item(
      id: id,
      content: content,
      tags: tags ?? const [],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('Item', () {
    test(
      'defaults tags to empty, isPinned to false, optional fields to null',
      () {
        final value = item();
        expect(value.tags, isEmpty);
        expect(value.isPinned, isFalse);
        expect(value.title, isNull);
        expect(value.note, isNull);
        expect(value.deletedAt, isNull);
        expect(value.isDeleted, isFalse);
      },
    );

    test('keeps tags in the provided order', () {
      final value = Item(
        id: 'id',
        content: 'content',
        tags: ['b', 'a'],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(value.tags, ['b', 'a']);
    });

    test('tags list is defensive (unmodifiable)', () {
      final value = Item(
        id: 'id',
        content: 'content',
        tags: ['a'],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(() => value.tags.add('b'), throwsUnsupportedError);
    });

    test('equal items compare equal, differing content does not', () {
      expect(item(), item());
      expect(item(content: 'a') == item(content: 'b'), isFalse);
      expect(item(id: 'a') == item(id: 'b'), isFalse);
      expect(item(tags: const []) == item(tags: const ['x']), isFalse);
    });

    test('isDeleted reflects deletedAt', () {
      final deleted = Item(
        id: 'id',
        content: 'content',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        deletedAt: DateTime(2026, 2),
      );
      expect(deleted.isDeleted, isTrue);
    });
  });
}
