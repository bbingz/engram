/**
 * Adapter format-drift check (mirror row 23).
 * Fingerprints newest real vendor sessions and diffs against committed baselines.
 * See docs/adapter-format-drift-design-2026-07.md.
 */
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  type Stats,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { parse as parseYaml } from 'yaml';

export const OBSERVE_FILES = 30;
export const BASELINE_FILES = 200;
export const HEAD_LINES = 200;
export const TAIL_LINES = 800;
export const FRESHNESS_WINDOW_DAYS = 14;
export const DOC_STALENESS_DAYS = 90;
export const PREVALENCE_THRESHOLD = 0.5;
export const BASELINE_SCHEMA_VERSION = 1;

export type BucketAgg = {
  files: number;
  records: number;
  keys: Record<string, number>;
};

export type Fingerprint = {
  format: string;
  corpusFiles: number;
  corpusNewestMtimeUtc: string | null;
  vendorVersions: { min: string | null; max: string | null };
  buckets: Record<string, BucketAgg>;
  parseErrors: number;
  rootsPresent: number;
  globMatches: number;
};

export type BaselineFile = {
  schemaVersion: number;
  format: string;
  sources: string[];
  acceptedAtUtc: string;
  acceptedNote: string;
  vendorVersions: { min: string | null; max: string | null };
  corpusFiles: number;
  corpusNewestMtimeUtc: string | null;
  sampling: {
    headLines: number;
    tailLines: number;
    excludeGlobs: string[];
  };
  digest: string;
  buckets: Record<string, BucketAgg>;
  note: string;
};

export type FormatMatrixEntry = {
  sources: string[];
  roots: string[];
  glob: string;
  excludeGlobs: string[];
  requiredTypes: string[];
  versionField: string;
  max_verified_version: string | null;
  last_checked_utc: string;
  monitored: boolean;
  docs: string[];
};

export type SupportMatrix = {
  schemaVersion: number;
  formats: Record<string, FormatMatrixEntry>;
};

export type FreshnessState =
  | { state: 'ok' }
  | { state: 'no_local_sample'; reason: string }
  | { state: 'blocked_stale_sample'; reason: string }
  | { state: 'blocked_stale_baseline'; reason: string }
  | { state: 'blocked_required_type_absent'; reason: string }
  | { state: 'stale_local_toolchain'; reason: string };

export type DiffFinding = {
  kind: 'DRIFT' | 'note' | 'info';
  line: string;
};

const USER_PATH_KEY_RE = /[/\\]|\.(md|ts|swift|json|jsonl)$/i;

export function expandHome(path: string, home = homedir()): string {
  if (path === '~') return home;
  if (path.startsWith('~/')) return join(home, path.slice(2));
  return path;
}

/** Compare dotted versions with optional prerelease. Returns -1 | 0 | 1. */
export function compareVersions(a: string, b: string): -1 | 0 | 1 {
  const parse = (raw: string) => {
    const trimmed = raw.trim();
    if (!trimmed) throw new Error('empty');
    const dash = trimmed.indexOf('-');
    const core = dash >= 0 ? trimmed.slice(0, dash) : trimmed;
    const pre = dash >= 0 ? trimmed.slice(dash + 1) : null;
    const coreParts = core.split('.').map((seg) => {
      if (!/^\d+$/.test(seg))
        throw new Error(`unparseable core segment "${seg}"`);
      return Number(seg);
    });
    const preParts =
      pre === null
        ? null
        : pre.split('.').map((seg) => {
            if (/^\d+$/.test(seg))
              return { kind: 'num' as const, n: Number(seg) };
            if (!/^[0-9A-Za-z.-]+$/.test(seg))
              throw new Error(`unparseable pre "${seg}"`);
            return { kind: 'str' as const, s: seg };
          });
    return { coreParts, preParts };
  };

  let pa: ReturnType<typeof parse>;
  let pb: ReturnType<typeof parse>;
  try {
    pa = parse(a);
    pb = parse(b);
  } catch {
    throw new Error(`unparseable version "${a}" or "${b}"`);
  }

  const maxCore = Math.max(pa.coreParts.length, pb.coreParts.length);
  for (let i = 0; i < maxCore; i++) {
    const x = pa.coreParts[i] ?? 0;
    const y = pb.coreParts[i] ?? 0;
    if (x < y) return -1;
    if (x > y) return 1;
  }

  if (pa.preParts === null && pb.preParts === null) return 0;
  if (pa.preParts === null) return 1; // release > prerelease
  if (pb.preParts === null) return -1;

  const maxPre = Math.max(pa.preParts.length, pb.preParts.length);
  for (let i = 0; i < maxPre; i++) {
    const x = pa.preParts[i];
    const y = pb.preParts[i];
    if (!x && y) return -1;
    if (x && !y) return 1;
    if (!x || !y) continue;
    if (x.kind === 'num' && y.kind === 'num') {
      if (x.n < y.n) return -1;
      if (x.n > y.n) return 1;
    } else if (x.kind === 'num' && y.kind === 'str') {
      return -1;
    } else if (x.kind === 'str' && y.kind === 'num') {
      return 1;
    } else if (x.kind === 'str' && y.kind === 'str') {
      if (x.s < y.s) return -1;
      if (x.s > y.s) return 1;
    }
  }
  return 0;
}

