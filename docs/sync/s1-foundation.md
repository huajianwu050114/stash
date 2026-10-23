# Sync Phase S1 foundation

S1 makes the local data model sync-ready. It does **not** synchronize data
between devices yet.

## Local-first topology

Each device keeps a complete SQLite working copy. Normal reads and writes use
that local database and continue to work offline. A future remote store is
synchronization infrastructure, not the primary database for the UI. The
SQLite database file itself is never replicated.

Every ordinary mutation commits the entity row and its durable outbox entry in
the same SQLite transaction. No network request is part of that transaction.

## Entities and portable identity

The syncable entity types and stable wire values are:

- `item`
- `channel`
- `attachment`

The durable identity of pending work is `(entityType, entityId)`. An Item and a
Channel may therefore use the same UUID without colliding. Operations use the
stable values `upsert` and `delete`; unknown wire values fail decoding instead
of falling back to another enum value.

## Generic outbox and revisions

There is at most one pending outbox row per entity. A new local edit:

- generates a new `mutationId`;
- refreshes the operation and creation time;
- resets `retryCount` to zero;
- preserves the first pending mutation's `baseRevision`.

`mutationId` is the future idempotency key. Retrying the same mutation ID must
be safe. A genuinely new local edit always gets a new ID. Acknowledgement and
retry bookkeeping are guarded by mutation ID so a delayed response cannot
erase or alter a newer local edit.

`serverRevision` is local sync metadata. Zero means the entity has never been
acknowledged by a remote. `baseRevision` is the server revision at which the
current unsynchronized sequence of local edits began.

The optimistic concurrency contract is:

- `remoteRevision == baseRevision`: eligible to accept and increment remotely;
- `remoteRevision > baseRevision`: stale local mutation, report a conflict;
- a previously recorded `mutationId`: already applied/idempotent outcome;
- impossible revision or missing dependency: invalid dependency/outcome.

S1 does not resolve conflicts and deliberately implements neither local-wins,
remote-wins, nor timestamp-based last-write-wins.

## Tombstones

Item and Channel deletion remain durable tombstones. Removing a committed
Attachment from an Item document sets `Attachment.deletedAt` and queues an
attachment delete. Its metadata and managed blob remain available for future
acknowledgement, conflict handling, recovery, and a later garbage collector.

Soft-deleting an Item does not tombstone its attachments: the retained Item
document still owns them and may be restored.

## Staged and committed attachments

Importing a file creates staged local metadata and a managed local blob. It
does not enqueue sync work. A staged attachment becomes committed only when a
successful Item create or edit references it. That Item transaction validates
that every referenced attachment exists, belongs to the exact Item ID, and is
not tombstoned, then queues the Item and newly committed Attachment upserts.

On edit, only added attachment IDs get upserts. Unchanged attachment IDs do not
churn the outbox. Removed committed IDs get tombstones and delete mutations.
Never-committed staged files may still be hard-deleted on cancel or orphan
cleanup.

Attachment payloads contain portable metadata only: ID, owning Item ID, MIME
type, original file name, byte size, timestamps, and revision metadata.
`relativePath`, absolute paths, AppData locations, temporary directories, and
blob bytes are device-local and are never part of the protocol payload.

## Dependencies and future application order

Future remote application must respect dependencies:

1. Channel upserts, with parents before children.
2. Item upserts, after referenced Channels are available.
3. Attachment metadata upserts, after owning Items are available.
4. Tombstones/deletes, applied using dependency-safe rules.

S1 defines this ordering but does not implement a network scheduler.

## SyncMeta

`SyncMeta` remains generic key/value storage. Future non-secret keys may include
`pull_cursor`, `device_id`, and `last_successful_sync`. Server URLs, auth tokens,
API keys, and other secrets do not belong there.

## Intentionally not implemented

S1 adds no HTTP or WebSocket client, backend selection, authentication, cloud
provider, blob transport, login UI, background worker, polling, push
notification, server settings, or cross-device synchronization. It does not
touch profile isolation, Stable data, or the 0.6.0 release tag.
