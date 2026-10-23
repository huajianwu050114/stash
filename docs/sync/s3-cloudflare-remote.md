# Sync Phase S3: Cloudflare remote v1

S3 replaces the in-memory-only remote with an opt-in, authenticated Cloudflare
implementation. It does not add background execution or sync UI. The default
application profile remains local-only until both `STASH_SYNC_BASE_URL` and
`STASH_SYNC_TOKEN` are supplied at build/run time.

## Architecture

- Flutter keeps the S2 `SyncRemote` boundary. `FakeSyncRemote` remains the
  deterministic test implementation and `CloudflareSyncRemote` is API v1.
- The Worker accepts small JSON metadata requests only.
- D1 stores current entity state, global mutation idempotency records, and an
  append-only cursor log.
- The private R2 bucket stores immutable attachment objects. The desktop client
  uploads and downloads directly through five-minute, operation- and key-scoped
  S3 presigned URLs. Large blob bodies never pass through the Worker.
- The integration smoke tool creates two temporary local databases and storage
  roots; it never opens Stable or Dev application profile data.

## D1 schema and atomic push

`remote_entities` is keyed by `(entity_type, entity_id)`. `applied_mutations` is
keyed globally by `mutation_id` and remembers the accepted revision and change
sequence. `change_log.sequence` is the monotonically increasing pull cursor.

Push checks idempotency first. A D1 `batch()` then performs a conditional UPSERT
whose predicate requires the exact base revision, appends the change, records
the mutation result, and executes a final commit assertion. D1 treats the batch
as one transaction: a failed assertion rolls back all three writes. Therefore
two concurrent writers cannot both advance the same entity from one base
revision, and entity state cannot exist without its idempotency and change-log
records.

Revision rules are exact:

- an absent entity accepts only base revision 0 and becomes revision 1;
- a base equal to the current revision advances by one;
- a lower base is a conflict;
- a higher base is an invalid dependency/revision;
- a repeated mutation ID returns its original revision and cursor without a
  second change.

Channel parents, Item Channels, Attachment owners, and Channel deletion
dependents are validated with prepared statements. Attachment metadata is
accepted only when the immutable R2 object exists and its size/checksum metadata
matches.

## API v1

All responses contain `protocolVersion: 1`. All routes require
`Authorization: Bearer <token>` and return `Cache-Control: no-store`.

- `GET /v1/health`
- `POST /v1/sync/push`
- `GET /v1/sync/pull?after=<cursor>&limit=<1..500>`
- `POST /v1/blobs/authorize-upload`
- `POST /v1/blobs/authorize-download`

Pull returns ordered metadata changes, `nextCursor`, and `hasMore`; no blob bytes
are included. The Dart engine follows pages with both a page-size limit and a
maximum-page safety bound. Malformed JSON, unknown protocol versions, invalid
fields, and invalid query bounds receive structured 4xx responses.

## R2 object lifecycle

The canonical key is `attachments/<attachment-id>/<sha256>`. Upload authorization
signs the exact PUT key plus content type, SHA-256 metadata, and byte-size
metadata. A client uploads immutable bytes first; only a later successful
Attachment mutation makes that checksum current. A stale mutation can leave an
unreferenced immutable object but cannot replace the committed object.

Download authorization derives the key from accepted D1 metadata. The S2 local
store stages the response, verifies byte length and SHA-256, then atomically
publishes it to the local attachment directory. Partial or corrupt downloads do
not alter local metadata.

## Authentication and configuration

`SYNC_BEARER_TOKEN`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` are Worker
secrets. They must never be placed in `wrangler.jsonc`, source, snapshots, logs,
or backups. The committed `.dev.vars.example` contains placeholders only;
`.dev.vars` and `.env*` are ignored.

Desktop configuration uses compile-time Dart defines:

```powershell
flutter run -d windows --dart-define=STASH_SYNC_BASE_URL=https://stash-sync-dev.<account>.workers.dev --dart-define=STASH_SYNC_TOKEN=<local-secret>
```

Production requires HTTPS. Only localhost HTTP is allowed for local testing.
The client never includes authorization headers on presigned R2 transfers and
does not include bearer values or user payloads in its errors.

## Local validation

```powershell
cd cloudflare
npm ci
npm run format
npm run lint
npm run typecheck
npm test
npx wrangler d1 migrations apply stash-sync-dev --local
npx wrangler dev --local
```

In another shell, use placeholder local values in an ignored `.dev.vars`. The
Worker tests use Cloudflare's Workers Vitest pool with local D1 and R2 bindings.
Cross-language, non-secret wire fixtures live in `protocol/fixtures/`.

## DEV deployment (never production)

Check tools and identity before creating anything:

```powershell
node --version
npm --version
npx wrangler --version
npx wrangler whoami
```

If `whoami` is not authenticated, stop and run `npx wrangler login`. After login,
create only the development resources:

```powershell
cd cloudflare
npx wrangler d1 create stash-sync-dev
npx wrangler r2 bucket create stash-sync-dev-blobs
```

Put the returned D1 development UUID into `wrangler.jsonc`, and replace only the
development account-ID placeholder. Create a bucket-scoped R2 S3 API token in
Cloudflare, then set all secrets interactively (values are not command
arguments):

```powershell
npx wrangler secret put SYNC_BEARER_TOKEN
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
npx wrangler d1 migrations apply stash-sync-dev --remote
npx wrangler deploy
```

Generate the bearer value with a cryptographically secure generator and at
least 32 random bytes. Do not print or persist it in the repository. Configure
the private bucket's CORS policy from `r2-cors.dev.json` if a browser client is
used; the Windows client does not require browser CORS.

Once deployed, run the isolated two-device smoke harness with process-local
environment variables:

```powershell
$env:STASH_SYNC_BASE_URL = 'https://stash-sync-dev.<account>.workers.dev'
$env:STASH_SYNC_TOKEN = '<local-secret>'
dart run tool/sync_cloudflare_smoke.dart
```

## DEV/production separation

This phase defines only `stash-sync-dev` and `stash-sync-dev-blobs`. There is no
production Wrangler environment, database ID, bucket, token, route, or deploy
command. A future production rollout must add a separately reviewed
configuration and separate resources; it must not rename or reuse DEV bindings.
The permanent desktop installer AppId and Stable profile are unrelated and are
not touched by S3.

## Security notes

- The R2 bucket remains private; presigned URLs are short-lived bearer grants.
- Authorization comparison hashes both token values before comparison.
- JSON requests, pull limits, blob sizes, and transfer timeouts are bounded.
- D1 runtime access uses prepared statements. Raw D1 CRUD is not exposed.
- Worker code does not log headers, tokens, mutation payloads, user text, object
  URLs, or R2 credentials.
- Current tables can gain an owner column and composite owner keys later without
  changing the public entity DTO. S3 intentionally remains single-user.
- Backups contain local database/attachments only. Remote URL/token values are
  compile-time or process configuration and are not written into profile data.

## S3 limitations

- Sync is manually invoked; no background scheduling, UI, login flow, or account
  management exists.
- Conflict detection is implemented, but conflict resolution remains manual.
- Presigned upload grants can leave unreferenced immutable R2 objects after a
  rejected/stale mutation; garbage collection is future work.
- There is no production Cloudflare environment or multi-user owner isolation.
- Large multipart uploads and resumable transfers are not implemented.