export function loadSupportMatrix(repoRoot: string): SupportMatrix {
  const path = join(repoRoot, 'docs/session-formats/support-matrix.yml');
  const raw = parseYaml(readFileSync(path, 'utf8')) as SupportMatrix;
  if (!raw?.formats) throw new Error(`invalid support matrix at ${path}`);
  return raw;
}

export function baselinePath(repoRoot: string, format: string): string {
  return join(
    repoRoot,
    'docs/session-formats/baselines',
    `${format}.baseline.json`,
  );
}

export function loadBaseline(
  repoRoot: string,
  format: string,
): BaselineFile | null {
  const path = baselinePath(repoRoot, format);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf8')) as BaselineFile;
}

function matchGlob(path: string, pattern: string): boolean {
  // Minimal ** / * matcher sufficient for matrix globs.
  const escaped = pattern
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*\*/g, '§§')
    .replace(/\*/g, '[^/]*')
    .replace(/§§/g, '.*');
  return new RegExp(`^${escaped}$`).test(path.replaceAll('\\', '/'));
}

/** True when path or basename matches the matrix entry.glob (single predicate). */
export function matchesFormatGlob(
  filePath: string,
  root: string,
  glob: string,
): boolean {
  if (glob === '**/*') return true;
  const normalized = filePath.replaceAll('\\', '/');
  const rel = relative(root, filePath).replaceAll('\\', '/');
  const base = filePath.split(/[/\\]/).pop() ?? filePath;
  return (
    matchGlob(rel, glob) || matchGlob(base, glob) || matchGlob(normalized, glob)
  );
}

function isExcluded(relPath: string, excludeGlobs: string[]): boolean {
  return excludeGlobs.some((g) => matchGlob(relPath.replaceAll('\\', '/'), g));
}

function walkFiles(root: string, excludeGlobs: string[]): string[] {
  const out: string[] = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop()!;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of entries) {
      const full = join(dir, name);
      let st: Stats;
      try {
        st = statSync(full);
      } catch {
        continue;
      }
      const rel = relative(root, full).replaceAll('\\', '/');
      if (isExcluded(rel, excludeGlobs) || isExcluded(name, excludeGlobs))
        continue;
      if (st.isDirectory()) {
        stack.push(full);
      } else if (st.isFile()) {
        out.push(full);
      }
    }
  }
  return out;
}

function sampleLines(path: string): { lines: string[]; parseErrors: number } {
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return { lines: [], parseErrors: 1 };
  }
  const nonBlank = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  if (nonBlank.length <= HEAD_LINES + TAIL_LINES) {
    return { lines: nonBlank, parseErrors: 0 };
  }
  return {
    lines: [
      ...nonBlank.slice(0, HEAD_LINES),
      ...nonBlank.slice(nonBlank.length - TAIL_LINES),
    ],
    parseErrors: 0,
  };
}

function recordType(obj: Record<string, unknown>): string {
  const t = obj.type;
  return typeof t === 'string' && t.length > 0 ? t : '<missing-type>';
}

