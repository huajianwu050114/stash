# S3-LAN: persistent LAN relay and automatic sync foundation

## Why a relay

Stash does not assign revisions through symmetric leaderless peer-to-peer
consensus. A LAN relay is one synchronization authority while it is available,
just as `FakeSyncRemote` is an authority in tests and the Cloudflare Worker is
an authority for the cloud transport. `SyncEngine` continues to depend only on
`SyncRemote`.

This preserves the existing invariants: typed entity identity, monotonic server
revisions, optimistic `baseRevision` checks, idempotent `mutationId`, dependency
validation, an ordered global change cursor, and no timestamp last-write-wins.

```text
Windows working DB -> SyncEngine -> LanSyncRemote -> LAN Relay <- peer
```

The LAN transport is additive. `FakeSyncRemote`, `CloudflareSyncRemote`, the
Cloudflare Worker, D1 schema, and R2 design remain intact.

## Persistent relay state

DEV profile operational state is separate from `database/stash.sqlite`:

```text
<profile>/sync/lan-relay.sqlite
<profile>/sync/lan-relay-blobs/<attachment-id>/<sha256>
<profile>/sync/identity/device-id
<profile>/sync/identity/relay-id
<profile>/sync/identity/pairing-secret
```

The relay SQLite database contains current entities, applied mutation IDs, the
append-only change log, cursors/revisions, and blob metadata. Blob uploads are
streamed to staging, checked for byte length and SHA-256, and only then moved to
an immutable checksum-addressed path. Client `relativePath` values never enter
the wire payload or relay identity.

Normal Stash backup explicitly snapshots the working database and referenced
user attachments; it does not archive the `sync` operational directory. Relay
history, relay blobs, device identity, and pairing credentials are therefore
excluded.

## HTTP protocol and authentication

`LanRelayServer` uses `dart:io HttpServer` with a dynamically allocated or
explicitly configured port. It can bind LAN interfaces and exposes protocol v1:

- `GET /v1/health`
- `POST /v1/sync/push`
- `GET /v1/sync/pull`
- `PUT/GET /v1/blobs/<attachment-id>`

All data endpoints require a strong shared pairing credential. The credential
is generated from 32 random bytes, persisted device-locally, never advertised,
never logged, never included in payloads, and never committed. Device and relay
IDs are random UUIDs; they are diagnostic identity, not authentication.

Important: S3-LAN currently uses authenticated plaintext HTTP. Bearer
authentication prevents anonymous access but does not prevent another party on
the LAN from inspecting traffic. It is DEV/trusted-LAN only and is not enabled
for Stable. Production LAN sync requires persistent relay certificate identity,
TLS, and client certificate/fingerprint pinning.

## Discovery and trust

Discovery is behind `LanRelayDiscovery`. The current DEV implementation sends a
small UDP advertisement representing `_stash-sync._tcp`; it includes only
protocol version, relay ID, port, and an optional human label. It never includes
credentials, filenames, or content.

UDP is a deliberately isolated interim mechanism, not a claim of full mDNS /
DNS-SD support. A maintained cross-platform DNS-SD implementation can replace
it later without changing `SyncEngine` or `LanSyncRemote`.

Discovery does not establish trust:

```text
discover relay -> match previously paired relay ID -> authenticate -> sync
```

Unknown relay IDs are filtered and receive no Stash data. A paired relay's new
address/port is accepted only after its stable ID matches. Disappearance and
reappearance are availability events; reappearance wakes automatic sync.

Windows may show a firewall prompt for inbound LAN traffic. S3-LAN neither adds
nor weakens Windows Firewall rules. A future installer change needs separate,
explicit review and a narrowly scoped rule.

## Event-driven automatic sync

`AutoSyncCoordinator` decides when to invoke `syncOnce()` and contains no sync
algorithm logic. It supports:

- process start: immediate attempt;
- local outbox mutation: 500 ms debounce, then attempt;
- paired relay discovery/reappearance: immediate attempt;
- network availability notification: immediate attempt;
- app foreground: immediate attempt;
- five-minute periodic fallback while the process remains alive.

The primary mechanism is events, not polling. Local saves commit first and do
not wait for a network round-trip.

```text
local change -> local transaction -> short debounce -> sync -> LAN relay -> peer
```

```text
relay/peer offline -> pending remains -> relay returns -> immediate retry
```

Only one cycle may run for a profile/target. A trigger during a cycle records
one follow-up request rather than racing pull cursors. Unavailability uses a
bounded 1 s, 2 s, 5 s, 10 s, 30 s, then 2 min backoff. A meaningful event can
cancel the wait. Conflict stops automatic retries and preserves the pending
mutation.

The pure status model exposes `idle`, `syncing`, `upToDate`, `offline`,
`waitingForRelay`, `pending`, `conflict`, and `error`, together with pending
count, last successful time, and last error category. `upToDate` is emitted only
when no mutation remains pending.

## Windows lifecycle and DEV configuration

LAN sync is composed only for `AppProfile.dev` and only when
`STASH_LAN_ENABLED=1`. The coordinator belongs to the process lifecycle, not a
window. Closing the main window to the existing tray therefore leaves relay,
discovery, timers, and outbox observation running. Selecting Exit disposes sync
services before closing the working database.

Relay role example (PowerShell, current process only):

```powershell
$env:STASH_LAN_ENABLED='1'
$env:STASH_LAN_ROLE='relay'
cd D:\herunze\project\stash\.worktrees\sync-s3-lan-relay
.\tool\run_dev.ps1
```

Optional `STASH_LAN_PORT` selects a port; otherwise the OS allocates one.
`STASH_LAN_DEVICE_LABEL` is non-secret. A client DEV process requires the paired
relay ID, initial host/port, and a securely injected
`STASH_LAN_PAIRING_SECRET`. The first complete client configuration is persisted
under the profile's excluded operational identity directory; later discovery
updates only the matched relay's address, port, and last-seen time. Never put
the credential in source control or paste it into logs/chat.

Windows login autostart registration is deferred. The current phase starts
automatic sync with the Stash process and keeps it alive in the existing tray,
but never modifies the real user's startup registry or Startup folder.

## Verification

The isolated real-network smoke command uses temporary storage and loopback; it
does not open Stable or Dev user data:

```powershell
cd D:\herunze\project\stash\.worktrees\sync-s3-lan-relay
dart run tool\sync_lan_smoke.dart
```

The integration tests additionally use two independent file-backed client
SQLite databases, independent attachment roots, an actual HTTP socket, a
persistent relay SQLite database, and a persistent blob root. They cover relay
restart, later Device B reconstruction after A is disposed, conflicts, and a
lost-response idempotent retry.

## Deferred boundaries

- There is no Android implementation or phone requirement in S3-LAN.
- There is no production pairing UI or conflict-resolution UI.
- TLS/certificate pinning is required before production LAN use.
- Windows login autostart is not registered yet.
- UDP discovery is a replaceable DEV mechanism; production should use proper
  DNS-SD/mDNS after cross-platform validation.
- LAN-only delivery requires both peers to overlap with the relay online; the
  persistent relay lets A go offline after pushing while B arrives later.
- Simultaneous LAN and Cloud orchestration is deliberately deferred. The future
  policy is to prefer a reachable paired LAN relay and otherwise use a
  configured cloud relay. A mutation must not be independently pushed into two
  revision authorities until a deliberate multi-remote model exists.
