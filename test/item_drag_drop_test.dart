import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/items/domain/item.dart';
import 'package:stash/features/items/presentation/item_drag_drop.dart';

void main() {
  final now = DateTime(2026);

  test('item drag keeps local move data and exports plain text', () {
    final item = Item(
      id: 'text-item',
      content: 'drag this text',
      channelId: 'source',
      createdAt: now,
      updatedAt: now,
    );

    final dragItem = const StashItemDragItemFactory().create(item);
    final payload = StashItemDragData.fromLocalData(dragItem.localData);

    expect(payload, isNotNull);
    expect(payload!.itemId, item.id);
    expect(payload.sourceChannelId, 'source');
    expect(dragItem.data, hasLength(1));
  });

  test('image-only whole-row drag never exports image data', () {
    final item = Item(
      id: 'image-item',
      content: '',
      documentJson: '{"image":true}',
      createdAt: now,
      updatedAt: now,
    );

    final dragItem = const StashItemDragItemFactory().create(item);

    expect(dragItem.data, isEmpty);
    expect(
      StashItemDragData.fromLocalData(dragItem.localData)?.itemId,
      item.id,
    );
  });

  test('Quick Channel text drag exposes one plain-text representation', () {
    final dragItem = const StashTextDragItemFactory().create('reply text');

    expect(dragItem.localData, isNull);
    expect(dragItem.data, hasLength(1));
  });

  test('invalid local data is ignored by internal move targets', () {
    expect(StashItemDragData.fromLocalData(null), isNull);
    expect(StashItemDragData.fromLocalData({'stashItemId': 1}), isNull);
  });
}
