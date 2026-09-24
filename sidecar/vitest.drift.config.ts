import { defineConfig } from "vitest/config";

// LIVE drift tests against real YouTube endpoints — the innertube/yt-dlp
// parsing is reverse-engineered, so structure changes upstream break the app
// silently. Run via `npm run test:drift` / .github/workflows/drift.yml.
// Deliberately separate from the offline unit suite (`npm test`).
export default defineConfig({
  test: {
    include: ["drift/**/*.drift.ts"],
    testTimeout: 120_000,
    hookTimeout: 300_000,
    retry: 2,                 // absorbs network flakes; real drift fails all 3
    fileParallelism: false,   // one YouTube session at a time
  },
});
