import { defineConfig } from "vitest/config";

// The offline unit suite (`npm test`).
export default defineConfig({
  test: {
    // no test reads this machine's browsers
    setupFiles: ["src/test-setup.ts"],
  },
});
