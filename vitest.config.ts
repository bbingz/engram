import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**'],
      exclude: ['src/cli/index.ts', 'src/cli/resume.ts'],
      thresholds: {
        lines: 75,
        branches: 65,
        functions: 70,
      },
      reporter: ['text', 'lcov'],
    },
  },
})
