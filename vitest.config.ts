import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    testTimeout: 60_000,
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**'],
      exclude: [
        'src/cli/index.ts',
        'src/cli/resume.ts',
        'src/index.ts',
        'src/types/**',
      ],
      thresholds: {
        lines: 74,
        branches: 66,
        functions: 75,
      },
      reporter: ['text', 'lcov'],
    },
  },
})
