import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: webRoot,
  plugins: [react()],
  server: { host: "0.0.0.0", port: 4173, strictPort: true },
  build: { outDir: path.resolve(webRoot, "../dist/web"), emptyOutDir: true },
});
