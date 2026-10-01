# Stash

Throw it in. Find it later.

Stash is a personal, cross-platform information drawer: one unified place to
stash URLs, API keys, tokens, commands, IP addresses, ports, Git/SSH notes,
config snippets, license info, temporary text—anything. It is **not** a
password manager, secure vault, wiki, or knowledge-base tool, and all content
shares the same storage and display semantics.

## Status: Phase 2.5 — Hierarchical Channels

Stash is a local-first personal drawer cabinet. Items may stay in the frictionless
Inbox or live directly inside arbitrarily nested Channels:

- Fast, content-first capture where only content is required
- Inbox (`channelId == null`), global Pinned, and hierarchical Channel views
- Root and child Channel creation, rename, safe move, and empty-only soft delete
- Responsive narrow navigation and a useful two-pane desktop/tablet browser
- Item detail with copy, edit, pin/unpin, and soft-delete actions
- Editing that can explicitly clear optional title and note values
- Simple comma-separated tag entry
- Responsive, restrained Material 3 presentation for mobile and desktop

The local SQLite database remains the working source of truth. UI screens
observe Drift-backed Riverpod streams and perform all mutations through
`ItemRepository`.

### Intentionally not included yet

- Search or full-text search
- Cloud sync, authentication, or networking
- File attachments
- AI features
- Trash UI
- Item types or channel metadata such as colors and icons

## Architecture

- `lib/features/items/domain/item.dart` — the unified Item model
- `lib/features/items/data/item_repository.dart` — repository boundary; all
  mutations are transactional (item row + outbox entry)
- `lib/features/channels/` — hierarchical Channel model, repository, and
  location picker; hierarchy safety lives below the UI
- `lib/features/items/presentation/` — home, create/edit, and detail screens
- `lib/core/database/` — Drift database, tables, migration strategy, and the
  tags JSON codec
- `lib/app/` — application theme and Riverpod providers

The local SQLite database is never treated as a cache. `serverRevision` lives
on the database row only, not on the domain `Item`.

## Running

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs  # after schema edits
flutter run
```

## Tests

```sh
flutter test
```

Tests run against in-memory SQLite databases and never touch the real
on-device database file.

## Database migrations

Current schema version: **2**. The additive v1→v2 migration creates `channels`
and adds nullable `items.channel_id`, leaving existing items in Inbox and
preserving sync tables. Schema snapshots are kept in `drift_schemas/`:

```sh
dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
```

Future schema changes must add stepwise, additive-only steps to the
`MigrationStrategy` in `lib/core/database/app_database.dart`. The database is
never recreated or dropped on upgrade.
