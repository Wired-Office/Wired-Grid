import { defineConfig } from "vitest/config";

// Tauri serves the built files; the dev server runs on a fixed port it expects.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: { target: "es2021", outDir: "dist", chunkSizeWarningLimit: 2000 },
  test: { environment: "jsdom" },
});
