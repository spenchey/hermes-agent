import type { TestProjectConfiguration } from 'vitest/config'
import { defineConfig } from 'vitest/config'

const reactUi: TestProjectConfiguration = {
  extends: './vite.config.ts',
  test: {
    name: 'ui',
    environment: 'jsdom',
    setupFiles: ['./vitest.setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    globals: true,
    // jsdom + React transforms are CPU-heavy. Unbounded file workers oversubscribe
    // larger Macs and make otherwise fast tests miss their timeout while queued.
    // Eight keeps the full suite parallel without turning scheduling delay into a
    // false product failure; 60s still catches genuinely stuck UI tests.
    maxWorkers: 8,
    testTimeout: 60_000
  }
}

const electronNative: TestProjectConfiguration = {
  test: {
    name: 'electron',
    environment: 'node',
    // `e2e/**/*.unit.test.ts` is the e2e HELPERS, not the specs: plain node
    // modules that should be provable without booting Electron. Playwright
    // ignores the same pattern so they run in exactly one runner.
    include: ['electron/**/*.test.ts', 'scripts/**.test.{ts,mjs}', 'e2e/**/*.unit.test.ts'],
    // These use node:test and have dedicated npm scripts, not Vitest suites.
    exclude: ['scripts/run-short-session-hang-repro.test.mjs', 'scripts/tasks-scroll.test.mjs']
  }
}

export default defineConfig({
  test: {
    projects: [reactUi, electronNative]
  }
})
