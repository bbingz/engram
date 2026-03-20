import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { mkdirSync, writeFileSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { handleLintConfig, extractBacktickRefs, looksLikeFilePath, looksLikeNpmScript } from '../../src/tools/lint_config.js'

const TEST_DIR = join(tmpdir(), 'engram-lint-test-' + Date.now())

describe('lint_config', () => {
  beforeAll(() => {
    mkdirSync(join(TEST_DIR, '.claude'), { recursive: true })
    mkdirSync(join(TEST_DIR, 'src'), { recursive: true })

    // Create a real source file
    writeFileSync(join(TEST_DIR, 'src', 'index.ts'), 'export default {}', 'utf-8')

    // Create package.json with scripts
    writeFileSync(join(TEST_DIR, 'package.json'), JSON.stringify({
      scripts: { build: 'tsc', test: 'vitest', dev: 'tsx src/index.ts' },
    }), 'utf-8')

    // Create CLAUDE.md with mixed valid and invalid references
    writeFileSync(join(TEST_DIR, 'CLAUDE.md'), [
      '# Project Config',
      '',
      'Run `npm run build` to compile.',
      'Run `npm run deploy` to deploy.',
      'Edit `src/index.ts` for the entry point.',
      'See `src/nonexistent.ts` for details.',
      'The `Database` class handles persistence.',
    ].join('\n'), 'utf-8')
  })

  afterAll(() => {
    rmSync(TEST_DIR, { recursive: true, force: true })
  })

  describe('extractBacktickRefs', () => {
    it('extracts backtick-wrapped references', () => {
      const refs = extractBacktickRefs('Run `npm run build` and edit `src/foo.ts`')
      expect(refs).toContain('npm run build')
      expect(refs).toContain('src/foo.ts')
    })

    it('handles no backticks', () => {
      expect(extractBacktickRefs('no backticks here')).toEqual([])
    })

    it('handles empty backticks', () => {
      expect(extractBacktickRefs('empty ``')).toEqual([])
    })
  })

  describe('looksLikeFilePath', () => {
    it('recognizes file paths with extensions', () => {
      expect(looksLikeFilePath('src/index.ts')).toBe(true)
      expect(looksLikeFilePath('macos/Engram/Views/Page.swift')).toBe(true)
      expect(looksLikeFilePath('package.json')).toBe(true)
    })

    it('recognizes directory paths', () => {
      expect(looksLikeFilePath('src/')).toBe(true)
      expect(looksLikeFilePath('macos/Engram/')).toBe(true)
    })

    it('rejects non-path strings', () => {
      expect(looksLikeFilePath('npm run build')).toBe(false)
      expect(looksLikeFilePath('Database')).toBe(false)
      expect(looksLikeFilePath('true')).toBe(false)
    })

    it('rejects URLs', () => {
      expect(looksLikeFilePath('http://example.com/foo')).toBe(false)
      expect(looksLikeFilePath('https://github.com/user/repo')).toBe(false)
      expect(looksLikeFilePath('https://docs.example.com/guide.html')).toBe(false)
    })

    it('rejects scoped npm packages', () => {
      expect(looksLikeFilePath('@scope/pkg')).toBe(false)
      expect(looksLikeFilePath('@types/node')).toBe(false)
      expect(looksLikeFilePath('@hono/node-server')).toBe(false)
    })
  })

  describe('looksLikeNpmScript', () => {
    it('recognizes npm run commands', () => {
      expect(looksLikeNpmScript('npm run build')).toBe('build')
      expect(looksLikeNpmScript('npm test')).toBe('test')
      expect(looksLikeNpmScript('npm run dev')).toBe('dev')
    })

    it('returns null for non-npm commands', () => {
      expect(looksLikeNpmScript('git status')).toBeNull()
      expect(looksLikeNpmScript('src/index.ts')).toBeNull()
    })
  })

  describe('handleLintConfig', () => {
    it('finds broken file references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const fileErrors = result.issues.filter(i => i.message.includes('src/nonexistent.ts'))
      expect(fileErrors.length).toBe(1)
      expect(fileErrors[0].severity).toBe('error')
    })

    it('finds broken npm script references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const npmWarnings = result.issues.filter(i => i.message.includes('deploy'))
      expect(npmWarnings.length).toBe(1)
      expect(npmWarnings[0].severity).toBe('warning')
    })

    it('does not flag valid references', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      const validFile = result.issues.filter(i => i.message.includes('src/index.ts'))
      expect(validFile.length).toBe(0)
      const validScript = result.issues.filter(i => i.message.includes('npm run build') && i.message.includes('not found'))
      expect(validScript.length).toBe(0)
    })

    it('computes score correctly', async () => {
      const result = await handleLintConfig({ cwd: TEST_DIR })
      // 1 error (-10) + 1 warning (-3) = 87
      expect(result.score).toBe(87)
    })

    it('returns score of 100 for clean config', async () => {
      const cleanDir = join(tmpdir(), 'engram-lint-clean-' + Date.now())
      mkdirSync(join(cleanDir, 'src'), { recursive: true })
      writeFileSync(join(cleanDir, 'src', 'app.ts'), 'export {}', 'utf-8')
      writeFileSync(join(cleanDir, 'package.json'), JSON.stringify({ scripts: { build: 'tsc' } }), 'utf-8')
      writeFileSync(join(cleanDir, 'CLAUDE.md'), 'Run `npm run build` to compile.\nEdit `src/app.ts` for the entry.', 'utf-8')

      const result = await handleLintConfig({ cwd: cleanDir })
      expect(result.score).toBe(100)

      rmSync(cleanDir, { recursive: true, force: true })
    })

    it('ignores path traversal references that escape project root', async () => {
      const traversalDir = join(tmpdir(), 'engram-lint-traversal-' + Date.now())
      mkdirSync(traversalDir, { recursive: true })
      writeFileSync(join(traversalDir, 'CLAUDE.md'), [
        '# Config',
        'See `../../etc/passwd` for secrets.',
        'Check `../sibling/file.ts` too.',
      ].join('\n'), 'utf-8')

      const result = await handleLintConfig({ cwd: traversalDir })
      // Path traversal refs should be silently skipped, not reported as broken
      const traversalIssues = result.issues.filter(i =>
        i.message.includes('etc/passwd') || i.message.includes('sibling/file.ts')
      )
      expect(traversalIssues.length).toBe(0)
      expect(result.score).toBe(100)

      rmSync(traversalDir, { recursive: true, force: true })
    })

    it('returns empty issues when no config files exist', async () => {
      const emptyDir = join(tmpdir(), 'engram-lint-empty-' + Date.now())
      mkdirSync(emptyDir, { recursive: true })

      const result = await handleLintConfig({ cwd: emptyDir })
      expect(result.issues).toEqual([])
      expect(result.score).toBe(100)

      rmSync(emptyDir, { recursive: true, force: true })
    })
  })
})