function bucketNames(format: string, obj: Record<string, unknown>): string[] {
  const type = recordType(obj);
  const buckets = [`record:${type}`];
  if (
    format === 'claude-code' &&
    obj.message &&
    typeof obj.message === 'object'
  ) {
    buckets.push(`message:${type}`);
  }
  if (format === 'codex') {
    const payload = obj.payload;
    if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
      const p = payload as Record<string, unknown>;
      const pType = typeof p.type === 'string' ? p.type : '-';
      buckets.push(`payload:${type}/${pType}`);
    } else {
      buckets.push(`payload:${type}/-`);
    }
  }
  return buckets;
}

function topLevelKeys(obj: Record<string, unknown>): string[] {
  return Object.keys(obj);
}

function extractVersion(
  format: string,
  versionField: string,
  obj: Record<string, unknown>,
): string | null {
  if (versionField === 'not_logged') return null;
  if (format === 'claude-code' && versionField === '$.version') {
    return typeof obj.version === 'string' ? obj.version : null;
  }
  if (format === 'codex' && versionField === '$.payload.cli_version') {
    if (obj.type !== 'session_meta') return null;
    const payload = obj.payload;
    if (payload && typeof payload === 'object' && !Array.isArray(payload)) {
      const v = (payload as Record<string, unknown>).cli_version;
      return typeof v === 'string' ? v : null;
    }
  }
  return null;
}

export function assertNoUserPathKeys(keys: Iterable<string>): void {
  for (const k of keys) {
    if (USER_PATH_KEY_RE.test(k)) {
      throw new Error(`refusing to record user-path-shaped key: ${k}`);
    }
  }
}

/**
 * Baseline ↔ matrix alignment (owner adjudication for PR #245):
 * - baseline.vendorVersions.max < matrix.max_verified_version → desync (exit 1, no diff)
 * - baseline.max > matrix.max → stale_baseline (existing blocked path)
 * - equal / either side null → ok
 */
export type BaselineMatrixAlignment =
  | { status: 'ok' }
  | { status: 'format_mismatch'; message: string }
  | { status: 'desync'; message: string }
  | { status: 'stale_baseline'; message: string };

export function alignBaselineWithMatrix(
  baseline: Pick<BaselineFile, 'format' | 'vendorVersions'>,
  format: string,
  entry: Pick<FormatMatrixEntry, 'max_verified_version'>,
): BaselineMatrixAlignment {
  if (baseline.format !== format) {
    return {
      status: 'format_mismatch',
      message: `baseline/matrix desync for ${format}: baseline format ${baseline.format}, matrix key ${format}`,
    };
  }
  const baselineMax = baseline.vendorVersions.max;
  const matrixMax = entry.max_verified_version;
  if (!baselineMax || !matrixMax) {
    return { status: 'ok' };
  }
  let cmp: -1 | 0 | 1;
  try {
    cmp = compareVersions(baselineMax, matrixMax);
  } catch {
    return {
      status: 'desync',
      message: `baseline/matrix desync for ${format}: unparseable versions baseline=${baselineMax} matrix=${matrixMax}`,
    };
  }
  if (cmp < 0) {
    return {
      status: 'desync',
      message: `baseline/matrix desync for ${format}: baseline max ${baselineMax} < matrix max_verified_version ${matrixMax}`,
    };
  }
  if (cmp > 0) {
    return {
      status: 'stale_baseline',
      message: `baseline max ${baselineMax} > max_verified_version ${matrixMax}`,
    };
  }
  return { status: 'ok' };
}

/** Hard-fail when committed baseline schemaVersion is not the writer's version. */
export function checkBaselineSchemaVersion(
  baseline: Pick<BaselineFile, 'schemaVersion'>,
  format: string,
  expected = BASELINE_SCHEMA_VERSION,
): { ok: true } | { ok: false; message: string } {
  if (baseline.schemaVersion !== expected) {
    return {
      ok: false,
      message: `unsupported baseline schemaVersion ${baseline.schemaVersion} in docs/session-formats/baselines/${format}.baseline.json`,
    };
  }
  return { ok: true };
}

