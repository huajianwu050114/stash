import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: await readD1Migrations(
            path.join(import.meta.dirname, "migrations"),
          ),
          SYNC_BEARER_TOKEN: "test-token-that-is-at-least-thirty-two-bytes",
          R2_ACCOUNT_ID: "test-account",
          R2_BUCKET_NAME: "stash-sync-dev-blobs",
          R2_ACCESS_KEY_ID: "test-access-key",
          R2_SECRET_ACCESS_KEY: "test-secret-key",
        },
      },
    })),
  ],
  test: {
    setupFiles: ["./test/setup.ts"],
  },
});
