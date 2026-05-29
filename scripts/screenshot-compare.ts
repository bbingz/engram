/**
 * Screenshot comparison pipeline for Engram UI tests.
 *
 * Reads test-manifest.json from $SCREENSHOTS_DIR, compares each screenshot
 * against its baseline using three metrics (pixelmatch, SSIM, average hash),
 * writes diff PNGs and a comparison-report.json, then exits 0/1.
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import pixelmatch from 'pixelmatch';
import sharp from 'sharp';
import { ssim as computeSSIM } from 'ssim.js';
import {
  type AiTriage,
  createTriageProvider,
  needsTriage,
} from './ai-triage.js';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface Config {
  ssim_threshold: number;
  phash_max_distance: number;
  pixel_diff_max_percent: number;
  baselines_dir: string;
  ignore_regions: Record<
    string,
    { x: number; y: number; w: number; h: number }[]
  >;
}

interface ManifestEntry {
  name: string;
  screen?: string;
  test?: string;
  timestamp?: string;
  size?: { width: number; height: number };
  scale?: number;
}

interface Manifest {
  screenshots: ManifestEntry[];
  environment: Record<string, string>;
}

interface ComparisonMetrics {
  ssim: number;
  phash_distance: number;
  pixel_diff_count: number;
  pixel_diff_percent: number;
}

interface ComparisonResult {
  name: string;
  status: 'passed' | 'failed' | 'new' | 'size_mismatch';
  metrics: ComparisonMetrics;
  paths: { baseline: string; actual: string; diff: string | null };
  dimensions?: {
    actual: { width: number; height: number };
    baseline: { width: number; height: number };
    compared: { width: number; height: number };
    resized: boolean;
  };
  environment: Record<string, string>;
  ai_triage: AiTriage | null;
}

interface ComparisonReport {
  summary: {
    total: number;
    passed: number;
    failed: number;
    new: number;
    size_mismatch: number;
  };
  results: ComparisonResult[];
  thresholds: Pick<
    Config,
    'ssim_threshold' | 'phash_max_distance' | 'pixel_diff_max_percent'
  >;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Load config from project root. */
function loadConfig(): Config {
  const configPath = path.resolve('screenshot-compare.config.json');
  return JSON.parse(fs.readFileSync(configPath, 'utf-8'));
}

/** Zero out ignored regions in an RGBA buffer (set to transparent black). */
function applyIgnoreRegions(
  buf: Buffer,
  width: number,
  height: number,
  regions: { x: number; y: number; w: number; h: number }[],
): void {
  for (const r of regions) {
    const startY = Math.max(0, r.y);
    const endY = Math.min(height, r.y + r.h);
    const startX = Math.max(0, r.x);
    const endX = Math.min(width, r.x + r.w);
    for (let row = startY; row < endY; row++) {
      for (let col = startX; col < endX; col++) {
        const idx = (row * width + col) * 4;
        buf[idx] = 0;
        buf[idx + 1] = 0;
        buf[idx + 2] = 0;
        buf[idx + 3] = 0;
      }
    }
  }
}

function scaleIgnoreRegions(
  regions: { x: number; y: number; w: number; h: number }[],
  from: { width: number; height: number },
  to: { width: number; height: number },
): { x: number; y: number; w: number; h: number }[] {
  const xScale = to.width / from.width;
  const yScale = to.height / from.height;
  return regions.map((r) => ({
    x: Math.round(r.x * xScale),
    y: Math.round(r.y * yScale),
    w: Math.round(r.w * xScale),
    h: Math.round(r.h * yScale),
  }));
}

async function rgbaBufferAtSize(
  imgPath: string,
  width: number,
  height: number,
): Promise<Buffer> {
  return sharp(imgPath)
    .resize(width, height, { fit: 'fill' })
    .ensureAlpha()
    .raw()
    .toBuffer();
}

/**
 * Compute an average-hash (aHash) for a perceptual fingerprint.
 * Resize to 8x8 grayscale, threshold against the mean, produce a 64-bit hash.
 */
