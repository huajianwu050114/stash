# Stash

Throw it in. Find it later.

Stash is a personal, cross-platform information drawer: one unified place to
stash URLs, API keys, tokens, commands, IP addresses, ports, Git/SSH notes,
config snippets, license info, temporary text — anything. It is **not** a
password manager, secure vault, wiki, or knowledge-base tool, and all content
shares the same storage and display semantics.

## Status: Phase 1 — Local foundation

This phase delivers a robust, local-first persistence foundation:

- One unified `Item` domain model — no per-type item concepts
- SQLite via [Drift](https://drift.simonbinder.eu/) with an explicit schema
  version and stepwise migration strategy
- Transactional writes: every item mutation commits atomically with its
  pending sync-outbox mutation
- Soft-delete tombstones — the repository never physically deletes item rows
- Durable `sync_outbox` / `sync_meta` tables as a migration-safe boundary for
  a future sync phase (coalescing: at most one pending mutation per item)
- Riverpod for lightweight dependency wiring (no code generation)
- A minimal Material 3 shell (placeholder screen only)

### Intentionally not included (yet)

- Full-text search
- Cloud sync (any backend, including Supabase)
- File attachments
- AI features
- Polished production UI

## Architecture

- `lib/features/items/domain/item.dart` — the unified Item model
- `lib/features/items/data/item_repository.dart` — repository boundary; all
  mutations are transactional (item row + outbox entry)
- `lib/core/database/` — Drift database, tables, migration strategy, and the
  tags JSON codec
- `lib/app/` — app shell and Riverpod providers

The local SQLite database is the source of truth — never a cache — and every
operation works fully offline. `serverRevision` lives on the database row
only, not on the domain `Item`.

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

Current schema version: **1**. The schema is exported to
`drift_schemas/drift_schema_v1.json`; regenerate it after any schema change:

```sh
dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
```

Future schema changes must add stepwise, additive-only steps to the
`MigrationStrategy` in `lib/core/database/app_database.dart`. The database is
never recreated or dropped on upgrade.
