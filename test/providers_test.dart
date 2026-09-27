import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/providers.dart';

import 'test_database.dart';

void main() {
  test('itemRepositoryProvider is wired to the database provider', () async {
    final db = createInMemoryDatabase();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final repository = container.read(itemRepositoryProvider);
    final item = await repository.createItem(content: 'wired through riverpod');
    expect(await repository.getItemById(item.id), isNotNull);
  });
}