export function fingerprintRecords(
  format: string,
  records: Array<Record<string, unknown>>,
  opts: { versionField: string; newestMtimeUtc?: string | null } = {
    versionField: 'not_logged',
  },
): Fingerprint {
  // Treat all records as one synthetic file for pure tests.
  const buckets: Record<string, BucketAgg> = {};
  const versions = new Set<string>();
  const parseErrors = 0;

  const ensure = (name: string) => {
    if (!buckets[name]) buckets[name] = { files: 0, records: 0, keys: {} };
    return buckets[name];
  };

  // Single-file aggregation for pure unit tests.
  const keysByBucket = new Map<string, Set<string>>();
  for (const obj of records) {
    const bNames = bucketNames(format, obj);
    for (const b of bNames) {
      const agg = ensure(b);
      agg.records += 1;
      const keys = topLevelKeys(
        b.startsWith('payload:') &&
          obj.payload &&
          typeof obj.payload === 'object'
          ? (obj.payload as Record<string, unknown>)
          : b.startsWith('message:') &&
              obj.message &&
              typeof obj.message === 'object'
            ? (obj.message as Record<string, unknown>)
            : obj,
      );
      assertNoUserPathKeys(keys);
      let set = keysByBucket.get(b);
      if (!set) {
        set = new Set();
        keysByBucket.set(b, set);
      }
      for (const k of keys) set.add(k);
    }
    const v = extractVersion(format, opts.versionField, obj);
    if (v) versions.add(v);
  }
  for (const [b, keys] of keysByBucket) {
    const agg = ensure(b);
    agg.files = records.length > 0 ? 1 : 0;
    for (const k of keys) agg.keys[k] = 1;
  }

  const versionList = [...versions].sort((a, b) => {
    try {
      return compareVersions(a, b);
    } catch {
      return a.localeCompare(b);
    }
  });

  return {
    format,
    corpusFiles: records.length > 0 ? 1 : 0,
    corpusNewestMtimeUtc: opts.newestMtimeUtc ?? null,
    vendorVersions: {
      min: versionList[0] ?? null,
      max: versionList[versionList.length - 1] ?? null,
    },
    buckets,
    parseErrors,
    rootsPresent: 1,
    globMatches: records.length > 0 ? 1 : 0,
  };
}

