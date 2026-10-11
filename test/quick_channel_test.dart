import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stash/app/providers.dart';
import 'package:stash/core/database/app_database.dart';
import 'package:stash/features/channels/data/channel_repository.dart';
import 'package:stash/features/items/data/item_document_codec.dart';
import 'package:stash/features/items/data/item_repository.dart';
import 'package:stash/features/quick_channel/application/quick_channel_controller.dart';
import 'package:stash/features/quick_channel/data/quick_channel_configuration_repository.dart';
import 'package:stash/features/quick_channel/domain/quick_channel_configuration.dart';
import 'package:stash/features/quick_channel/presentation/quick_channel_palette.dart';
import 'package:stash/features/quick_stash/application/quick_stash_settings_controller.dart';
import 'package:stash/features/quick_stash/data/quick_stash_settings_repository.dart';
import 'package:stash/features/quick_stash/domain/quick_stash_settings.dart';
import 'package:stash/platform/global_hotkey/global_hotkey_service.dart';

import 'test_database.dart';

void main() {
  late AppDatabase db;
  late ChannelRepository channels;
  late MemoryQuickStashPreferenceStore store;
  late _FakeHotkeys hotkeys;
  late QuickStashSettingsController quickStashSettings;

  setUp(() async {
    db = createInMemoryDatabase();
    channels = ChannelRepository(db);
    store = MemoryQuickStashPreferenceStore();
    hotkeys = _FakeHotkeys();
    quickStashSettings = QuickStashSettingsController(
      repository: QuickStashSettingsRepository(store),
      hotkeys: hotkeys,
      onGlobalShortcut: () {},
    );
    await quickStashSettings.initialize();
  });

  tearDown(() => db.close());

  test('Quick Channel configuration persists device-local state', () async {
    final repository = QuickChannelConfigurationRepository(store);
    const configuration = QuickChannelConfiguration(
      channelId: 'memes',
      globalShortcut: QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9'),
    );

    await repository.save([configuration]);
    final restored = (await repository.load()).single;

    expect(restored.channelId, 'memes');
    expect(restored.globalShortcut, configuration.globalShortcut);
    expect(restored.quickPaletteEnabled, isTrue);
  });

  test(
    'configuration rejects Quick Stash and Channel shortcut conflicts',
    () async {
      final first = await channels.createRootChannel(
        id: 'first',
        name: 'First',
      );
      final second = await channels.createRootChannel(
        id: 'second',
        name: 'Second',
      );
      final opened = <String>[];
      final controller = QuickChannelController(
        repository: QuickChannelConfigurationRepository(store),
        channels: channels,
        hotkeys: hotkeys,
        quickStashSettings: quickStashSettings,
        onGlobalShortcut: opened.add,
      );
      await controller.initialize();
      const f9 = QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9');

      expect(
        await controller.configure(
          first.id,
          QuickStashShortcut.defaultShortcut,
        ),
        isFalse,
      );
      expect(
        controller.errorFor(first.id),
        'This shortcut is already used by Quick Stash.',
      );
      expect(await controller.configure(first.id, f9), isTrue);
      expect(await controller.configure(second.id, f9), isFalse);
      expect(
        controller.errorFor(second.id),
        'This shortcut is already used by another Channel.',
      );

      hotkeys.handlers[f9]!();
      expect(opened, [first.id]);
      expect(await quickStashSettings.changeShortcut(f9), isFalse);
      expect(
        quickStashSettings.shortcutError,
        'This shortcut is already used by a Quick Channel.',
      );

      const sameF9WithDifferentLabel = QuickStashShortcut(
        keyId: 0x00070042,
        keyLabel: 'Function 9',
      );
      expect(
        await controller.configure(first.id, sameF9WithDifferentLabel),
        isTrue,
      );
      expect(
        hotkeys.registered.where((value) => value.hasSameChord(f9)),
        hasLength(1),
      );
      await controller.disable(first.id);
      expect(hotkeys.unregistered.last, f9);
      controller.dispose();
    },
  );

  test('missing or tombstoned Channels are not registered on load', () async {
    final deleted = await channels.createRootChannel(
      id: 'deleted',
      name: 'Deleted',
    );
    await channels.softDeleteChannel(deleted.id);
    const f9 = QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9');
    await QuickChannelConfigurationRepository(store).save([
      const QuickChannelConfiguration(channelId: 'missing', globalShortcut: f9),
      const QuickChannelConfiguration(
        channelId: 'deleted',
        globalShortcut: QuickStashShortcut(keyId: 0x00070041, keyLabel: 'F8'),
      ),
    ]);
    hotkeys.registered.clear();
    final controller = QuickChannelController(
      repository: QuickChannelConfigurationRepository(store),
      channels: channels,
      hotkeys: hotkeys,
      quickStashSettings: quickStashSettings,
      onGlobalShortcut: (_) {},
    );

    await controller.initialize();

    expect(hotkeys.registered, isEmpty);
    expect(controller.errorFor('missing'), 'Channel is unavailable.');
    expect(controller.errorFor('deleted'), 'Channel is unavailable.');
    controller.dispose();
  });

  test(
    'deleting a configured Channel releases and disables its shortcut',
    () async {
      final channel = await channels.createRootChannel(
        id: 'temporary',
        name: 'Temporary',
      );
      const f9 = QuickStashShortcut(keyId: 0x00070042, keyLabel: 'F9');
      final repository = QuickChannelConfigurationRepository(store);
      final controller = QuickChannelController(
        repository: repository,
        channels: channels,
        hotkeys: hotkeys,
        quickStashSettings: quickStashSettings,
        onGlobalShortcut: (_) {},
      );
      await controller.initialize();
      expect(await controller.configure(channel.id, f9), isTrue);

      await channels.softDeleteChannel(channel.id);
      for (var attempt = 0; attempt < 20; attempt++) {
        if (controller.configurationFor(channel.id)?.quickPaletteEnabled ==
            false) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        controller.configurationFor(channel.id)?.quickPaletteEnabled,
        isFalse,
      );
      expect(hotkeys.unregistered, contains(f9));
      expect((await repository.load()).single.quickPaletteEnabled, isFalse);
      controller.dispose();
    },
  );

  testWidgets('palette loads an image grid and text fallback', (tester) async {
    final items = ItemRepository(db);
    final channel = await channels.createRootChannel(
      id: 'palette',
      name: 'Memes',
    );
    const attachmentId = 'palette-image';
    const codec = ItemDocumentCodec();
    final imageDocument = Document.fromJson([
      {
        'insert': BlockEmbed.custom(const StashImageEmbed(attachmentId))
            .toJson(),
      },
      {'insert': '\n'},
    ]);
    await items.createItem(
      id: 'image-item',
      channelId: channel.id,
      document: codec.snapshot(imageDocument),
    );
    await items.createItem(
      id: 'text-item',
      channelId: channel.id,
      title: 'Reply',
      content: 'Thanks!',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: QuickChannelPalette(channelId: 'palette'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('Memes'), findsOneWidget);
    expect(
      find.byKey(const Key('quick-channel-image-palette-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('quick-channel-text-text-item')),
      findsOneWidget,
    );
    expect(find.text('Thanks!'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
  });
}

class _FakeHotkeys implements GlobalHotkeyService {
  final List<QuickStashShortcut> registered = [];
  final List<QuickStashShortcut> unregistered = [];
  final Map<QuickStashShortcut, void Function()> handlers = {};

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> register(
    QuickStashShortcut shortcut,
    void Function() onPressed,
  ) async {
    registered.add(shortcut);
    handlers[shortcut] = onPressed;
  }

  @override
  Future<void> unregister(QuickStashShortcut shortcut) async {
    unregistered.add(shortcut);
    handlers.remove(shortcut);
  }
}
