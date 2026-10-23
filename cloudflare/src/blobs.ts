import { AwsClient } from "aws4fetch";

import type { Env } from "./types";

const GRANT_SECONDS = 300;

export async function presign(
  env: Env,
  key: string,
  method: "GET" | "PUT",
  headers: Record<string, string> = {},
): Promise<string> {
  if (
    !env.R2_ACCOUNT_ID ||
    !env.R2_BUCKET_NAME ||
    !env.R2_ACCESS_KEY_ID ||
    !env.R2_SECRET_ACCESS_KEY
  ) {
    throw new Error("R2 signing is not configured");
  }
  const client = new AwsClient({
    service: "s3",
    region: "auto",
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  });
  const encodedKey = key.split("/").map(encodeURIComponent).join("/");
  const url = new URL(
    `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${encodeURIComponent(env.R2_BUCKET_NAME)}/${encodedKey}`,
  );
  url.searchParams.set("X-Amz-Expires", String(GRANT_SECONDS));
  const signed = await client.sign(new Request(url, { method, headers }), {
    aws: { signQuery: true },
  });
  return signed.url;
}