export function fingerprintCorpus(opts: {
  format: string;
  entry: FormatMatrixEntry;
  fileLimit: number;
  home?: string;
}): Fingerprint {
  const { format, entry, fileLimit } = opts;
  const home = opts.home ?? homedir();
  const roots = entry.roots.map((r) => expandHome(r, home));
  const rootsPresent = roots.filter((r) => existsSync(r)).length;

  const candidates: Array<{ path: string; mtimeMs: number }> = [];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    for (const file of walkFiles(root, entry.excludeGlobs ?? [])) {
      if (!matchesFormatGlob(file, root, entry.glob)) continue;
      try {
        const st = statSync(file);
        candidates.push({ path: file, mtimeMs: st.mtimeMs });
      } catch {
        /* skip */
      }
    }
  }

  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const globMatches = candidates.length;

  const buckets: Record<string, BucketAgg> = {};
  const ensure = (name: string) => {
    if (!buckets[name]) buckets[name] = { files: 0, records: 0, keys: {} };
    return buckets[name];
  };

  const selected: typeof candidates = [];
  let parseErrors = 0;
  const versions = new Set<string>();

  for (const cand of candidates) {
    if (selected.length >= fileLimit) break;
    const { lines, parseErrors: pe } = sampleLines(cand.path);
    parseErrors += pe;
    const fileBuckets = new Map<string, Set<string>>();
    let hasRequired = entry.requiredTypes.length === 0;
    for (const line of lines) {
      let obj: unknown;
      try {
        obj = JSON.parse(line);
      } catch {
        parseErrors += 1;
        continue;
      }
      if (!obj || typeof obj !== 'object' || Array.isArray(obj)) continue;
      const rec = obj as Record<string, unknown>;
      const type = recordType(rec);
      if (entry.requiredTypes.includes(type)) hasRequired = true;
      const v = extractVersion(format, entry.versionField, rec);
      if (v) versions.add(v);
      for (const b of bucketNames(format, rec)) {
        const agg = ensure(b);
        agg.records += 1;
        const keySource =
          b.startsWith('payload:') &&
          rec.payload &&
          typeof rec.payload === 'object'
            ? (rec.payload as Record<string, unknown>)
            : b.startsWith('message:') &&
                rec.message &&
                typeof rec.message === 'object'
              ? (rec.message as Record<string, unknown>)
              : rec;
        let set = fileBuckets.get(b);
        if (!set) {
          set = new Set();
          fileBuckets.set(b, set);
        }
        const keys = topLevelKeys(keySource);
        // Fail-loud on path-shaped keys (same contract as fingerprintRecords /
        // accept write path) so baselines never silently drop them.
        assertNoUserPathKeys(keys);
        for (const k of keys) set.add(k);
      }
    }
    if (!hasRequired) continue;
    selected.push(cand);
    for (const [b, keys] of fileBuckets) {
      const agg = ensure(b);
      agg.files += 1;
      for (const k of keys) {
        agg.keys[k] = (agg.keys[k] ?? 0) + 1;
      }
    }
  }

  const versionList = [...versions].sort((a, b) => {
    try {
      return compareVersions(a, b);
    } catch {
      return a.localeCompare(b);
    }
  });

  return {
    format,
    corpusFiles: selected.length,
    corpusNewestMtimeUtc:
      selected.length > 0
        ? new Date(Math.max(...selected.map((s) => s.mtimeMs))).toISOString()
        : null,
    vendorVersions: {
      min: versionList[0] ?? null,
      max: versionList[versionList.length - 1] ?? null,
    },
    buckets,
    parseErrors,
    rootsPresent,
    globMatches,
  };
}

export function digestFingerprint(fp: Fingerprint): string {
  const shape: Record<string, string[]> = {};
  for (const [b, agg] of Object.entries(fp.buckets).sort(([a], [c]) =>
    a.localeCompare(c),
  )) {
    shape[b] = Object.keys(agg.keys).sort();
  }
  const hex = createHash('sha256').update(JSON.stringify(shape)).digest('hex');
  return `sha256:${hex}`;
}

export function evaluateFreshness(
  fp: Fingerprint,
  entry: FormatMatrixEntry,
  now = new Date(),
): FreshnessState {
  if (fp.rootsPresent === 0 || fp.globMatches === 0) {
    return {
      state: 'no_local_sample',
      reason: `no corpus at ${entry.roots[0] ?? '(none)'}`,
    };
  }
  if (fp.globMatches > 0 && fp.corpusFiles === 0) {
    const rootHint = entry.roots[0] ?? '(none)';
    return {
      state: 'blocked_required_type_absent',
      reason: `${fp.globMatches} files scanned under ${rootHint}, none contained any of ${JSON.stringify(entry.requiredTypes)}`,
    };
  }
  if (fp.corpusNewestMtimeUtc) {
    const ageDays =
      (now.getTime() - new Date(fp.corpusNewestMtimeUtc).getTime()) /
      (24 * 3600 * 1000);
    if (ageDays > FRESHNESS_WINDOW_DAYS) {
      return {
        state: 'blocked_stale_sample',
        reason: `newest sample ${fp.corpusNewestMtimeUtc.slice(0, 10)} is ${Math.floor(ageDays)}d old (window ${FRESHNESS_WINDOW_DAYS}d)`,
      };
    }
  }
  if (
    entry.versionField !== 'not_logged' &&
    entry.max_verified_version &&
    fp.vendorVersions.max
  ) {
    try {
      const cmp = compareVersions(
        fp.vendorVersions.max,
        entry.max_verified_version,
      );
      if (cmp > 0) {
        return {
          state: 'blocked_stale_baseline',
          reason: `corpus version ${fp.vendorVersions.max} > max_verified_version ${entry.max_verified_version}`,
        };
      }
      if (cmp < 0) {
        return {
          state: 'stale_local_toolchain',
          reason: `observed ${fp.vendorVersions.max} < max_verified_version ${entry.max_verified_version}`,
        };
      }
    } catch {
      return {
        state: 'blocked_stale_baseline',
        reason: `unparseable version "${fp.vendorVersions.max}"`,
      };
    }
  }
  return { state: 'ok' };
}

