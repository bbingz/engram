# Archive v2 Production Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package, deploy, activate, and production-verify exact-source archive v2 on `macmini-hq` and `macmini-m1` without adding or performing any source/archive deletion.

**Architecture:** Build one relocatable, hashed, ad-hoc-signed server bundle from the reviewed commit. Install the same bytes on both Macs, but generate independent v2 token/key/root values on each host. Each server binds `127.0.0.1:8787`; Tailscale Serve owns HTTPS 443. Enable the client only after both servers pass authenticated immutable API smoke checks, then require independently verified `hq` and `m1` receipts.

**Tech Stack:** Swift/XcodeGen, XCTest, Vitest, zsh, codesign, launchd, Tailscale Serve, macOS Keychain, SSH/rsync.

## Global Constraints

- Work only in `/Users/bing/orca/workspaces/engram/archive-v2-dual-replica` on `bbingz/archive-v2-dual-replica` for repository changes.
- Preserve legacy `/v1/bundles`, its store, credentials, and existing data.
- Archive v2 replica identities are exactly `hq` and `m1`; their tokens, AES keys, roots, and Tailscale origins must all be distinct.
- Bind `EngramRemoteServer` only to `127.0.0.1:8787`; expose only HTTPS 443 through Tailscale Serve. Do not use Funnel, wildcard/LAN/public listeners, or the existing M1 nginx 8443 route for v2.
- Never put tokens or keys in Git, settings JSON, command arguments, shell history, plist files, logs, review reports, or chat output.
- Preserve a per-host owner-only rollback snapshot before replacing binary/framework/wrapper/env/plist state.
- Do not delete or evict live sources, local CAS, remote objects/manifests/receipts, legacy v1 bundles, or rollback snapshots.
- Every code milestone must pass focused tests, `git diff --check`, and independent Orca Claude Opus plus Grok review before production mutation.
- A health response is process evidence only. Production durability requires authenticated receipt creation, independent receipt GET, byte-verified read-back, and client status showing verified receipts from both server IDs.
- Both hosts currently use FileVault and have no auto-login. Do not weaken FileVault. Record that a cold power loss requires manual FileVault unlock before the per-user LaunchAgent can run.

---

### Task 1: Fail Closed on the Fixed Production Replica Set

**Files:**

- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift`
- Modify: `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`
- Modify: `macos/EngramRemoteServerCoreTests/ArchiveConfigTests.swift`
- Modify affected programmatic server tests that use non-production archive IDs.

**Interfaces:**

- Consumes: `ENGRAM_REMOTE_ARCHIVE_SERVER_ID`.
- Produces: an archive-enabled server that can start only with `hq` or `m1`, including programmatic `EngramRemoteServerApp` construction.

- [ ] **Step 1: Write failing tests**

  Change the accepted-ID test to assert only `hq` and `m1` succeed. Assert `m1-primary`, `archive.server_2`, and `archive-test` throw `ConfigError.invalidArchiveServerID`. Add a programmatic app test proving a non-production ID is rejected before any root is created.

- [ ] **Step 2: Observe RED**

  Run:

  ```bash
  cd macos
  xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -only-testing:EngramRemoteServerCoreTests/ArchiveConfigTests
  ```

  Expected: the new non-production-ID assertions fail against the current safe-token-only validation.

- [ ] **Step 3: Implement the fixed-ID guard**

  Centralize the predicate in `EngramRemoteServerConfig`:

  ```swift
  static func isCurrentArchiveServerID(_ value: String) -> Bool {
      value == "hq" || value == "m1"
  }
  ```

  Use it in `fromEnvironment` and the programmatic app initializer before creating either store root. Keep the existing bounded safe-token validation in `ArchiveStore` as defense in depth for decoded on-disk namespaces.

- [ ] **Step 4: Verify and commit**

  Run the focused test, full `EngramRemoteServerCore` scheme, archive safety gate, and `git diff --check`. Commit only Task 1 files with:

  ```bash
  git commit -m "fix(remote): pin archive replica identities"
  ```

---

### Task 2: Produce a Verifiable Relocatable Server Bundle

**Files:**

- Create: `macos/scripts/package-remote-server.sh`
- Create: `tests/scripts/remote-server-package.test.ts`
- Modify: `.github/workflows/test.yml`
- Modify: `docs/remote-offload.md`
- Modify: `docs/remote-archive-v2.md`

**Interfaces:**

- Command: `macos/scripts/package-remote-server.sh --products-dir <Release-products> --output-dir <new-empty-dir> --source-commit <40-hex-sha>`.
- Output: `bin/EngramRemoteServer`, `Frameworks/EngramRemoteServerCore.framework`, optional `Frameworks/libswiftCompatibilitySpan.dylib` when the built executable needs it, `SHA256SUMS`, and `BUILD-METADATA.json`.

- [ ] **Step 1: Write failing script tests**

  Require strict argument parsing, a new/empty output directory, binary plus framework presence, arm64 support, framework-relative rpath, dependency closure, framework/dylib-before-executable ad-hoc signing, deep strict verification, deterministic sorted SHA-256 manifest, and no credential/environment handling. Require CI to invoke the packager after a Release server build.

- [ ] **Step 2: Observe RED**

  Run:

  ```bash
  npm test -- tests/scripts/remote-server-package.test.ts
  ```

  Expected: failure because the packager does not exist.

- [ ] **Step 3: Implement packaging and documentation**

  The script must use `ditto` for the framework, preserve its symlinks, copy only required compatibility dylibs, sign nested code before the executable, run `codesign --verify --deep --strict`, run `lipo -verify_arch arm64`, validate `@executable_path/../Frameworks`, and emit hashes without secrets.

  Update the v2 runbook to use:

  ```bash
  tailscale serve --bg --https=443 --yes http://127.0.0.1:8787
  ```

  and client origins `https://macmini-hq.tail1cb16.ts.net` and `https://macmini-m1.tail1cb16.ts.net`. State that the M1 nginx 8443 listener is legacy-only and outside v2. Document the FileVault/manual-unlock cold-boot limitation honestly.