async function averageHash(imgPath: string): Promise<bigint> {
  const { data } = await sharp(imgPath)
    .resize(8, 8, { fit: 'fill' })
    .grayscale()
    .raw()
    .toBuffer({ resolveWithObject: true });

  // Compute mean
  let sum = 0;
  for (let i = 0; i < 64; i++) sum += data[i];
  const mean = sum / 64;

  // Build hash
  let hash = 0n;
  for (let i = 0; i < 64; i++) {
    if (data[i] >= mean) hash |= 1n << BigInt(63 - i);
  }
  return hash;
}

/** Hamming distance between two 64-bit hashes. */
function hammingDistance(a: bigint, b: bigint): number {
  let xor = a ^ b;
  let dist = 0;
  while (xor > 0n) {
    dist += Number(xor & 1n);
    xor >>= 1n;
  }
  return dist;
}

/**
 * Convert RGBA buffer to grayscale number[] for ssim.js Matrix format.
 * Uses ITU-R BT.601 luma coefficients.
 */
function rgbaToGrayscale(
  rgba: Buffer,
  width: number,
  height: number,
): number[] {
  const gray: number[] = new Array(width * height);
  for (let i = 0; i < width * height; i++) {
    const r = rgba[i * 4];
    const g = rgba[i * 4 + 1];
    const b = rgba[i * 4 + 2];
    gray[i] = Math.round(0.299 * r + 0.587 * g + 0.114 * b);
  }
  return gray;
}

// ---------------------------------------------------------------------------
// Main comparison
// ---------------------------------------------------------------------------

