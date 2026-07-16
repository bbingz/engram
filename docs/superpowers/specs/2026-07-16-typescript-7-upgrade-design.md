# Design Doc: TypeScript 7 Upgrade

- **Status**: Complete for implementation approval; this document does not
  authorize the dependency change
- **Owner**: Engram maintainers
- **Date**: 2026-07-16
- **Baseline**: `17cc1b70351b1933187ea9c5b6f2b6c4d3e5fc55`
  (`origin/main`)
- **Related**:
  [TypeScript 7.0 announcement](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/),
  [TypeScript 6.0 release notes](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-6-0.html),
  [TypeScript 7 intentional changes (pinned source revision)](https://github.com/microsoft/typescript-go/blob/9ea7f6b36e9a56987d078a8fd33e63a033121683/CHANGES.md),
  [npm metadata for `typescript@7.0.2`](https://registry.npmjs.org/typescript/7.0.2)

## Problem

Engram still declares `typescript@^6.0.3` for retained development, reference,
fixture, and regression-test tooling (`package.json:43-56`). TypeScript 7.0 was
released on 2026-07-08 as a native compiler and `7.0.2` was the npm `latest`
version when this design was written. The new compiler materially improves
checking speed, but the major-version change also alters the package layout,
removes the stable programmatic Compiler API from the `typescript` package,
tightens configuration rules, and resolves the executable through an
OS/architecture-specific native package.

A version-only edit without an explicit compatibility and verification contract
would leave four material gaps:

1. `--noEmit` success would not prove that JavaScript, declarations, source maps,
   declaration maps, or the retained CLI still work.
2. A warm macOS installation would not prove that a clean Node 24 installation
   resolves the correct native compiler on both macOS and Linux CI.
3. A hidden tool that imports the TypeScript Compiler API could require the
   official TypeScript 6 compatibility package even though Engram source does
   not import `typescript` directly.
4. Fixture or declaration changes could be accepted as dependency churn without
   determining whether their semantics changed.

The upgrade therefore needs to remain narrow while proving the full retained
TypeScript toolchain and the Swift product boundary.

## Goals / Non-goals

### Goals

- Use the stable `typescript@7.0.2` compiler for Engram's `tsc` build and
  typecheck commands on local development machines and CI.
- Keep the planned tracked implementation diff limited to `package.json` and
  `package-lock.json`.
- Preserve the existing ES2022/Node16 module contract, strictness, JavaScript
  emit, declaration emit, source maps, declaration maps, retained CLI behavior,
  tests, and fixture/parity outputs.
- Prove clean native-compiler installation and execution on the repository's
  macOS lane and Ubuntu x64 Node 24 lane.
- Preserve the Swift-only shipped runtime and the rule that no Node, TypeScript,
  platform compiler binary, `node_modules`, or `dist` artifact enters
  `Engram.app`.
- Make failure classification and rollback deterministic and atomic.

### Non-goals

- Removing the retained TypeScript source or porting more reference tooling to
  Swift.
- Changing Swift app, service, MCP, database, schema, indexing, or adapter
  behavior.
- Refactoring TypeScript source to use new language features.
- Changing `target`, `module`, `moduleResolution`, `strict`, `skipLibCheck`,
  declaration, or source-map policy.
- Upgrading Node, npm, `@types/node`, Vitest, tsx, Knip, Biome, or unrelated
  dependencies.
- Adopting `typescript@next`, beta/RC builds, `@typescript/native-preview`, or
  `typescript/unstable/*` APIs.
- Configuring the TypeScript 7 editor extension or standardizing editor/LSP
  behavior.
- Tuning `--checkers` or `--builders`, or promising a fixed compiler speedup.
- Building, installing, deploying, or releasing a new Engram app solely because
  the development compiler changed.

## Current state

All repository anchors in this section refer to baseline commit
`17cc1b70351b1933187ea9c5b6f2b6c4d3e5fc55`.

### Product and tooling boundary

- The shipped product is the native SwiftUI app plus Swift `EngramService` and
  `EngramMCP`. TypeScript is explicitly retained for development, reference,
  fixtures, and regression tests and is not the shipped runtime
  (`CLAUDE.md:3-6`).
- Release verification rejects `node`, `node_modules`, `dist`, `daemon.js`,
  `index.js`, and `web.js` from the app bundle
  (`macos/scripts/release-verify.sh:73-90`).
- `dist/` is ignored and is not a committed or shipped artifact.

### Dependency and compiler configuration

- `package.json:55` declares `typescript: "^6.0.3"`; the lockfile resolves
  exactly `6.0.3` (`package-lock.json:5860-5872`).
- `npm run build` invokes `tsc`, and `npm run typecheck:test` invokes
  `tsc --noEmit -p tsconfig.test.json` (`package.json:9-30`).
- `tsconfig.json:2-16` explicitly sets `target: ES2022`, `module: Node16`,
  `moduleResolution: Node16`, `rootDir: src`, `strict: true`, JavaScript and
  declaration emit, and both source-map forms.
- `tsconfig.test.json:2-8` extends that configuration, sets `rootDir: .` and
  `noEmit: true`, and includes `src`, `tests`, and `scripts`.
- The repository standard is Node 24 (`.nvmrc:1` and
  `.github/workflows/test.yml:71-75`); `package.json:6-8` permits Node 24 through
  26. TypeScript 7.0.2 requires Node `>=16.20.0`, so the repository range is
  compatible.

### Compiler API and ecosystem inventory

- A repository scan found no static `import`, dynamic `import`, or `require` of
  the `typescript` package under `src`, `tests`, or `scripts`.
- `npm ls typescript --all` reports only Engram's direct compiler dependency.
- The installed tsx, Vitest, Knip, and Biome packages do not declare TypeScript
  as a runtime dependency or peer dependency that pins TypeScript 6. This is
  positive evidence, not a substitute for running the tools after a clean TS 7
  install.
- All 123 current `*.test.ts` files explicitly import Vitest rather than relying
  on ambient Vitest globals.
- No active repository configuration uses the TypeScript 7 hard-error options
  `target: es5`, `downlevelIteration`, `moduleResolution: node|node10|classic`,
  `module: amd|umd|systemjs|none`, `baseUrl`, `esModuleInterop: false`,
  `allowSyntheticDefaultImports: false`, or `alwaysStrict: false`.

### CI and fixture consumers

- Any `package.json` or lockfile change is classified as heavy by the Tests
  workflow, so the Node, macOS fixture, Swift, remote-server, and pull-request UI
  lanes run (`.github/workflows/test.yml:22-54`). The remote-server lane is
  independent native coverage; it does not install Node or consume generated
  TypeScript fixtures.
- The Ubuntu Node 24 lane performs clean install, build, test/script typecheck,
  lint, Knip, coverage, and dependency audit
  (`.github/workflows/test.yml:56-100`).
- The macOS lane performs clean install and build, then checks fixture schema,
  MCP contract freshness, adapter parity, and fixture determinism
  (`.github/workflows/test.yml:102-132`).
- Swift and UI jobs also use the retained TypeScript tooling to build fixtures
  before their native checks (`.github/workflows/test.yml:171-175` and
  `305-320`).
- Package and lockfile changes select TypeScript CodeQL
  (`scripts/ci/classify-codeql-changes.sh:20-28`) and the pull request is subject
  to fail-closed dependency review for moderate-or-higher development dependency
  findings (`.github/workflows/dependency-review.yml:13-50`).

### Pre-design compatibility evidence

The following read-only probes were run on 2026-07-16 without changing tracked
files:

- local compiler: `Version 6.0.3`;
- ephemeral official compiler: `Version 7.0.2`;
- TypeScript 6.0.3 and 7.0.2 both passed `--noEmit` for `tsconfig.json` and
  `tsconfig.test.json`;
- TS 6 and TS 7 `--showConfig` output was semantically equal; the diff contained
  only property ordering and final-newline differences;
- one warm local `tsconfig.test.json --noEmit` sample took 2.07 seconds on TS 6
  and 0.26 seconds on TS 7.

The timing is informational only. The probe used macOS arm64 and Node 26.5.0; it
does not replace Node 24, real emit, clean-install, or Linux CI evidence.
Because those preliminary probes did not opt TS 6 into
`--stableTypeOrdering`, they are not the formal cross-version declaration/emit
baseline defined below.

## Compatibility constraints

### Compiler selection and package installation

1. The root development dependency MUST be `typescript: "^7.0.2"`.
2. The committed lockfile MUST remain lockfile version 3 and MUST resolve the
   root TypeScript package and selected native compiler packages to exact
   version `7.0.2`.
3. Lockfile churn MUST be limited to removal of the TS 6 package shape, addition
   of the TS 7 package shape, and the official
   `@typescript/typescript-<os>-<arch>` packages required by
   `typescript@7.0.2`. Unrelated package upgrades are not allowed.
4. Build and typecheck installations MUST include dev and optional dependencies.
   `--omit=optional`, `optional=false`, and equivalent settings are forbidden:
   the `tsc` launcher resolves the actual compiler from an OS/CPU-specific
   native package.
5. Acceptance MUST use the project-local compiler. In the Node 24 implementation
   environment, `npm exec -- tsc --version` MUST print exactly `Version 7.0.2`.
   On each existing Ubuntu/macOS CI lane that installs Node dependencies, a
   clean `npm ci` followed by `npm run build` MUST succeed; together with the
   exact lockfile assertions below, that proves the platform launcher selected
   the locked compiler without requiring a workflow-only logging change.
6. The migration MUST NOT add `@typescript/native-preview`, `typescript@next`,
   `@typescript/typescript6`, a `typescript` npm alias, a vendored compiler
   binary, or an unreviewed registry source.

### Configuration and source compatibility

1. `tsconfig.json` and `tsconfig.test.json` MUST remain unchanged in the planned
   implementation.
2. The migration MUST NOT suppress failures by weakening `strict`, adding
   `noCheck`, changing `skipLibCheck`, adding `ignoreDeprecations`, removing
   declaration or map emit, or introducing `@ts-ignore`/`@ts-nocheck` comments.
3. TypeScript 7 defaults `types` to an empty list, but both current projects pass
   the TS 7 probe and all tests import Vitest explicitly. The migration therefore
   MUST NOT add `types: ["*"]` or preemptively add `types: ["node"]`.
4. The migration MUST use project compilation (`-p <tsconfig>`) rather than
   passing source file paths to `tsc` from a directory containing a tsconfig.
5. Default TS 7 parallelism MUST be used initially. `--checkers`, `--builders`,
   and `--singleThreaded` are diagnostic or follow-up controls, not part of the
   planned scripts.
6. If a source or configuration change appears necessary, implementation stops
   after preserving the exact diagnostic. The requirement must be reproduced on
   a clean install, compared with TS 6, and added to a reviewed amendment before
   changing source, configuration, tests, or CI.

### Emit and behavior compatibility

1. `--noEmit` success is necessary but insufficient. The implementation MUST run
   the real `npm run build` and MUST produce JavaScript, `.d.ts`, `.js.map`, and
   `.d.ts.map` outputs.
2. A TS 6 baseline and TS 7 candidate emit MUST have the same relative file
   inventory. Missing or extra output files are blockers unless this design is
   amended with a concrete reason.
3. The formal TS 6 typecheck and emit baseline MUST use the TS 6 migration-only
   `--stableTypeOrdering` flag because TS 7 always uses stable type ordering.
   The flag MUST NOT be added to either tsconfig or passed to the TS 7 compiler.
   This avoids treating expected union/property ordering changes as candidate
   declaration drift.
4. Byte-identical output is not required because the native compiler can change
   formatting and map serialization. A complete recursive diff MUST be retained
   as verifier evidence, and every changed file MUST be classified before the
   upgrade can pass.
5. Allowed differences are limited to printer trivia/formatting, or valid source
   map serialization and mappings attributable to that formatting. Declaration
   changes are allowed only when review proves that differences are trivia: the
   exported names, module specifiers, modifiers, and type token sequence remain
   identical. JavaScript changes to literals, import/export specifiers, shebangs,
   executable control flow, or callable signatures are semantic until a focused
   consumer check and specification amendment prove otherwise. Missing/extra
   files, invalid maps, unclassified differences, and semantic drift are
   blockers.
6. Public declaration shapes MUST not lose exports or widen/narrow types without
   an explicit compatibility finding, focused consumer check, and reviewed
   specification amendment.
7. The compiled retained CLI MUST run `project --help` successfully from the
   candidate output and print the `engram project` usage text.
8. No generated `dist` file may be staged or committed.

### Tool and fixture compatibility

1. Build, test/script typecheck, lint, Knip, coverage, fixture schema, MCP
   contract, adapter parity, and fixture determinism commands MUST all run with
   the TS 7 lockfile installed.
2. Passing Vitest alone is insufficient because Vitest/tsx primarily transpile
   through Vite/esbuild rather than exercising the configured `tsc` emit.
3. Fixture generation MUST leave `test-fixtures/` and `tests/fixtures/` without
   unexplained tracked changes. A compiler-only dependency upgrade is not a
   reason to bless changed product/parity data.
4. The migration MUST begin with one TypeScript compiler. A TS 6 compatibility
   package may be proposed only after a clean, reproducible failure proves that
   a required tool imports the TypeScript 6 Compiler API. That fallback is a new
   design decision, not an automatic workaround under this specification.

## Proposed design

### Package and lockfile update

The implementation changes the direct dependency to:

```json
{
  "devDependencies": {
    "typescript": "^7.0.2"
  }
}
```

The implementation regenerates only the TypeScript-related lockfile nodes using
the repository's supported Node/npm toolchain, then validates the result with a
clean `npm ci`. The lockfile pins the actual compiler to `7.0.2`; the caret range
retains the repository's existing dependency declaration style. If this work is
implemented after `7.0.2` is no longer npm `latest`, it MUST still target and
verify `7.0.2` or this specification must be revised before silently selecting a
later 7.x compiler.

The expected tracked implementation file set is:

- `package.json`
- `package-lock.json`

This specification is the only documentation artifact. No source, tsconfig,
workflow, Swift, Xcode project, fixture, changelog, memory, or generated output
change is part of the planned implementation.

### Single-compiler decision

Engram adopts TypeScript 7 directly and does not install TypeScript 6 alongside
it. The repository has no confirmed Compiler API consumer, and preemptive
dual-installation would add aliases, two command names, and ambiguity without a
demonstrated requirement.

If a required tool later proves that it needs the TypeScript 6 API, the
implementation must stop and record:

- the exact tool and version;
- the clean-install command and complete error;
- proof that the error is caused by the missing API rather than a type or emit
  change; and
- a focused verifier for the tool.

A follow-up amendment may then evaluate the official
`@typescript/typescript6`/npm-alias arrangement. It must separately prove the
TS 7 `tsc` and TS 6 `tsc6` selections. Compatibility mode is not rollback.

### CI and platform coverage

No CI workflow changes are planned. Existing change classification already
causes the required coverage:

- Ubuntu x64 / Node 24 clean install and Node quality gates;
- the current macOS runner's architecture / Node 24 clean install and fixture
  gates;
- TypeScript CodeQL and dependency review;
- native Swift and pull-request UI lanes that build retained tooling and consume
  generated fixtures; and
- the independent native remote-server lane, which runs because the change is
  classified as heavy but is not a TypeScript or fixture verifier.

The implementation records `process.platform`, `process.arch`, Node, npm, and
`tsc` versions in its local Node 24 evidence. Existing Ubuntu and macOS CI lanes
prove platform execution through clean install and real build; this package-only
design does not add version-printing steps solely for redundant log output. The
specification promises only the platforms exercised by the repository's real
runners; registry metadata alone does not prove every Linux distribution or
libc combination.

No custom parallelism flags are introduced. If a CI-only resource or ordering
failure appears, rerunning the same project with `--singleThreaded` is the first
diagnostic split. A permanent checker/builder count requires separate benchmark
evidence and consistent configuration across environments.

### Product boundary

The compiler remains a development dependency. No Xcode copy phase, release
script, application resource, helper target, or runtime invocation changes.
Existing bundle-hygiene guards remain authoritative. A local app rebuild,
installation, service restart, database migration, or production deployment is
not required for this upgrade.

## Invariants affected

### Invariant 4: Parent-Detection Parity Triple Lock

`docs/invariants.md:26-31` requires the Swift detection version, retained
TypeScript `DETECTION_VERSION`, and generated fixture version to remain equal.
The dependency upgrade does not change any of the three values. The current
ledger names no standalone executable gate, so the implementation explicitly
regenerates the parent-detection fixture into a temporary directory, compares it
with the committed fixture while excluding only provenance-only `sourceCommit`,
and relies on `ParentDetectionParityTests` for the Swift side. No ledger update
is required.

### Invariant 7: Bundle Hygiene Excludes Node Artifacts

`docs/invariants.md:47-52` prohibits Node runtime artifacts from the release app.
The new native compiler and its platform package remain under development
`node_modules` and MUST NOT be copied into the app. Existing build/release-script
tests must pass. If an app bundle is produced for another reason during the same
change, `macos/scripts/release-verify.sh` must also pass against that artifact.
No ledger update is required.

No other product invariant is changed by this design.

## Alternatives considered

### A. Remain on TypeScript 6.0.3

This avoids immediate native-package and early-release risk, but retains the
slower legacy compiler and postpones an already-compatible transition. It is not
selected because both Engram projects pass the TS 7 typecheck probe and the
remaining risks have bounded verifiers and an atomic rollback.

### B. Upgrade directly to stable TypeScript 7.0.2

This keeps one compiler, follows the standard `typescript` package, and requires
only manifest/lockfile changes when all gates pass. It is selected.

### C. Run TypeScript 6 and 7 side by side

The official compatibility package is appropriate when a required tool imports
the old Compiler API. Engram has no confirmed consumer, so adding it now would
increase dependency and command ambiguity without solving an observed problem.
It is rejected as the default and retained only as a spec-amendment option.

### D. Use `next`, native preview, or unstable APIs

Preview channels and unstable APIs would give less reproducible behavior than
the stable 7.0.2 compiler and are unnecessary for this migration. They are
rejected.

### E. Modernize tsconfig and source code in the same change

Switching to NodeNext, adding ambient `types`, changing strictness, or refactoring
imports would make failures harder to attribute. The existing configurations
already pass TS 7. It is rejected as scope expansion.

## Failure handling and rollback

### Failure classification

- **Native package missing or unsupported**: confirm that optional dependencies
  were installed, record OS/architecture/Node/npm, and retry a clean `npm ci`.
  Do not vendor or manually copy a compiler binary. If the supported runner still
  cannot resolve `tsc`, roll back.
- **Compiler/type error**: reproduce from a clean install and compare TS 6 versus
  TS 7 on the same tsconfig. Do not weaken checks. An unexpected source/config
  change requires an amended specification.
- **Emit difference**: preserve the recursive diff report; separate
  file-inventory, declaration-shape, JavaScript, and map-only differences using
  the allowed/blocked rules in this document. Unclassified or semantic drift
  blocks the upgrade.
- **Tool failure**: identify whether the tool invokes the CLI, imports the old
  Compiler API, or is independently failing. Do not add the TS 6 compatibility
  package without the evidence required above.
- **Fixture difference**: retain the generated diff as evidence, determine which
  generator changed behavior, and reject unexplained product/parity changes.
- **CI resource or ordering failure**: rerun `tsc` with `--singleThreaded` only as
  a diagnostic. Do not commit the flag without reproducible evidence and a
  reviewed amendment.
- **Heavy-CI failure outside TypeScript**: classify it as upgrade-induced,
  pre-existing, or environment/flaky from logs and reruns. Do not claim success
  while a required gate remains unresolved.
- **Dependency review finding**: fail closed on moderate-or-higher findings or an
  incomplete dependency snapshot; do not waive a new platform-package finding in
  this dependency-only change.

### Atomic rollback

Rollback restores `package.json` and `package-lock.json` together to the last
accepted TypeScript 6.0.3 state, then performs a clean `npm ci` and reruns the
original build, typecheck, test, and fixture gates. Reusing a TS 7 `node_modules`
tree is not a rollback verifier.

No app, service, database, fixture, or production data rollback is needed. A
dual-compiler compatibility mode is not equivalent to rollback.

Rollback is required when any of the following remains unresolved within this
narrow dependency change:

- a supported CI platform cannot install or execute its native compiler;
- required tools fail and the cause cannot be resolved without a broader
  compatibility layer;
- type or emit semantics change unacceptably;
- fixture or declaration output cannot be classified or reproduced;
- required CI is nondeterministic after a single-threaded diagnostic split; or
- dependency review rejects the new package graph.

## Test plan

All shell blocks in this plan assume Bash and are fail-closed with
`set -euo pipefail`. The implementation evidence must preserve command output,
not merely report a summarized pass/fail result.

### Pre-change baseline

Before changing the dependency, record:

```bash
set -euo pipefail
test -z "$(git status --porcelain)"
test ! -e dist
test "$(node -p 'process.versions.node.split(".")[0]')" = "24"
ONNXRUNTIME_NODE_INSTALL=skip npm ci

node --version
npm --version
tsc_version="$(npm exec -- tsc --version)"
printf '%s\n' "$tsc_version"
test "$tsc_version" = "Version 6.0.3"
npm ls typescript --all
npm exec -- tsc --noEmit -p tsconfig.json \
  --stableTypeOrdering --pretty false
npm exec -- tsc --noEmit -p tsconfig.test.json \
  --stableTypeOrdering --pretty false

cp package-lock.json /tmp/engram-ts6-package-lock.json
git rev-parse HEAD > /tmp/engram-ts7-baseline.sha
ts6_dist="$(mktemp -d /tmp/engram-ts6-dist.XXXXXX)"
npm exec -- tsc -p tsconfig.json --outDir "$ts6_dist" \
  --stableTypeOrdering --pretty false
printf '%s\n' "$ts6_dist" > /tmp/engram-ts6-dist.path
```

The implementation starts from a clean worktree in which this specification is
already durable and outside the implementation diff, and where ignored `dist/`
output is absent. Baseline and candidate must run on the same machine, Node 24
major, npm toolchain, source revision, and tsconfig. The clean TS 6 install
prevents an old `node_modules` tree from contaminating the declaration baseline;
the absent `dist/` precondition makes the later real build a clean emit. The
TS 6-only `--stableTypeOrdering` migration diagnostic aligns its declaration
ordering with TS 7 without changing committed configuration. Preserve the
lockfile copy, `/tmp/engram-ts7-baseline.sha`, and the path recorded in
`/tmp/engram-ts6-dist.path` until candidate review is complete.

### Clean install and compiler identity

After updating the manifest and lockfile, use Node 24 and run:

```bash
set -euo pipefail
test "$(node -p 'process.versions.node.split(".")[0]')" = "24"

node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const baseline = JSON.parse(
  readFileSync('/tmp/engram-ts6-package-lock.json', 'utf8'),
);
const candidate = JSON.parse(readFileSync('package-lock.json', 'utf8'));
const isTypeScriptNode = (key) =>
  key === 'node_modules/typescript' ||
  key.startsWith('node_modules/@typescript/typescript-');
const withoutTypeScript = (lock) => {
  const copy = structuredClone(lock);
  delete copy.packages[''].devDependencies.typescript;
  for (const key of Object.keys(copy.packages)) {
    if (isTypeScriptNode(key)) delete copy.packages[key];
  }
  return copy;
};

assert.equal(candidate.lockfileVersion, 3);
assert.equal(candidate.packages[''].devDependencies.typescript, '^7.0.2');
const compiler = candidate.packages['node_modules/typescript'];
assert.equal(compiler?.version, '7.0.2');
assert.match(compiler?.resolved ?? '', /^https:\/\/registry\.npmjs\.org\//);

const officialPlatformPackages = [
  '@typescript/typescript-aix-ppc64',
  '@typescript/typescript-darwin-arm64',
  '@typescript/typescript-darwin-x64',
  '@typescript/typescript-freebsd-arm64',
  '@typescript/typescript-freebsd-x64',
  '@typescript/typescript-linux-arm',
  '@typescript/typescript-linux-arm64',
  '@typescript/typescript-linux-loong64',
  '@typescript/typescript-linux-mips64el',
  '@typescript/typescript-linux-ppc64',
  '@typescript/typescript-linux-riscv64',
  '@typescript/typescript-linux-s390x',
  '@typescript/typescript-linux-x64',
  '@typescript/typescript-netbsd-arm64',
  '@typescript/typescript-netbsd-x64',
  '@typescript/typescript-openbsd-arm64',
  '@typescript/typescript-openbsd-x64',
  '@typescript/typescript-sunos-x64',
  '@typescript/typescript-win32-arm64',
  '@typescript/typescript-win32-x64',
].sort();
const declaredPlatforms = {
  ...(compiler.dependencies ?? {}),
  ...(compiler.optionalDependencies ?? {}),
};
const declaredPlatformPackages = Object.keys(declaredPlatforms)
  .filter((name) => name.startsWith('@typescript/typescript-'))
  .sort();
assert.deepEqual(declaredPlatformPackages, officialPlatformPackages);
const expectedPlatformKeys = officialPlatformPackages.map(
  (name) => `node_modules/${name}`,
);
for (const key of expectedPlatformKeys) {
  assert.equal(declaredPlatforms[key.slice('node_modules/'.length)], '7.0.2');
  assert.equal(candidate.packages[key]?.version, '7.0.2');
  assert.match(
    candidate.packages[key]?.resolved ?? '',
    /^https:\/\/registry\.npmjs\.org\//,
  );
}
const actualPlatformKeys = Object.keys(candidate.packages)
  .filter((key) => key.startsWith('node_modules/@typescript/typescript-'))
  .sort();
assert.deepEqual(actualPlatformKeys, expectedPlatformKeys);
assert.deepEqual(withoutTypeScript(candidate), withoutTypeScript(baseline));
NODE

ONNXRUNTIME_NODE_INSTALL=skip npm ci
node -p '`${process.platform}/${process.arch} node=${process.version}`'
npm --version
tsc_version="$(npm exec -- tsc --version)"
printf '%s\n' "$tsc_version"
test "$tsc_version" = "Version 7.0.2"
npm ls typescript --all
```

The compiler output must be `Version 7.0.2`. The dependency tree must show the
root TypeScript 7.0.2 compiler and no TypeScript 6 compatibility alias. The JSON
assertion proves the exact root/platform package versions and rejects unrelated
lock nodes; it is a hard gate, not a visual diff suggestion. Existing Ubuntu x64
and macOS Node 24 lanes then prove their selected native package by completing
clean `npm ci` and `npm run build`. Installation must not omit optional
dependencies.

### Build, typecheck, and emit

```bash
set -euo pipefail
npm run build
npm run typecheck:test

test -f dist/cli/index.js
test -f dist/cli/index.d.ts
test -f dist/cli/index.js.map
test -f dist/cli/index.d.ts.map
node dist/cli/index.js project --help | grep -F 'engram project'

ts6_dist="$(cat /tmp/engram-ts6-dist.path)"
test -d "$ts6_dist"
ts7_dist="$(mktemp -d /tmp/engram-ts7-dist.XXXXXX)"
npm exec -- tsc -p tsconfig.json --outDir "$ts7_dist" --pretty false
diff -u \
  <(cd "$ts6_dist" && find . -type f | sort) \
  <(cd "$ts7_dist" && find . -type f | sort)

# A CLI launched directly from macOS /tmp misses both its entrypoint identity
# (/tmp resolves to /private/tmp) and the repository's node_modules. Copy the
# candidate emit under an ignored repo-local directory for this smoke only.
node --input-type=module - "$ts7_dist" <<'NODE'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const emittedRoot = process.argv[2];
const scratchRoot = mkdtempSync(join('node_modules', '.engram-ts7-cli.'));
const repoLocalEmit = join(scratchRoot, 'emit');
try {
  cpSync(emittedRoot, repoLocalEmit, { recursive: true });
  const help = execFileSync(
    process.execPath,
    [join(repoLocalEmit, 'cli/index.js'), 'project', '--help'],
    { encoding: 'utf8' },
  );
  assert.match(help, /engram project/);
} finally {
  rmSync(scratchRoot, { recursive: true, force: true });
}
NODE

node --input-type=module - "$ts7_dist" <<'NODE'
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.argv[2];
const files = [];
const walk = (directory) => {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) walk(path);
    else files.push(path);
  }
};
walk(root);
const maps = files.filter(
  (path) => path.endsWith('.js.map') || path.endsWith('.d.ts.map'),
);
assert.ok(maps.some((path) => path.endsWith('.js.map')));
assert.ok(maps.some((path) => path.endsWith('.d.ts.map')));
for (const path of maps) JSON.parse(readFileSync(path, 'utf8'));
NODE

emit_diff_report="$(mktemp /tmp/engram-ts6-ts7-emit.XXXXXX)"
emit_diff_rc=0
diff -ru "$ts6_dist" "$ts7_dist" > "$emit_diff_report" || emit_diff_rc=$?
test "$emit_diff_rc" -le 1
printf 'TS 6/TS 7 emit diff report: %s\n' "$emit_diff_report"
```

File-list equality, both CLI smokes, and JSON parsing of every emitted map are
hard gates. The temporary repo-local CLI copy is ignored and removed in a
`finally` block; it exists only because an out-of-repository ESM entrypoint
cannot resolve Engram's runtime dependencies. Preserve `emit_diff_report` with
the implementation evidence and classify every entry using the allowed/blocked
rules under **Emit and behavior compatibility**. A `diff` exit status of 1 means
content review is required; a status greater than 1 is an operational failure.
Byte equality is not required, but an absent report, unclassified entry, or
semantic difference fails acceptance. Do not stage `dist`.

### Tooling, tests, and fixtures

```bash
set -euo pipefail
npm run lint
npm run knip
npm run test:coverage

npm run check:fixtures
npm run check:mcp-contract-fixtures
npm run check:adapter-parity-fixtures
npm run generate:fixtures
git diff --exit-code -- test-fixtures tests/fixtures
test -z "$(git ls-files --others --exclude-standard -- test-fixtures tests/fixtures)"

parent_fixture_tmp="$(mktemp -d /tmp/engram-parent-fixture.XXXXXX)"
npm run generate:parent-detection-fixtures -- --out "$parent_fixture_tmp"
node --input-type=module - "$parent_fixture_tmp/detection-version.json" <<'NODE'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const committed = JSON.parse(
  readFileSync('tests/fixtures/parent-detection/detection-version.json', 'utf8'),
);
const generated = JSON.parse(readFileSync(process.argv[2], 'utf8'));
delete committed.sourceCommit;
delete generated.sourceCommit;
assert.deepEqual(generated, committed);
NODE

git diff --check
baseline_sha="$(cat /tmp/engram-ts7-baseline.sha)"
git cat-file -e "$baseline_sha^{commit}"
diff -u \
  <(printf '%s\n' package-lock.json package.json | sort) \
  <(git diff --name-only "$baseline_sha" -- | sort)
test -z "$(git ls-files --others --exclude-standard)"
```

The fixture diff and fixture-only untracked-file list must be empty. The
parent-detection comparison ignores only the generator's provenance commit and
must otherwise be equal. The final path allowlist checks both staged and
unstaged changes, plus any implementation commits made after the recorded
baseline, against exactly `package.json` and `package-lock.json`; it then rejects
every untracked path. This specification must therefore already be durable
before implementation begins; it is not part of the implementation worktree
diff.

### CI acceptance

The implementation pull request must complete all required existing checks:

- Tests / CI Gate, including Ubuntu Node quality, macOS fixture checks, native
  Swift and remote-server tests, and the pull-request UI smoke contract;
- CodeQL Gate with the TypeScript target selected by package/lockfile changes;
- Dependency Review with no incomplete snapshot or rejected finding.

No release tag, local app install, service restart, or production smoke is part
of this migration. Release and perf workflows are not required before merge but
must continue to consume the committed lockfile successfully when next invoked.

### Informational performance check

Implementers may capture three warm `tsconfig.test.json --noEmit` samples for TS
6 and TS 7 on the same machine. Report the median and environment, but do not use
a speed ratio as a pass/fail gate: Engram's retained TypeScript surface is small,
and correctness and reproducibility take precedence over a noisy sub-second
measurement.

### Checks intentionally not required

- Editor/LSP behavior: no editor configuration is changed.
- Compiler API behavior: Engram has no confirmed API consumer, and TS 7.0 has no
  stable API to adopt.
- Every OS/libc combination: only real supported repository runners are in
  scope.
- Installed-app runtime smoke or production deployment: TypeScript is not in the
  shipped runtime and no product code or bundle phase changes.
- A new release artifact: existing bundle guard tests are sufficient for this
  package-only change unless an app artifact is produced for another reason.

## Acceptance criteria

1. `package.json` declares exactly `typescript: "^7.0.2"`; the version is not a
   preview, alias, or compatibility package.
2. The version-3 lockfile resolves TypeScript and its official native package
   nodes to `7.0.2` and contains no unrelated dependency upgrade.
3. Clean Node 24 `npm ci` followed by `npm run build` succeeds without omitting
   dev or optional dependencies on Ubuntu x64 and the repository's macOS CI
   runner.
4. The local Node 24 implementation verifier prints `Version 7.0.2` from
   `npm exec -- tsc --version`, `npm ls typescript --all` shows no TS 6 compiler
   or alias, and the executable lockfile assertion proves all declared official
   platform nodes are exactly 7.0.2 with no unrelated lockfile churn.
5. `tsconfig.json` and `tsconfig.test.json` remain unchanged and both pass under
   TS 7 without suppressions or source changes.
6. Real emit succeeds against a clean, same-environment TS 6 baseline produced
   with `--stableTypeOrdering`; it has the same relative output-file inventory,
   retains JavaScript/declaration/map outputs, every map parses as JSON, and both
   compiled `project --help` smokes print `engram project`. The complete recursive
   diff report is retained and every content difference satisfies the documented
   allowed rules; no semantic or unclassified difference remains.
7. Every TS/tooling/coverage command and every fixture/parity/freshness command in
   the test plan passes; fixture generation leaves no tracked or untracked diff,
   and the normalized parent-detection fixture comparison is equal.
8. No TypeScript source, Swift source, workflow, Xcode project, fixture,
   changelog, memory, or generated `dist` file appears in the planned
   implementation diff.
9. Invariants 4 and 7 remain satisfied; Node, TypeScript, platform compiler
   binaries, `node_modules`, and `dist` remain outside the shipped app.
10. Tests / CI Gate, CodeQL Gate, and Dependency Review all succeed with complete
    dependency snapshots.
11. Any failure is resolved within this specification's narrow scope or triggers
    the atomic TypeScript 6 rollback; no required check is waived.

## Rollout

1. Keep this completed specification separate from implementation authorization.
2. Implement the package and lockfile update in one dedicated change using Node
   24, with no unrelated dependency refresh.
3. Complete local clean-install, emit, tooling, fixture, and diff checks before
   opening or updating the implementation pull request.
4. Merge only after all required Tests, CodeQL, and Dependency Review gates pass.
5. Do not create a release tag or deploy/restart Engram for this toolchain-only
   change. The next normal release automatically consumes the accepted lockfile
   and re-runs release hygiene.
6. If post-merge main-branch CI exposes a TS 7 regression, atomically revert the
   manifest and lockfile change and re-run the TS 6 baseline gates before any
   broader compatibility work.

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation / decision gate |
|---|---|---|---|
| Optional native package is omitted or unavailable on a real runner | Medium | High | Exact lockfile assertion plus clean `npm ci` and real build on Ubuntu and macOS; rollback on failure. |
| A tool dynamically imports the removed TS 6 Compiler API | Low | High | Run every real tool after clean install; require a reproduced consumer before considering the official TS 6 compatibility package. |
| JS/declaration/map emit differs semantically | Low-Medium | Medium | Compare inventories and content, run compiled CLI smoke and full consumers; block unclassified drift. |
| Native platform packages make the lockfile diff large or obscure unrelated churn | High | Medium | Allow only official exact-7.0.2 platform nodes and reject every unrelated package change. |
| Default parallelism exposes resource or ordering behavior on CI | Low | Medium | Use default first, split with `--singleThreaded`, and require separate evidence before committing tuning. |
| TS 7.0.2 is early in its release lifecycle | Medium | Medium | Pin exact resolution in lockfile, use required CI and atomic rollback, and do not silently retarget a later 7.x release. |
| Heavy CI has an unrelated Swift/UI flake | Medium | Low | Classify from logs and bounded reruns; never mislabel an unresolved gate as TS 7 success. |

There are no blocking design questions at the 2026-07-16 baseline. A future
implementation must re-check official npm metadata and supported runner behavior.
If the desired target version, required platforms, or toolchain API consumers
change, revise this specification before implementation rather than broadening
the patch opportunistically.
