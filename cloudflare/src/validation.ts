import {
  MAX_BLOB_BYTES,
  MAX_JSON_BYTES,
  PROTOCOL_VERSION,
  type EntityType,
  type Mutation,
  type Operation,
} from "./types";

export class InputError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export async function readJson(
  request: Request,
): Promise<Record<string, unknown>> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_JSON_BYTES)
    throw new InputError("requestTooLarge", "Request too large");
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_JSON_BYTES) {
    throw new InputError("requestTooLarge", "Request too large");
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new InputError("malformedJson", "Malformed JSON");
  }
  if (!isRecord(value))
    throw new InputError("invalidRequest", "JSON object required");
  return value;
}

export function requireProtocol(body: Record<string, unknown>): void {
  if (body.protocolVersion !== PROTOCOL_VERSION) {
    throw new InputError("protocolMismatch", "Unsupported protocolVersion");
  }
}

export function parseMutation(body: Record<string, unknown>): Mutation {
  requireProtocol(body);
  const raw = body.mutation;
  if (!isRecord(raw))
    throw new InputError("invalidMutation", "mutation object required");
  const entityType = string(raw.entityType, "entityType") as EntityType;
  if (!(["item", "channel", "attachment"] as string[]).includes(entityType)) {
    throw new InputError("invalidEntityType", "Unknown entity type");
  }
  const operation = string(raw.operation, "operation") as Operation;
  if (!(["upsert", "delete"] as string[]).includes(operation)) {
    throw new InputError("invalidOperation", "Unknown operation");
  }
  const entityId = identifier(raw.entityId, "entityId");
  const mutationId = identifier(raw.mutationId, "mutationId");
  const baseRevision = integer(raw.baseRevision, "baseRevision", 0);
  if (!isRecord(raw.payload))
    throw new InputError("invalidPayload", "payload object required");
  if (raw.payload.id !== entityId) {
    throw new InputError("entityIdMismatch", "payload id must match entityId");
  }
  validatePayload(entityType, raw.payload);
  return {
    entityType,
    entityId,
    mutationId,
    baseRevision,
    operation,
    payload: raw.payload,
  };
}

export function parseBlobUpload(body: Record<string, unknown>): {
  attachmentId: string;
  sha256: string;
  byteSize: number;
} {
  requireProtocol(body);
  const attachmentId = identifier(body.attachmentId, "attachmentId");
  const sha256 = string(body.sha256, "sha256").toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sha256))
    throw new InputError("invalidChecksum", "Invalid SHA-256");
  const byteSize = integer(body.byteSize, "byteSize", 0);
  if (byteSize > MAX_BLOB_BYTES)
    throw new InputError("blobTooLarge", "Blob too large");
  return { attachmentId, sha256, byteSize };
}

export function parseBlobDownload(body: Record<string, unknown>): string {
  requireProtocol(body);
  return identifier(body.attachmentId, "attachmentId");
}

export function blobKey(attachmentId: string, sha256: string): string {
  return `attachments/${encodeURIComponent(attachmentId)}/${sha256}`;
}

function validatePayload(
  type: EntityType,
  payload: Record<string, unknown>,
): void {
  integer(payload.serverRevision, "serverRevision", 0);
  switch (type) {
    case "channel":
      nullableIdentifier(payload.parentId, "parentId");
      break;
    case "item":
      nullableIdentifier(payload.channelId, "channelId");
      break;
    case "attachment":
      identifier(payload.itemId, "itemId");
      if (payload.sha256 !== null) {
        const checksum = string(payload.sha256, "sha256");
        if (!/^[a-fA-F0-9]{64}$/.test(checksum))
          throw new InputError("invalidChecksum", "Invalid SHA-256");
      }
      if (payload.byteSize !== null) integer(payload.byteSize, "byteSize", 0);
      break;
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function string(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 1024) {
    throw new InputError("invalidField", `Invalid ${name}`);
  }
  return value;
}

function identifier(value: unknown, name: string): string {
  const result = string(value, name);
  if (
    result.length > 200 ||
    [...result].some((character) => character.charCodeAt(0) < 32)
  ) {
    throw new InputError("invalidField", `Invalid ${name}`);
  }
  return result;
}

function nullableIdentifier(value: unknown, name: string): string | null {
  return value === null ? null : identifier(value, name);
}

function integer(value: unknown, name: string, minimum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) {
    throw new InputError("invalidField", `Invalid ${name}`);
  }
  return value as number;
}
