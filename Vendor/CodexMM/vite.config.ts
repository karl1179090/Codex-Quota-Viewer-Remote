import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const apiPort = process.env.CODEX_SESSION_MANAGER_API_PORT ?? "4318";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 4173,
    proxy: {
      "/api": `http://127.0.0.1:${apiPort}`,
    },
  },
  build: {
    outDir: "dist/client",
    emptyOutDir: true,
  },
});
