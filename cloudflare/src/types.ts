export const PROTOCOL_VERSION = 1;
export const MAX_JSON_BYTES = 256 * 1024;
export const MAX_BLOB_BYTES = 512 * 1024 * 1024;
export const MAX_PULL_LIMIT = 500;

export type EntityType = "item" | "channel" | "attachment";
export type Operation = "upsert" | "delete";

export interface Env {
  DB: D1Database;
  BLOBS: R2Bucket;
  SYNC_BEARER_TOKEN: string;
  R2_ACCOUNT_ID: string;
  R2_BUCKET_NAME: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
}

export interface Mutation {
  entityType: EntityType;
  entityId: string;
  mutationId: string;
  baseRevision: number;
  operation: Operation;
  payload: Record<string, unknown>;
}

export interface AppliedRow {
  mutation_id: string;
  entity_type: EntityType;
  entity_id: string;
  revision: number;
  change_sequence: number;
}

export interface EntityRow {
  entity_type: EntityType;
  entity_id: string;
  revision: number;
  operation: Operation;
  payload_json: string;
}