async function compareOne(
  entry: ManifestEntry,
  screenshotsDir: string,
  config: Config,
  environment: Record<string, string>,
): Promise<ComparisonResult> {
  const actualPath = path.join(screenshotsDir, `${entry.name}.png`);
  const baselinePath = path.join(config.baselines_dir, `${entry.name}.png`);
  const diffPath = path.join(screenshotsDir, `diff-${`${entry.name}.png`}`);

  const emptyMetrics: ComparisonMetrics = {
    ssim: 0,
    phash_distance: 64,
    pixel_diff_count: 0,
    pixel_diff_percent: 0,
  };

  // New baseline — no comparison possible
  if (!fs.existsSync(baselinePath)) {
    return {
      name: entry.name,
      status: 'new',
      metrics: emptyMetrics,
      paths: { baseline: baselinePath, actual: actualPath, diff: null },
      environment,
      ai_triage: null,
    };
  }

  // Load both images via sharp
  const actualMeta = await sharp(actualPath).metadata();
  const baselineMeta = await sharp(baselinePath).metadata();

  const aw = actualMeta.width!;
  const ah = actualMeta.height!;
  const bw = baselineMeta.width!;
  const bh = baselineMeta.height!;
  const actualDimensions = { width: aw, height: ah };
  const baselineDimensions = { width: bw, height: bh };
  let compareWidth = aw;
  let compareHeight = ah;
  const resized = aw !== bw || ah !== bh;

  if (resized) {
    const aspectDelta = Math.abs(aw / ah - bw / bh);
    if (aspectDelta > 0.01) {
      return {
        name: entry.name,
        status: 'size_mismatch',
        metrics: { ...emptyMetrics, pixel_diff_percent: 100 },
        paths: { baseline: baselinePath, actual: actualPath, diff: null },
        dimensions: {
          actual: actualDimensions,
          baseline: baselineDimensions,
          compared: { width: 0, height: 0 },
          resized: false,
        },
        environment,
        ai_triage: null,
      };
    }
    if (aw * ah > bw * bh) {
      compareWidth = bw;
      compareHeight = bh;
    }
  }

  // Extract raw RGBA, normalizing same-aspect screenshots across runner display sizes.
  const actualBuf = await rgbaBufferAtSize(
    actualPath,
    compareWidth,
    compareHeight,
  );
  const baselineBuf = await rgbaBufferAtSize(
    baselinePath,
    compareWidth,
    compareHeight,
  );

  // Apply ignore regions
  const ignoreRegions = scaleIgnoreRegions(
    config.ignore_regions[entry.name] || [],
    baselineDimensions,
    { width: compareWidth, height: compareHeight },
  );
  if (ignoreRegions.length) {
    applyIgnoreRegions(actualBuf, compareWidth, compareHeight, ignoreRegions);
    applyIgnoreRegions(baselineBuf, compareWidth, compareHeight, ignoreRegions);
  }

  // 1. Pixelmatch
  const diffBuf = Buffer.alloc(compareWidth * compareHeight * 4);
  const pixelDiffCount = pixelmatch(
    new Uint8Array(actualBuf.buffer, actualBuf.byteOffset, actualBuf.length),
    new Uint8Array(
      baselineBuf.buffer,
      baselineBuf.byteOffset,
      baselineBuf.length,
    ),
    new Uint8Array(diffBuf.buffer, diffBuf.byteOffset, diffBuf.length),
    compareWidth,
    compareHeight,
    { threshold: 0.1 },
  );
  const totalPixels = compareWidth * compareHeight;
  const pixelDiffPercent = (pixelDiffCount / totalPixels) * 100;

  // Write diff PNG
  await sharp(diffBuf, {
    raw: { width: compareWidth, height: compareHeight, channels: 4 },
  })
    .png()
    .toFile(diffPath);

  // 2. SSIM (grayscale Matrix)
  const grayActual = rgbaToGrayscale(actualBuf, compareWidth, compareHeight);
  const grayBaseline = rgbaToGrayscale(
    baselineBuf,
    compareWidth,
    compareHeight,
  );

  let ssimValue: number;
  // ssim.js needs images at least windowSize (default 11) in both dimensions
  if (compareWidth < 11 || compareHeight < 11) {
    // Too small for SSIM — fall back to pixel comparison only
    ssimValue = pixelDiffCount === 0 ? 1.0 : 0.0;
  } else {
    const ssimResult = computeSSIM(
      { data: grayActual, width: compareWidth, height: compareHeight },
      { data: grayBaseline, width: compareWidth, height: compareHeight },
      { windowSize: 11 } as any,
    ) as any;
    ssimValue = ssimResult.mssim;
  }

  // 3. Average hash (pHash fallback)
  const hashActual = await averageHash(actualPath);
  const hashBaseline = await averageHash(baselinePath);
  const phashDist = hammingDistance(hashActual, hashBaseline);

  const metrics: ComparisonMetrics = {
    ssim: Math.round(ssimValue * 10000) / 10000,
    phash_distance: phashDist,
    pixel_diff_count: pixelDiffCount,
    pixel_diff_percent: Math.round(pixelDiffPercent * 10000) / 10000,
  };

  // Determine pass/fail
  const passed =
    ssimValue >= config.ssim_threshold &&
    phashDist <= config.phash_max_distance &&
    pixelDiffPercent <= config.pixel_diff_max_percent;

  return {
    name: entry.name,
    status: passed ? 'passed' : 'failed',
    metrics,
    paths: { baseline: baselinePath, actual: actualPath, diff: diffPath },
    dimensions: {
      actual: actualDimensions,
      baseline: baselineDimensions,
      compared: { width: compareWidth, height: compareHeight },
      resized,
    },
    environment,
    ai_triage: null,
  };
}

