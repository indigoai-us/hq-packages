// Builds the booking pages into dist/ (one JS bundle, one CSS file,
// index.html, embed.js and the favicon) for hq-deploy, which uploads dist/,
// api/ and db/migrations/ under a 100-file cap.
//
//   npm run build                                   # template components only
//   BOOKING_OVERRIDES_DIR=../../companies/acme/booking/overrides npm run build
//   npm run dev:ui                                  # Vite on :5173, /api proxied to npm run dev on :5180

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import { layerOverrides } from "./build/layer-overrides.ts";

const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  root: here,
  plugins: [layerOverrides({ componentsDir: join(here, "src", "components"), overridesDir: process.env.BOOKING_OVERRIDES_DIR || undefined })],
  esbuild: { jsx: "automatic", jsxImportSource: "preact" },
  resolve: {
    alias: { "@booking": join(here, "src") },
    // Overrides live outside the template, so make them use the template's Preact.
    dedupe: ["preact"],
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    target: "es2020",
    cssCodeSplit: false,
    assetsInlineLimit: 8192,
    modulePreload: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        entryFileNames: "assets/app-[hash].js",
        assetFileNames: "assets/app-[hash][extname]",
      },
    },
  },
  server: {
    port: 5173,
    proxy: { "/api": `http://127.0.0.1:${process.env.BOOKING_API_PORT ?? 5180}` },
  },
});