export function compareFingerprints(
  observed: Fingerprint,
  baseline: BaselineFile,
): DiffFinding[] {
  const findings: DiffFinding[] = [];
  const obsFiles = Math.max(1, observed.corpusFiles);
  const baseFiles = Math.max(1, baseline.corpusFiles);

  for (const [b, agg] of Object.entries(observed.buckets)) {
    if (!baseline.buckets[b]) {
      const prev = agg.files / obsFiles;
      const line = `+${b} ${agg.files}/${observed.corpusFiles} (${Math.round(prev * 100)}%)`;
      if (prev >= PREVALENCE_THRESHOLD) {
        findings.push({
          kind: 'DRIFT',
          line: `DRIFT ${observed.format} ${line}`,
        });
      } else {
        findings.push({
          kind: 'note',
          line: `note  ${observed.format} ${line} — novel-rare, informational`,
        });
      }
      continue;
    }
    const baseKeys = baseline.buckets[b].keys;
    for (const [k, fileCount] of Object.entries(agg.keys)) {
      if (baseKeys[k] != null) continue;
      const prev = fileCount / obsFiles;
      const line = `${b} +${k} ${fileCount}/${observed.corpusFiles} (${Math.round(prev * 100)}%)`;
      if (prev >= PREVALENCE_THRESHOLD) {
        findings.push({
          kind: 'DRIFT',
          line: `DRIFT ${observed.format} ${line}`,
        });
      } else {
        findings.push({
          kind: 'note',
          line: `note  ${observed.format} ${line} — novel-rare, informational`,
        });
      }
    }
  }

  for (const [b, baseAgg] of Object.entries(baseline.buckets)) {
    for (const [k, baseCount] of Object.entries(baseAgg.keys)) {
      const basePrev = baseCount / baseFiles;
      if (basePrev < PREVALENCE_THRESHOLD) continue;
      const obsCount = observed.buckets[b]?.keys[k];
      if (obsCount == null) {
        findings.push({
          kind: 'info',
          line: `info  ${observed.format} ${b} -${k} (in baseline, unobserved)`,
        });
      }
    }
  }

  return findings;
}

export function toBaselineFile(
  fp: Fingerprint,
  entry: FormatMatrixEntry,
  note: string,
  acceptedAtUtc = new Date().toISOString(),
): BaselineFile {
  return {
    schemaVersion: BASELINE_SCHEMA_VERSION,
    format: fp.format,
    sources: entry.sources,
    acceptedAtUtc,
    acceptedNote: note,
    vendorVersions: fp.vendorVersions,
    corpusFiles: fp.corpusFiles,
    corpusNewestMtimeUtc: fp.corpusNewestMtimeUtc,
    sampling: {
      headLines: HEAD_LINES,
      tailLines: TAIL_LINES,
      excludeGlobs: entry.excludeGlobs ?? [],
    },
    digest: digestFingerprint(fp),
    buckets: fp.buckets,
    note: 'key names only; no values are recorded',
  };
}

function writeBaseline(repoRoot: string, baseline: BaselineFile): void {
  const path = baselinePath(repoRoot, baseline.format);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(baseline, null, 2)}\n`, 'utf8');
}

function isMain(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return import.meta.url === `file://${resolve(entry)}`;
  } catch {
    return false;
  }
}