- [ ] **Step 4: Verify and commit**

  Build Release, run the packager against the actual products, verify its hashes/signatures/linkage, run the focused script test, the exact CI script matrix, actionlint, archive safety gate, and `git diff --check`. Commit with:

  ```bash
  git commit -m "build(remote): package signed archive server bundle"
  ```

---

### Task 3: Deploy the HQ Canary and M1 Replica

**Files/Systems:**

- Remote: `macmini-hq.tail1cb16.ts.net`
- Remote: `macmini-m1.tail1cb16.ts.net`
- Existing per-user service root: `~/.engram-remote`
- Existing LaunchAgent: `~/Library/LaunchAgents/com.engram.remote-server.plist`

- [ ] **Step 1: Capture rollback evidence**

  On each host, create an owner-only timestamped rollback directory containing current binary, framework, wrapper, env, plist, hashes, process/listener state, and Tailscale Serve config. Do not copy either store into the rollback directory and do not delete anything.

- [ ] **Step 2: Prepare independent secrets and roots**

  Generate the v2 token and AES key locally on each server with `openssl rand -base64 32`, write them to a distinct `0600` `archive-v2.env`, and create `0700` `archive-v2-hq` / `archive-v2-m1` roots. Verify decoded lengths are 32 bytes and values differ from each other and from legacy values without printing them.

- [ ] **Step 3: Canary HQ**

  Install the hashed package into a versioned release directory, atomically repoint the wrapper, set legacy bind to `127.0.0.1`, source legacy plus v2 env files, restart only `com.engram.remote-server`, configure Tailscale Serve HTTPS 443, and verify local health, tailnet TLS health, auth rejection, authenticated v1 compatibility, authenticated v2 object/manifest/receipt round-trip, immutable repeat PUT, read-back hash, and DELETE `405`.

- [ ] **Step 4: Orca dual review gate**

  Give Claude Opus and Grok the HQ deploy marker, hashes, redacted config shape, health/API evidence, listeners, logs, and rollback handle. Fix any Critical/Important finding and re-run the gate before touching M1.

- [ ] **Step 5: Deploy M1**

  Repeat the exact versioned package and API proof using server ID `m1`, its own root/token/key, and its own Tailscale Serve HTTPS endpoint. Leave the existing nginx 8443 configuration unchanged for legacy callers during this milestone.

- [ ] **Step 6: Orca dual review gate**

  Require both reviewers to confirm distinct server identities, package hashes, credentials/root namespaces, no public v2 listener, and independent immutable receipts before client activation.

---

### Task 4: Activate the Client and Prove Production Recovery

**Files/Systems:**

- Local Keychain service: `com.engram.remote-archive-v2`
- Accounts: `replica:hq`, `replica:m1`
- Local settings: `~/.engram/settings.json`
- Installed app: `/Applications/Engram.app`

- [ ] **Step 1: Preserve client rollback state**

  Save the installed app hash/version and an owner-only copy of settings. Record whether each archive Keychain account exists without printing passwords. Do not remove legacy credentials.

- [ ] **Step 2: Store tokens without argv/history exposure**

  Stream each token from its own server over the verified SSH channel into a local Security-framework helper or interactive `security ... -w` prompt; never interpolate it into a command string or argument. Verify both Keychain items exist and differ without printing them.

- [ ] **Step 3: Install and enable**

  Build/sign/verify the current Engram app, install it using the existing release/install path, then write only the non-secret `exactArchiveEnabled` and strict `remoteArchiveV2` settings with the two HTTPS origins. Restart the app/service through the repository-supported mechanism.

- [ ] **Step 4: Production dual-receipt proof**

  Wait for a bounded cycle, query `archiveV2Status`, and require at least one manifest with separately verified `hq` and `m1` receipts. Confirm server-side immutable receipt GET and object read-back match the local manifest and whole-source hashes. Keep every source file intact.

- [ ] **Step 5: HQ-to-M1 fallback proof**

  Disable only the HQ client origin or temporarily stop only HQ after recording its rollback handle; read the same archived session through M1; restore HQ immediately; verify ordinary indexing and local reads remained available throughout.

- [ ] **Step 6: Final review, PR, and closeout**

  Run the full Swift/static/build matrix and two final Orca reviews. Push `bbingz/archive-v2-dual-replica`, create a PR to `main`, and record exact commits, artifact hashes, remote release paths, LaunchAgent/Tailscale states, live receipt proof, rollback handles, skipped checks, and residual FileVault cold-boot risk in the existing runbook/TODO/followups surfaces. Do not merge without green GitHub checks and clean review findings.
