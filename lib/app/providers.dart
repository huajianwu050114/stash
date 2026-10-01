import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../features/channels/data/channel_repository.dart';
import '../features/channels/domain/channel.dart';
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

final channelRepositoryProvider = Provider<ChannelRepository>(
  (ref) => ChannelRepository(ref.watch(databaseProvider)),
);

/// Reactive view of all non-deleted items, newest-updated first.
final activeItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchActiveItems(),
);

final inboxItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchInboxItems(),
);

final pinnedItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(itemRepositoryProvider).watchPinnedItems(),
);

final channelItemsProvider = StreamProvider.family<List<Item>, String>(
  (ref, id) => ref.watch(itemRepositoryProvider).watchItemsInChannel(id),
);

final rootChannelsProvider = StreamProvider<List<Channel>>(
  (ref) => ref.watch(channelRepositoryProvider).watchRootChannels(),
);

final childChannelsProvider = StreamProvider.family<List<Channel>, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).watchChildChannels(id),
);

final channelByIdProvider = StreamProvider.family<Channel?, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).watchChannelById(id),
);

final channelBreadcrumbsProvider = FutureProvider.family<List<Channel>, String>(
  (ref, id) => ref.watch(channelRepositoryProvider).getBreadcrumbs(id),
);

/// Reactive view of one item for detail and edit flows.
final itemByIdProvider = StreamProvider.family<Item?, String>(
  (ref, id) => ref.watch(itemRepositoryProvider).watchItemById(id),
);
