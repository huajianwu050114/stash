# Stash

Throw it in. Find it later.

Stash is a personal, cross-platform information drawer: one unified place to
stash URLs, API keys, tokens, commands, IP addresses, ports, Git/SSH notes,
config snippets, license info, temporary text—anything. It is **not** a
password manager, secure vault, wiki, or knowledge-base tool, and all content
shares the same storage and display semantics.

## Status: Phase 2 — Capture and retrieval UX

This phase adds the complete local-only item loop on top of the Phase 1
persistence foundation:

- Fast, content-first capture where only content is required
- Reactive home with separate Pinned and Recent sections
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
- Categories, folders, or item types

## Architecture

- `lib/features/items/domain/item.dart` — the unified Item model
- `lib/features/items/data/item_repository.dart` — repository boundary; all
  mutations are transactional (item row + outbox entry)
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

Current schema version: **1**. Phase 2 does not change the schema. The schema
is exported to `drift_schemas/drift_schema_v1.json`; regenerate it after any
future schema change:

```sh
dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
```

Future schema changes must add stepwise, additive-only steps to the
`MigrationStrategy` in `lib/core/database/app_database.dart`. The database is
never recreated or dropped on upgrade.