async function main() {
  const config = loadConfig();
  // Check SCREENSHOTS_DIR env, then sandbox fallback, then /tmp
  let screenshotsDir = process.env.SCREENSHOTS_DIR || '';
  if (
    !screenshotsDir ||
    !fs.existsSync(path.join(screenshotsDir, 'test-manifest.json'))
  ) {
    const sandboxDir = path.join(
      os.homedir(),
      'Library/Containers/com.engram.EngramUITests.xctrunner/Data/tmp/engram-screenshots',
    );
    if (fs.existsSync(path.join(sandboxDir, 'test-manifest.json'))) {
      screenshotsDir = sandboxDir;
    } else if (!screenshotsDir) {
      screenshotsDir = '/tmp/engram-screenshots';
    }
  }

  const manifestPath = path.join(screenshotsDir, 'test-manifest.json');
  if (!fs.existsSync(manifestPath)) {
    console.log(
      `No test-manifest.json found at ${manifestPath}. No screenshots to compare.`,
    );
    process.exit(0);
  }
  console.log(`Using screenshots from: ${screenshotsDir}`);

  const manifest: Manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
  const entries = manifest.screenshots;

  const summary = {
    total: entries.length,
    passed: 0,
    failed: 0,
    new: 0,
    size_mismatch: 0,
  };
  const results: ComparisonResult[] = [];

  for (const entry of entries) {
    const result = await compareOne(
      entry,
      screenshotsDir,
      config,
      manifest.environment,
    );
    results.push(result);
    summary[result.status === 'passed' ? 'passed' : result.status]++;
  }

  // AI triage pass — serial, only for failed or near-threshold results
  const provider = createTriageProvider();
  if (provider) {
    const triageTargets = results.filter((r) => needsTriage(r));
    if (triageTargets.length > 0) {
      console.log(
        `\nAI Triage: ${triageTargets.length} screenshot(s) to analyze with ${provider.model}...`,
      );
      for (const result of triageTargets) {
        try {
          const baseline = fs.readFileSync(result.paths.baseline);
          const actual = fs.readFileSync(result.paths.actual);
          const diff = result.paths.diff
            ? fs.readFileSync(result.paths.diff)
            : null;
          result.ai_triage = await provider.analyze(
            { baseline, actual, diff },
            result.metrics,
          );
          const icon =
            result.ai_triage.verdict === 'acceptable'
              ? '✅'
              : result.ai_triage.verdict === 'regression'
                ? '❌'
                : '⚠️';
          console.log(
            `  ${icon} ${result.name}: ${result.ai_triage.verdict} (${result.ai_triage.confidence.toFixed(2)}) — ${result.ai_triage.reason}`,
          );
        } catch (err) {
          result.ai_triage = {
            verdict: 'uncertain',
            confidence: 0,
            reason: `triage error: ${String(err).slice(0, 200)}`,
            model: provider.model,
            duration_ms: 0,
          };
          console.log(
            `  ⚠️ ${result.name}: triage error — ${String(err).slice(0, 100)}`,
          );
        }
      }
    }
  }

  const report: ComparisonReport = {
    summary,
    results,
    thresholds: {
      ssim_threshold: config.ssim_threshold,
      phash_max_distance: config.phash_max_distance,
      pixel_diff_max_percent: config.pixel_diff_max_percent,
    },
  };

  const reportPath = path.join(screenshotsDir, 'comparison-report.json');
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

  // Print summary
  console.log('');
  console.log('Screenshot Comparison Report');
  console.log('============================');
  console.log(
    `Total: ${summary.total} | Passed: ${summary.passed} | Failed: ${summary.failed} | New: ${summary.new} | Size Mismatch: ${summary.size_mismatch}`,
  );
  console.log(`Report: ${reportPath}`);

  for (const r of results) {
    const icon =
      r.status === 'passed' ? 'OK' : r.status === 'new' ? 'NEW' : 'FAIL';
    const detail =
      r.status === 'new'
        ? '(no baseline)'
        : r.status === 'size_mismatch'
          ? '(size mismatch)'
          : `SSIM=${r.metrics.ssim} pHash=${r.metrics.phash_distance} diff=${r.metrics.pixel_diff_percent}%`;
    const dimensions =
      r.dimensions?.resized && r.status !== 'size_mismatch'
        ? ` normalized=${r.dimensions.actual.width}x${r.dimensions.actual.height}->${r.dimensions.compared.width}x${r.dimensions.compared.height}`
        : '';
    console.log(`  [${icon}] ${r.name} — ${detail}${dimensions}`);
  }

  if (summary.failed > 0 || summary.size_mismatch > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Screenshot comparison failed:', err);
  process.exit(1);
});
