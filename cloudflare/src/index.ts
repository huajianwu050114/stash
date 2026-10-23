import { isAuthorized } from "./auth";
import { presign } from "./blobs";
import { json, problem } from "./response";
import { applyMutation, attachmentForDownload, pullChanges } from "./store";
import { MAX_PULL_LIMIT, type Env } from "./types";
import {
  blobKey,
  InputError,
  parseBlobDownload,
  parseBlobUpload,
  parseMutation,
  readJson,
} from "./validation";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (!(await isAuthorized(request, env.SYNC_BEARER_TOKEN))) {
        return problem(401, "unauthorized");
      }
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/v1/health") {
        return json({ status: "ok" });
      }
      if (request.method === "POST" && url.pathname === "/v1/sync/push") {
        const mutation = parseMutation(await readJson(request));
        return json(await applyMutation(env, mutation));
      }
      if (request.method === "GET" && url.pathname === "/v1/sync/pull") {
        const after = queryInteger(url, "after", 0, Number.MAX_SAFE_INTEGER, 0);
        const limit = queryInteger(url, "limit", 1, MAX_PULL_LIMIT, 100);
        return json(await pullChanges(env.DB, after, limit));
      }
      if (
        request.method === "POST" &&
        url.pathname === "/v1/blobs/authorize-upload"
      ) {
        const upload = parseBlobUpload(await readJson(request));
        const key = blobKey(upload.attachmentId, upload.sha256);
        const headers = {
          "content-type": "application/octet-stream",
          "x-amz-meta-sha256": upload.sha256,
          "x-amz-meta-byte-size": String(upload.byteSize),
        };
        const uploadUrl = await presign(env, key, "PUT", headers);
        return json({ uploadUrl, objectKey: key, expiresIn: 300, headers });
      }
      if (
        request.method === "POST" &&
        url.pathname === "/v1/blobs/authorize-download"
      ) {
        const id = parseBlobDownload(await readJson(request));
        const attachment = await attachmentForDownload(env.DB, id);
        if (!attachment || !(await env.BLOBS.head(attachment.key)))
          return problem(404, "blobNotFound");
        const downloadUrl = await presign(env, attachment.key, "GET");
        return json({
          downloadUrl,
          expiresIn: 300,
          byteSize: attachment.byteSize,
          sha256: attachment.sha256,
        });
      }
      return problem(404, "notFound");
    } catch (error) {
      if (error instanceof InputError) return problem(400, error.code);
      return problem(500, "serverError");
    }
  },
} satisfies ExportedHandler<Env>;

function queryInteger(
  url: URL,
  name: string,
  minimum: number,
  maximum: number,
  fallback: number,
): number {
  const raw = url.searchParams.get(name);
  if (raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new InputError("invalidQuery", `Invalid ${name}`);
  }
  return value;
}
