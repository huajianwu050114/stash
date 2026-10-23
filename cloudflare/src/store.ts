import type { AppliedRow, EntityRow, Env, Mutation } from "./types";
import { blobKey } from "./validation";

export type PushOutcome =
  | {
      outcome: "accepted" | "alreadyApplied";
      remoteRevision: number;
      changeCursor: number;
    }
  | {
      outcome: "conflict" | "invalidDependency";
      remoteRevision?: number;
      message?: string;
    };

export async function applyMutation(
  env: Env,
  mutation: Mutation,
): Promise<PushOutcome> {
  const existing = await appliedMutation(env.DB, mutation.mutationId);
  if (existing) return appliedResult(existing, "alreadyApplied");

  const dependencyError = await validateDependencies(env, mutation);
  if (dependencyError) {
    const current = await currentEntity(
      env.DB,
      mutation.entityType,
      mutation.entityId,
    );
    return {
      outcome: "invalidDependency",
      remoteRevision: current?.revision,
      message: dependencyError,
    };
  }

  const now = new Date().toISOString();
  const payload = JSON.stringify(mutation.payload);
  const nextRevision = mutation.baseRevision + 1;
  const dependencyGuard = atomicDependencyGuard(mutation);
  try {
    const results = await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO remote_entities
          (entity_type, entity_id, revision, operation, payload_json, last_mutation_id, updated_at)
         SELECT ?, ?, ?, ?, ?, ?, ?
         WHERE NOT EXISTS (SELECT 1 FROM applied_mutations WHERE mutation_id = ?)
           AND (
             (? = 0 AND NOT EXISTS (
               SELECT 1 FROM remote_entities WHERE entity_type = ? AND entity_id = ?
             ))
             OR EXISTS (
               SELECT 1 FROM remote_entities
               WHERE entity_type = ? AND entity_id = ? AND revision = ?
             )
           )
           AND (${dependencyGuard.sql})
         ON CONFLICT(entity_type, entity_id) DO UPDATE SET
           revision = excluded.revision,
           operation = excluded.operation,
           payload_json = excluded.payload_json,
           last_mutation_id = excluded.last_mutation_id,
           updated_at = excluded.updated_at
         WHERE remote_entities.revision = ?
           AND NOT EXISTS (SELECT 1 FROM applied_mutations WHERE mutation_id = ?)`,
      ).bind(
        mutation.entityType,
        mutation.entityId,
        nextRevision,
        mutation.operation,
        payload,
        mutation.mutationId,
        now,
        mutation.mutationId,
        mutation.baseRevision,
        mutation.entityType,
        mutation.entityId,
        mutation.entityType,
        mutation.entityId,
        mutation.baseRevision,
        ...dependencyGuard.bindings,
        mutation.baseRevision,
        mutation.mutationId,
      ),
      env.DB.prepare(
        `INSERT OR IGNORE INTO change_log
          (entity_type, entity_id, revision, operation, mutation_id, payload_json, created_at)
         SELECT entity_type, entity_id, revision, operation, last_mutation_id, payload_json, ?
         FROM remote_entities
         WHERE entity_type = ? AND entity_id = ? AND last_mutation_id = ?`,
      ).bind(now, mutation.entityType, mutation.entityId, mutation.mutationId),
      env.DB.prepare(
        `INSERT OR IGNORE INTO applied_mutations
          (mutation_id, entity_type, entity_id, revision, change_sequence, applied_at)
         SELECT mutation_id, entity_type, entity_id, revision, sequence, ?
         FROM change_log WHERE mutation_id = ?`,
      ).bind(now, mutation.mutationId),
      env.DB.prepare(
        `SELECT CASE
           WHEN EXISTS (SELECT 1 FROM applied_mutations WHERE mutation_id = ?) THEN 1
           ELSE json_extract('invalid', '$')
         END AS committed`,
      ).bind(mutation.mutationId),
    ]);
    const applied = await appliedMutation(env.DB, mutation.mutationId);
    if (!applied) throw new Error("atomic mutation assertion failed");
    const entityWriteCount = Number(results[0]?.meta.changes ?? 0);
    return appliedResult(
      applied,
      entityWriteCount === 0 ? "alreadyApplied" : "accepted",
    );
  } catch {
    const raced = await appliedMutation(env.DB, mutation.mutationId);
    if (raced) return appliedResult(raced, "alreadyApplied");
    const current = await currentEntity(
      env.DB,
      mutation.entityType,
      mutation.entityId,
    );
    if (current && current.revision > mutation.baseRevision) {
      return { outcome: "conflict", remoteRevision: current.revision };
    }
    return {
      outcome: "invalidDependency",
      remoteRevision: current?.revision,
      message: current
        ? "Mutation base revision is ahead of the remote entity."
        : "A new remote entity must use base revision 0.",
    };
  }
}

function atomicDependencyGuard(mutation: Mutation): {
  sql: string;
  bindings: unknown[];
} {
  if (mutation.operation === "delete") {
    if (mutation.entityType !== "channel")
      return { sql: "1 = 1", bindings: [] };
    return {
      sql: `NOT EXISTS (
        SELECT 1 FROM remote_entities
        WHERE operation != 'delete' AND (
          (entity_type = 'channel' AND json_extract(payload_json, '$.parentId') = ?)
          OR (entity_type = 'item' AND json_extract(payload_json, '$.channelId') = ?)
        )
      )`,
      bindings: [mutation.entityId, mutation.entityId],
    };
  }
  const dependency =
    mutation.entityType === "channel"
      ? mutation.payload.parentId
      : mutation.entityType === "item"
        ? mutation.payload.channelId
        : mutation.payload.itemId;
  if (dependency === null) return { sql: "1 = 1", bindings: [] };
  const dependencyType =
    mutation.entityType === "attachment" ? "item" : "channel";
  return {
    sql: `EXISTS (
      SELECT 1 FROM remote_entities
      WHERE entity_type = ? AND entity_id = ? AND operation != 'delete'
    )`,
    bindings: [dependencyType, dependency],
  };
}

export async function pullChanges(
  db: D1Database,
  after: number,
  limit: number,
) {
  const result = await db
    .prepare(
      `SELECT sequence, entity_type, entity_id, revision, operation, mutation_id, payload_json
       FROM change_log WHERE sequence > ? ORDER BY sequence ASC LIMIT ?`,
    )
    .bind(after, limit + 1)
    .all<{
      sequence: number;
      entity_type: string;
      entity_id: string;
      revision: number;
      operation: string;
      mutation_id: string;
      payload_json: string;
    }>();
  const hasMore = result.results.length > limit;
  const page = result.results.slice(0, limit);
  return {
    changes: page.map((row) => ({
      cursor: row.sequence,
      entityType: row.entity_type,
      entityId: row.entity_id,
      remoteRevision: row.revision,
      operation: row.operation,
      mutationId: row.mutation_id,
      payload: JSON.parse(row.payload_json) as Record<string, unknown>,
    })),
    nextCursor: page.at(-1)?.sequence ?? after,
    hasMore,
  };
}

export async function attachmentForDownload(
  db: D1Database,
  attachmentId: string,
) {
  const entity = await currentEntity(db, "attachment", attachmentId);
  if (!entity || entity.operation === "delete") return null;
  const payload = JSON.parse(entity.payload_json) as Record<string, unknown>;
  const sha256 = payload.sha256;
  const byteSize = payload.byteSize;
  if (typeof sha256 !== "string" || typeof byteSize !== "number") return null;
  return { sha256, byteSize, key: blobKey(attachmentId, sha256) };
}

async function validateDependencies(
  env: Env,
  mutation: Mutation,
): Promise<string | null> {
  if (mutation.operation === "delete") {
    if (mutation.entityType !== "channel") return null;
    const dependent = await env.DB.prepare(
      `SELECT entity_type FROM remote_entities
       WHERE operation != 'delete' AND (
         (entity_type = 'channel' AND json_extract(payload_json, '$.parentId') = ?)
         OR (entity_type = 'item' AND json_extract(payload_json, '$.channelId') = ?)
       ) LIMIT 1`,
    )
      .bind(mutation.entityId, mutation.entityId)
      .first<{ entity_type: string }>();
    return dependent ? "Channel still has an active dependent entity." : null;
  }

  if (mutation.entityType === "channel") {
    const parentId = mutation.payload.parentId;
    return parentId === null ||
      (await isLive(env.DB, "channel", parentId as string))
      ? null
      : "Parent Channel is missing or tombstoned.";
  }
  if (mutation.entityType === "item") {
    const channelId = mutation.payload.channelId;
    return channelId === null ||
      (await isLive(env.DB, "channel", channelId as string))
      ? null
      : "Referenced Channel is missing or tombstoned.";
  }
  const itemId = mutation.payload.itemId as string;
  if (!(await isLive(env.DB, "item", itemId)))
    return "Owning Item is missing or tombstoned.";
  const checksum = mutation.payload.sha256;
  const byteSize = mutation.payload.byteSize;
  if (typeof checksum !== "string" || typeof byteSize !== "number")
    return "Attachment blob metadata is missing.";
  const object = await env.BLOBS.head(blobKey(mutation.entityId, checksum));
  if (!object) return "Attachment blob is missing.";
  const metadata = object.customMetadata ?? {};
  if (
    object.size !== byteSize ||
    metadata.sha256 !== checksum ||
    metadata.byteSize !== String(byteSize)
  ) {
    return "Attachment blob integrity metadata does not match.";
  }
  return null;
}

async function isLive(
  db: D1Database,
  type: string,
  id: string,
): Promise<boolean> {
  const row = await db
    .prepare(
      "SELECT 1 AS live FROM remote_entities WHERE entity_type = ? AND entity_id = ? AND operation != 'delete'",
    )
    .bind(type, id)
    .first<{ live: number }>();
  return row?.live === 1;
}

async function appliedMutation(
  db: D1Database,
  id: string,
): Promise<AppliedRow | null> {
  return db
    .prepare(
      `SELECT mutation_id, entity_type, entity_id, revision, change_sequence
       FROM applied_mutations WHERE mutation_id = ?`,
    )
    .bind(id)
    .first<AppliedRow>();
}

async function currentEntity(
  db: D1Database,
  type: string,
  id: string,
): Promise<EntityRow | null> {
  return db
    .prepare(
      `SELECT entity_type, entity_id, revision, operation, payload_json
       FROM remote_entities WHERE entity_type = ? AND entity_id = ?`,
    )
    .bind(type, id)
    .first<EntityRow>();
}

function appliedResult(
  row: AppliedRow,
  outcome: "accepted" | "alreadyApplied",
): PushOutcome {
  return {
    outcome,
    remoteRevision: row.revision,
    changeCursor: row.change_sequence,
  };
}
