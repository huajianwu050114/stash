# Sync Phase S2: Fake Remote

S2 makes the S1 protocol executable without selecting or contacting a real
backend. It is test infrastructure, not a user-facing sync product.

## Boundaries

- `SyncEngine` owns deterministic push/pull behavior.
- `SyncRemote` is the transport and authoritative-store abstraction.
- `FakeSyncRemote` is an in-memory, non-production implementation.
- `SyncLocalStore` owns bootstrap, payload creation, acknowledgements, cursor
  persistence, and applying remote state without invoking user mutation APIs.

There is no HTTP, authentication, background worker, timer, settings UI, or
production remote in S2. Sync happens only through an explicit `syncOnce()`.

## Remote state and revisions

The Fake Remote keys entities by `(entityType, entityId)`, so an Item, Channel,
and Attachment may share the same UUID without collision. Each entity stores a
portable full snapshot, operation/tombstone state, and monotonically increasing
revision. The first accepted mutation creates revision 1.

A push is accepted only when a new entity has `baseRevision == 0`, or an
existing entity has `baseRevision == remoteRevision`. A smaller base is a
conflict and a larger base is invalid. Neither case overwrites remote state.

Applied mutation IDs are remembered. Retrying the same mutation ID returns the
original revision without applying twice, appending another change, or
incrementing the revision.

## Change log and cursor

Every accepted mutation appends one global change-log entry containing its
cursor, entity key, revision, operation, mutation ID, and portable snapshot.
`pull(afterCursor)` returns only later entries. Each device persists its cursor
under `SyncMeta.pull_cursor` after each successfully handled entry.

If a newer remote change meets a pending local mutation, the engine returns a
structured `SyncConflict`, stops at that event, and leaves the cursor before
it. Later changes are temporarily blocked until a future phase resolves or
persists the conflict. S2 never uses timestamps or last-write-wins.

## Push lifecycle and ordering

Pending work is not ordered by creation time alone:

1. Channel upserts, parent before child.
2. Item upserts.
3. Attachment upserts.
4. Attachment deletes.
5. Item deletes.
6. Channel deletes, child before parent.

The Fake Remote independently rejects missing parents, missing Item Channels,
missing Attachment owners, and deletion of a Channel that still has active
children or Items.

On acceptance, the local entity revision and outbox acknowledgement are updated
in one SQLite transaction. A mutation-ID guard prevents a delayed response from
deleting a newer edit. If M2 replaces in-flight M1, accepting M1 updates the
entity revision and rebases M2 from M1's base to the accepted revision.

## Pull lifecycle

Pulled changes use a dedicated remote-application path and never call ordinary
user repositories, so no echo outbox entry is generated. A change already
represented by an equal or newer local revision is a harmless no-op, including
a device pulling its own push echo. Otherwise, with no pending local mutation,
the full portable snapshot replaces the local portable fields and records the
remote revision. Deletes remain tombstones; nothing is hard-purged.

## Initial bootstrap

Bootstrap explicitly queues revision-zero Items, Channels, and committed
Attachments that lack pending work. Active rows use `upsert`; tombstones use
`delete`. Active Attachment metadata is eligible only when its owning Item
document references it. Tombstoned Attachment metadata is considered previously
committed. Abandoned staged attachments are excluded. Repeated bootstrap calls
preserve existing mutation IDs and create no churn.

## Attachment blobs

Schema v5 adds nullable `attachments.sha256`. Existing rows migrate with null
and are hashed lazily when first uploaded. Hashing uses streaming SHA-256, and
the calculated byte count and checksum are persisted locally.

For an Attachment upsert, the device uploads the blob before committing its
metadata mutation. The Fake Remote verifies byte count and SHA-256 and rejects
metadata without a matching blob. The Fake Remote may retain a staged upload
after a later metadata rejection; it is not considered accepted entity state.

On pull, the receiving device derives a managed relative path from the
Attachment ID and a safe filename/MIME extension. No sender path is present in
the protocol. Bytes are streamed into a unique temporary file, then byte count
and SHA-256 are verified before publishing. A missing or corrupt blob leaves
the cursor before the Attachment change, does not apply metadata, does not
publish a partial file, and does not destroy an existing valid file.

Physical garbage collection remains deferred. Attachment deletes tombstone
metadata and may retain local and fake-remote bytes.

## Failure semantics

Push, pull, and blob failures are reported in `SyncCycleResult.errors`. Failed
pushes keep the exact outbox row and increment retry bookkeeping. Pull failures
do not advance the cursor. Blob failures retain local user data. There is no
automatic retry loop in S2.

## Sequences

```text
Device A SQLite        Fake Remote             Device B SQLite
      | create C/I/A        |                         |
      | syncOnce push ----> | revisions + log         |
      | <---- ack ----------|                         |
      X offline             |                         |
                            | <---- syncOnce pull -----|
                            | ----- snapshots/blob --->|
                            |                         | reconstruct C/I/A
```

```text
Device A (rev 1)       Fake Remote          Device B (rev 1)
 edit A, base 1             |                edit B, base 1
 push --------------------> | rev 2 = A
                            | <------------- push B
                            | reject conflict
                            |                 keep B + pending mutation
                            |                 cursor stops before A change
```

## Remaining for S3 and later

S3 may design a real remote implementation behind `SyncRemote`. It still needs
backend selection, authentication, secure configuration, durable server-side
storage, and production transport behavior. Later phases also need durable
conflict inbox/resolution UX, background scheduling, blob garbage collection,
and operational retry policy. `FakeSyncRemote` must never be treated as
production storage.
