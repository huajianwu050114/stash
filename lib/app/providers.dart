import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../features/items/data/item_repository.dart';
import '../features/items/domain/item.dart';

/// The single on-device SQLite database. The database is the source of
/// truth; no additional in-memory copy of items is kept anywhere.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase.open();
  ref.onDispose(() => database.close());
  return database;
});

final itemRepositoryProvider = Provider<ItemRepository>(
  (ref) => ItemRepository(ref.watch(databaseProvider)),
);

/// Reactive view of all non-deleted items, newest-updated first.
final activeItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchActiveItems(),
);

/// Reactive view of one item for detail and edit flows.
final itemByIdProvider = StreamProvider.family<Item?, String>(
  (ref, id) => ref.watch(itemRepositoryProvider).watchItemById(id),
);
