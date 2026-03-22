import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    coverage: {
      provider: 'v8',
      include: ['src/**'],
      exclude: ['src/cli/index.ts', 'src/cli/resume.ts', 'src/daemon.ts'],
      thresholds: {
        lines: 60,
        branches: 50,
        functions: 55,
      },
      reporter: ['text', 'lcov'],
    },
  },
})