function main(): void {
  const repoRoot = resolve(import.meta.dirname, '..');
  const args = process.argv.slice(2);
  const accept = args.includes('--accept');
  const acceptDrift = args.includes('--accept-drift');
  const allowStaleSample = args.includes('--allow-stale-sample');
  const formatIdx = args.indexOf('--format');
  const onlyFormat = formatIdx >= 0 ? args[formatIdx + 1] : null;
  const noteIdx = args.indexOf('--note');
  const note = noteIdx >= 0 ? args[noteIdx + 1] : null;

  const matrix = loadSupportMatrix(repoRoot);
  const monitored = Object.entries(matrix.formats).filter(
    ([, e]) => e.monitored,
  );
  const targets = onlyFormat
    ? monitored.filter(([name]) => name === onlyFormat)
    : monitored;

  if (targets.length === 0) {
    console.error(
      `no monitored format matched${onlyFormat ? ` (${onlyFormat})` : ''}`,
    );
    process.exit(1);
  }

  if (accept) {
    if (!onlyFormat || !note) {
      console.error('accept requires --format <f> and --note "<why>"');
      process.exit(1);
    }
    const entry = matrix.formats[onlyFormat];
    if (!entry?.monitored) {
      console.error(`format ${onlyFormat} is not monitored`);
      process.exit(1);
    }
    const existing = loadBaseline(repoRoot, onlyFormat);
    if (existing && existing.schemaVersion > BASELINE_SCHEMA_VERSION) {
      console.error(
        `refusing to overwrite baseline schemaVersion ${existing.schemaVersion} > writer ${BASELINE_SCHEMA_VERSION}`,
      );
      process.exit(1);
    }
    const fp = fingerprintCorpus({
      format: onlyFormat,
      entry,
      fileLimit: BASELINE_FILES,
    });
    const freshness = evaluateFreshness(fp, entry);
    if (
      freshness.state === 'no_local_sample' ||
      freshness.state === 'blocked_required_type_absent'
    ) {
      console.error(`accept refused: ${freshness.state}: ${freshness.reason}`);
      process.exit(1);
    }
    if (freshness.state === 'blocked_stale_sample' && !allowStaleSample) {
      console.error(
        `accept refused: ${freshness.reason} (pass --allow-stale-sample to override)`,
      );
      process.exit(1);
    }
    if (existing) {
      const findings = compareFingerprints(fp, existing);
      const drifts = findings.filter((f) => f.kind === 'DRIFT');
      if (drifts.length > 0 && !acceptDrift) {
        console.error(drifts.map((d) => d.line).join('\n'));
        console.error('accept refused: DRIFT without --accept-drift');
        process.exit(1);
      }
    }
    const baseline = toBaselineFile(fp, entry, note);
    writeBaseline(repoRoot, baseline);

    // Update matrix max_verified_version / last_checked_utc
    let matrixText = readFileSync(
      join(repoRoot, 'docs/session-formats/support-matrix.yml'),
      'utf8',
    );
    const today = new Date().toISOString();
    if (fp.vendorVersions.max && entry.max_verified_version) {
      try {
        if (
          compareVersions(fp.vendorVersions.max, entry.max_verified_version) > 0
        ) {
          matrixText = matrixText.replace(
            new RegExp(
              `(^  ${onlyFormat}:[\\s\\S]*?max_verified_version: )[^\\n]+`,
              'm',
            ),
            `$1"${fp.vendorVersions.max}"`,
          );
        } else if (
          compareVersions(fp.vendorVersions.max, entry.max_verified_version) < 0
        ) {
          console.log(
            `version regression ignored: observed ${fp.vendorVersions.max} < recorded ${entry.max_verified_version}`,
          );
        }
      } catch {
        /* leave matrix alone */
      }
    }
    matrixText = matrixText.replace(
      new RegExp(`(^  ${onlyFormat}:[\\s\\S]*?last_checked_utc: )[^\\n]+`, 'm'),
      `$1"${today}"`,
    );
    writeFileSync(
      join(repoRoot, 'docs/session-formats/support-matrix.yml'),
      matrixText,
      'utf8',
    );

    const stampDate = today.slice(0, 10);
    for (const doc of entry.docs) {
      const docPath = join(repoRoot, doc);
      if (!existsSync(docPath)) continue;
      let text = readFileSync(docPath, 'utf8');
      text = text.replace(
        /Last researched:\s*[^\n]+/,
        `Last researched: ${stampDate}`,
      );
      writeFileSync(docPath, text, 'utf8');
    }
    console.log(
      `accepted baseline for ${onlyFormat} (${fp.corpusFiles} files)`,
    );
    process.exit(0);
  }

  // Check path
  let fingerprinted = 0;
  let skipped = 0;
  let blocked = 0;
  const failures: string[] = [];

  for (const [format, entry] of targets) {
    const baseline = loadBaseline(repoRoot, format);
    if (!baseline) {
      failures.push(
        `missing baseline for ${format} at ${baselinePath(repoRoot, format)}`,
      );
      blocked += 1;
      continue;
    }
    const schema = checkBaselineSchemaVersion(baseline, format);
    if (!schema.ok) {
      failures.push(schema.message);
      blocked += 1;
      continue;
    }

    const alignment = alignBaselineWithMatrix(baseline, format, entry);
    if (
      alignment.status === 'format_mismatch' ||
      alignment.status === 'desync'
    ) {
      console.log(alignment.message);
      failures.push(alignment.message);
      blocked += 1;
      continue;
    }
    if (alignment.status === 'stale_baseline') {
      // Owner adjudication: baseline.max > matrix.max uses the existing
      // blocked_stale_baseline path (exit 1, no fingerprint diff).
      console.log(
        `BLOCKED ${format} blocked_stale_baseline: ${alignment.message}`,
      );
      failures.push(`${format} blocked_stale_baseline`);
      blocked += 1;
      continue;
    }

    const fp = fingerprintCorpus({ format, entry, fileLimit: OBSERVE_FILES });
    const freshness = evaluateFreshness(fp, entry);

    if (freshness.state === 'no_local_sample') {
      console.log(
        `adapter format drift: ${format} skipped (${freshness.reason})`,
      );
      skipped += 1;
      continue;
    }

    // Required type absent: not a successful fingerprint; no compare/diff dump.
    if (freshness.state === 'blocked_required_type_absent') {
      console.log(`BLOCKED ${format} ${freshness.state}: ${freshness.reason}`);
      blocked += 1;
      failures.push(`${format} ${freshness.state}`);
      continue;
    }

    fingerprinted += 1;
    const findings = compareFingerprints(fp, baseline);
    const drifts = findings.filter((f) => f.kind === 'DRIFT');

    if (
      freshness.state === 'blocked_stale_baseline' ||
      freshness.state === 'blocked_stale_sample'
    ) {
      console.log(`BLOCKED ${format} ${freshness.state}: ${freshness.reason}`);
      if (findings.length > 0) {
        const untrustedHint =
          freshness.state === 'blocked_stale_baseline'
            ? 'untrusted diff follows — the baseline predates this vendor version'
            : 'untrusted diff follows — sample is outside the freshness window';
        console.log(`  ${untrustedHint}`);
        for (const f of findings) console.log(`  ${f.line}`);
      } else {
        console.log('  untrusted diff follows — no drift or note lines');
      }
      blocked += 1;
      failures.push(`${format} ${freshness.state}`);
      continue;
    }

    if (freshness.state === 'stale_local_toolchain') {
      console.log(`note  ${format} ${freshness.reason}`);
    }

    if (drifts.length > 0) {
      for (const f of findings) console.log(f.line);
      failures.push(`${format} drift`);
    } else {
      for (const f of findings) console.log(f.line);
      const ver = fp.vendorVersions.max ?? 'unknown';
      const baseDate = baseline.acceptedAtUtc.slice(0, 10);
      console.log(
        `adapter format drift: ${format} ok (${fp.corpusFiles} files, ${ver}, baseline ${baseDate})`,
      );
    }
  }

  const monitoredCount = targets.length;
  if (failures.length > 0) {
    console.log(
      `adapter format drift: ${fingerprinted} of ${monitoredCount} monitored formats fingerprinted, ${blocked} blocked — fingerprint not trusted`,
    );
    console.error(failures.join('\n'));
    process.exit(1);
  }

  if (fingerprinted === 0) {
    console.log(
      `adapter format drift: 0 of ${monitoredCount} monitored formats fingerprinted, ${skipped} skipped — nothing was checked`,
    );
    process.exit(0);
  }

  console.log(
    `adapter format drift: ${fingerprinted} of ${monitoredCount} monitored formats fingerprinted, ${skipped} skipped — ok`,
  );
  process.exit(0);
}

if (isMain()) {
  main();
}
