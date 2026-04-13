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
        lines: 65,
        branches: 60,
        functions: 70,
      },
      reporter: ['text', 'lcov'],
    },
  },
})
