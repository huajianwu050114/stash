import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import fixtures from "../../protocol/fixtures/sync-v1.json";

const token = "test-token-that-is-at-least-thirty-two-bytes";
const headers = {
  authorization: `Bearer ${token}`,
  "content-type": "application/json",
};

type MutationFixture = typeof fixtures.channel;

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM applied_mutations"),
    env.DB.prepare("DELETE FROM change_log"),
    env.DB.prepare("DELETE FROM remote_entities"),
  ]);
  const listed = await env.BLOBS.list();
  if (listed.objects.length)
    await env.BLOBS.delete(listed.objects.map((object) => object.key));
});

describe("Stash sync protocol v1", () => {
  it("protects every route with bearer auth", async () => {
    const unauthorized = await SELF.fetch("https://worker.test/v1/health");
    expect(unauthorized.status).toBe(401);
    expect(await unauthorized.json()).toMatchObject({
      protocolVersion: 1,
      error: "unauthorized",
    });
    const health = await request("/v1/health", { method: "GET" });
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ protocolVersion: 1, status: "ok" });
  });

  it("creates revision 1 and increments only from an equal base", async () => {
    expect(await push(fixtures.channel)).toMatchObject(fixtures.accepted);
    const update = clone(fixtures.channel, {
      mutationId: "mutation-channel-2",
      baseRevision: 1,
      payload: {
        ...fixtures.channel.payload,
        name: "Updated",
        serverRevision: 1,
      },
    });
    expect(await push(update)).toMatchObject({
      outcome: "accepted",
      remoteRevision: 2,
    });
  });

  it("returns conflict for stale and invalidDependency for future revisions", async () => {
    await push(fixtures.channel);
    expect(
      await push(
        clone(fixtures.channel, { mutationId: "stale", baseRevision: 0 }),
      ),
    ).toMatchObject(fixtures.conflict);
    expect(
      await push(
        clone(fixtures.channel, { mutationId: "future", baseRevision: 8 }),
      ),
    ).toMatchObject({ outcome: "invalidDependency", remoteRevision: 1 });
  });

  it("replays a mutation idempotently with its original revision and sequence", async () => {
    const first = await push(fixtures.channel);
    const retry = await push(fixtures.channel);
    expect(first).toMatchObject({ outcome: "accepted", remoteRevision: 1 });
    expect(retry).toMatchObject({
      outcome: "alreadyApplied",
      remoteRevision: 1,
      changeCursor: first.changeCursor,
    });
    expect(await count("change_log")).toBe(1);
  });

  it("paginates ordered changes with a stable cursor", async () => {
    await push(fixtures.channel);
    await push(fixtures.item);
    await push(
      clone(fixtures.item, {
        entityId: "item-2",
        mutationId: "mutation-item-2",
        payload: { ...fixtures.item.payload, id: "item-2" },
      }),
    );
    const first = await getJson("/v1/sync/pull?after=0&limit=2");
    expect(first).toMatchObject({ protocolVersion: 1, hasMore: true });
    expect(first.changes).toHaveLength(2);
    const firstChanges = first.changes as Array<{ cursor: number }>;
    expect(first.nextCursor).toBe(firstChanges[1]!.cursor);
    const second = await getJson(
      `/v1/sync/pull?after=${String(first.nextCursor)}&limit=2`,
    );
    expect(second).toMatchObject({ hasMore: false });
    expect(second.changes).toHaveLength(1);
    const secondChanges = second.changes as Array<{ cursor: number }>;
    expect(second.nextCursor).toBe(secondChanges[0]!.cursor);
  });

  it("rejects missing parent Channel, Item Channel, and Attachment Item dependencies", async () => {
    const child = clone(fixtures.channel, {
      entityId: "child",
      mutationId: "child",
      payload: {
        ...fixtures.channel.payload,
        id: "child",
        parentId: "missing",
      },
    });
    expect(await push(child)).toMatchObject({ outcome: "invalidDependency" });
    expect(await push(fixtures.item)).toMatchObject({
      outcome: "invalidDependency",
    });
    expect(await push(fixtures.attachment)).toMatchObject({
      outcome: "invalidDependency",
    });
  });

  it("rejects deleting a Channel with live dependents", async () => {
    await push(fixtures.channel);
    await push(fixtures.item);
    const deletion = clone(fixtures.channel, {
      mutationId: "delete-channel",
      baseRevision: 1,
      operation: "delete",
    });
    expect(await push(deletion)).toMatchObject({
      outcome: "invalidDependency",
    });
  });

  it("returns structured 4xx errors for malformed input and protocol mismatch", async () => {
    const malformed = await request("/v1/sync/push", {
      method: "POST",
      body: "{",
    });
    expect(malformed.status).toBe(400);
    expect(await malformed.json()).toMatchObject({ error: "malformedJson" });
    const mismatch = await request("/v1/sync/push", {
      method: "POST",
      body: JSON.stringify({ protocolVersion: 99, mutation: fixtures.channel }),
    });
    expect(mismatch.status).toBe(400);
    expect(await mismatch.json()).toMatchObject({ error: "protocolMismatch" });
  });

  it("commits entity, idempotency record, and change log atomically", async () => {
    await push(fixtures.channel);
    expect(await count("remote_entities")).toBe(1);
    expect(await count("applied_mutations")).toBe(1);
    expect(await count("change_log")).toBe(1);
    await push(
      clone(fixtures.channel, { mutationId: "stale-atomic", baseRevision: 0 }),
    );
    expect(await count("remote_entities")).toBe(1);
    expect(await count("applied_mutations")).toBe(1);
    expect(await count("change_log")).toBe(1);
  });

  it("uses immutable private R2 keys and authorizes direct upload/download", async () => {
    await push(fixtures.channel);
    await push(fixtures.item);
    const upload = await postJson("/v1/blobs/authorize-upload", {
      protocolVersion: 1,
      attachmentId: fixtures.attachment.entityId,
      byteSize: fixtures.attachment.payload.byteSize,
      sha256: fixtures.attachment.payload.sha256,
    });
    expect(upload.uploadUrl).toMatch(
      /^https:\/\/test-account\.r2\.cloudflarestorage\.com\//,
    );
    expect(upload.objectKey).toBe(
      `attachments/attachment-1/${fixtures.attachment.payload.sha256}`,
    );
    const key = upload.objectKey as string;
    await env.BLOBS.put(key, new Uint8Array([1, 2, 3, 4]), {
      customMetadata: {
        sha256: fixtures.attachment.payload.sha256,
        byteSize: "4",
      },
    });
    expect(await push(fixtures.attachment)).toMatchObject({
      outcome: "accepted",
    });
    const download = await postJson("/v1/blobs/authorize-download", {
      protocolVersion: 1,
      attachmentId: fixtures.attachment.entityId,
    });
    expect(download.downloadUrl).toMatch(
      /^https:\/\/test-account\.r2\.cloudflarestorage\.com\//,
    );
    expect(download).toMatchObject({
      byteSize: 4,
      sha256: fixtures.attachment.payload.sha256,
    });
  });

  it("rejects attachment metadata when staged blob integrity metadata differs", async () => {
    await push(fixtures.channel);
    await push(fixtures.item);
    const key = `attachments/attachment-1/${fixtures.attachment.payload.sha256}`;
    await env.BLOBS.put(key, new Uint8Array([1, 2, 3]), {
      customMetadata: {
        sha256: fixtures.attachment.payload.sha256,
        byteSize: "3",
      },
    });
    expect(await push(fixtures.attachment)).toMatchObject({
      outcome: "invalidDependency",
    });
  });

  it("does not let a stale attachment mutation replace committed blob metadata", async () => {
    await push(fixtures.channel);
    await push(fixtures.item);
    const originalKey = `attachments/attachment-1/${fixtures.attachment.payload.sha256}`;
    await env.BLOBS.put(originalKey, new Uint8Array([1, 2, 3, 4]), {
      customMetadata: {
        sha256: fixtures.attachment.payload.sha256,
        byteSize: "4",
      },
    });
    await push(fixtures.attachment);

    const divergentChecksum = "0".repeat(64);
    const divergentKey = `attachments/attachment-1/${divergentChecksum}`;
    await env.BLOBS.put(divergentKey, new Uint8Array([8, 9]), {
      customMetadata: { sha256: divergentChecksum, byteSize: "2" },
    });
    const stale = clone(fixtures.attachment, {
      mutationId: "stale-attachment",
      baseRevision: 0,
      payload: {
        ...fixtures.attachment.payload,
        byteSize: 2,
        sha256: divergentChecksum,
      },
    });
    expect(await push(stale)).toMatchObject({
      outcome: "conflict",
      remoteRevision: 1,
    });
    const download = await postJson("/v1/blobs/authorize-download", {
      protocolVersion: 1,
      attachmentId: fixtures.attachment.entityId,
    });
    expect(download.sha256).toBe(fixtures.attachment.payload.sha256);
    expect(download.byteSize).toBe(4);
  });
});

async function request(path: string, init: RequestInit): Promise<Response> {
  return SELF.fetch(`https://worker.test${path}`, {
    ...init,
    headers: { ...headers, ...init.headers },
  });
}

async function push(mutation: MutationFixture | Record<string, unknown>) {
  return postJson("/v1/sync/push", { protocolVersion: 1, mutation });
}

async function postJson(path: string, body: Record<string, unknown>) {
  const response = await request(path, {
    method: "POST",
    body: JSON.stringify(body),
  });
  return (await response.json()) as Record<string, unknown>;
}

async function getJson(path: string) {
  const response = await request(path, { method: "GET" });
  return (await response.json()) as Record<string, unknown>;
}

async function count(
  table: "remote_entities" | "applied_mutations" | "change_log",
) {
  const row = await env.DB.prepare(
    `SELECT COUNT(*) AS value FROM ${table}`,
  ).first<{ value: number }>();
  return row?.value ?? 0;
}

function clone<T extends Record<string, unknown>>(
  value: T,
  changes: Record<string, unknown>,
): T {
  return { ...value, ...changes } as T;
}
