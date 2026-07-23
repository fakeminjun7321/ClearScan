import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  testMatch: "web-drive.spec.ts",
  timeout: 25_000,
  use: {
    baseURL: "http://127.0.0.1:4196",
    viewport: { width: 1280, height: 900 },
  },
  webServer: [
    {
      command: "VITE_CLEARSCAN_API_URL=http://clearscan.test VITE_GOOGLE_CLIENT_ID=qa-client npm exec vite -- --config web/vite.config.ts --host 127.0.0.1 --port 4196",
      url: "http://127.0.0.1:4196",
      reuseExistingServer: false,
    },
    {
      command: "env -u VITE_CLEARSCAN_API_URL -u VITE_GOOGLE_CLIENT_ID npm exec vite -- --config web/vite.config.ts --host 127.0.0.1 --port 4197",
      url: "http://127.0.0.1:4197",
      reuseExistingServer: false,
    },
  ],
});
