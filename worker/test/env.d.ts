declare namespace Cloudflare {
  interface Env {
    // Test-only binding supplied by vitest.config.ts; never present in production.
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
