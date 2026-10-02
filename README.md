# Stash

Throw it in. Find it later.

Stash is a local-first personal document drawer for URLs, commands, network
details, config snippets, screenshots, and other information worth keeping. It
is not a password manager, wiki, or cloud service.

## Status: Phase 2.6 — Document Editor, Local Images, and Appearance

- A calm document editor with an optional title, rich body, compact formatting,
  inline images, and collapsed Note/Tags details
- Inbox, global Pinned, and arbitrarily nested Channels from Phase 2.5
- Structured document persistence with a searchable plain-text projection
- Local image import from the clipboard or a restrained file-picker fallback
- Persistent System, Light, and Dark appearance choices
- Responsive narrow navigation and two-pane desktop/tablet browsing

Search, cloud sync, authentication, AI, Trash UI, and arbitrary file
attachments are intentionally out of scope.

## Document persistence

`items.document_json` stores a versioned envelope whose current shape is:

```json
{
  "version": 1,
  "format": "quill-delta",
  "document": []
}
```

All serialization is isolated in `ItemDocumentCodec`. `items.content` remains
the non-null plain-text projection used by previews, copy, and future search.
The repository writes the serialized document, projection, and outbox mutation
in one database transaction. Legacy rows with a null structured document are
turned into an in-memory plain-text document when opened and are only upgraded
when edited.

An Item is valid when its body contains non-whitespace text or at least one
image. This means an image-only Item has an empty `content` projection but is
still valid; a title alone is not sufficient.

## Local attachments

Attachment metadata is stored in SQLite, while bytes live under the app support
directory using relative managed paths such as
`attachments/<attachment-id>.png`. Documents reference stable attachment UUIDs,
not absolute paths or base64 data.

New editors allocate their future Item UUID before saving. Image metadata can
therefore be staged under that ID without inserting an invalid blank Item.
Cancel cleans the editor session's staged IDs best-effort, and orphan cleanup
can remove old attachments whose future Item was never saved. The attachment
table intentionally has no Item foreign key because staged rows predate their
owner; existing and tombstoned Items both count as owners so sync tombstones do
not cause unsafe byte deletion.

## Architecture

- `lib/features/items/data/` — transactional Item repository and versioned
  document adapter
- `lib/features/items/presentation/` — home, editor, and structured detail view
- `lib/features/attachments/` — attachment model, managed storage, clipboard,
  picker, and Quill embed rendering
- `lib/features/channels/` — hierarchy repository, browser, and location picker
- `lib/core/database/` — Drift tables and additive migrations
- `lib/app/` — Riverpod providers, themes, and local appearance preference

SQLite and managed files are the working source of truth; there is no separate
authoritative in-memory store.

## Running

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Tests

```sh
flutter test
```

Tests use in-memory SQLite databases and temporary attachment directories; they
never touch the real app database.

## Database migrations

Current schema version: **3**.

- v1 → v2 creates Channels and adds nullable `items.channel_id`.
- v2 → v3 adds nullable `items.document_json` and the `attachments` table.

Both migrations are additive. Existing Items, Channels, outbox operations, and
sync metadata are preserved. Drift snapshots live in `drift_schemas/` and can
be refreshed with:

```sh
dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/
```
