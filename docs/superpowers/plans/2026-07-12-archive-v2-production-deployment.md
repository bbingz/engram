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
- Create: `macos/EngramRemoteServer/Packaging/run-engram-remote.zsh.template`
- Create: `macos/EngramRemoteServer/Packaging/com.engram.remote-server.plist.template`
- Create: `tests/scripts/remote-server-package.test.ts`
- Modify: `.github/workflows/test.yml`
- Modify: `docs/remote-offload.md`
- Modify: `docs/remote-archive-v2.md`

**Interfaces:**

- Command: `macos/scripts/package-remote-server.sh --derived-data <abs-dir> --configuration Release --arch arm64 --source-revision <40-hex-sha> --output <new-empty-dir>` plus a non-mutating `--verify-only <bundle>` mode.
- Output: arm64 `bin/EngramRemoteServer`, adjacent `bin/swift-nio_NIOPosix.bundle`, `Frameworks/EngramRemoteServerCore.framework`, required `Frameworks/libswiftCompatibilitySpan.dylib`, owner-only wrapper/LaunchAgent templates, `SHA256SUMS`, and `BUILD-METADATA.json`.

- [ ] **Step 1: Write failing script tests**

  Require strict argument parsing, Release-only packaging, a new/empty output directory, fixed executable/framework/resource-bundle presence, arm64 support, framework-relative rpath, `swift-stdlib-tool` dependency closure, dylib/framework-before-executable ad-hoc signing, deep strict verification, deterministic sorted SHA-256 manifest, and no credential/environment handling. Require the wrapper/plist templates to contain no token/key or plist `EnvironmentVariables`. Require CI to invoke build → package → verify-only → clean-environment `keygen` after a Release server build.

- [ ] **Step 2: Observe RED**

  Run:

  ```bash
  npm test -- tests/scripts/remote-server-package.test.ts
  ```

  Expected: failure because the packager does not exist.

- [ ] **Step 3: Implement packaging and documentation**

  The script must use `ditto` for the framework and NIO resource bundle, preserve and validate framework symlinks, use active-Xcode `swift-stdlib-tool --print` rather than `find | head` to resolve runtime dylibs, thin to arm64 before signing, sign nested dylib/framework before the executable, run `codesign --verify --deep --strict`, run `lipo -verify_arch arm64`, validate `@executable_path/../Frameworks`, verify sorted hashes, and emit metadata without secrets.

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

### Task 3: Ship a Capability-Protected Archive Operator

**Files:**

- Create: `macos/Shared/Service/EngramCLIArchiveCommand.swift`
- Create: `macos/EngramService/Core/ArchiveV2CredentialProvisioner.swift`
- Create: `macos/scripts/copy-cli-helper.sh`
- Create: `macos/EngramTests/EngramCLIArchiveCommandTests.swift`
- Create: `macos/EngramServiceCoreTests/ArchiveV2OperatorIPCTests.swift`
- Modify: `macos/EngramCLI/main.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/ServiceCapabilityToken.swift`
- Modify: `macos/project.yml`
- Modify: `macos/scripts/release-verify.sh`
- Modify: `tests/scripts/build-release-script.test.ts`

**Interfaces:**

- Bundled executable: `/Applications/Engram.app/Contents/Helpers/EngramCLI`.
- Commands: `archive status`, `archive retry --replica hq|m1|all`, and `archive token set --replica hq|m1 --stdin`.
- New protected IPC: `archiveV2StoreToken`.

- [ ] **Step 1: Write failing parser, secret, IPC, and bundle tests**

  Prove archive commands are parsed before the existing resume/MCP fallback; unknown archive subcommands return usage. `token set` must reject a TTY, token arguments, token environment variables, embedded newlines/NUL, non-canonical base64, and decoded lengths other than 32 bytes. Require `archiveV2StoreToken` to be capability-protected, accept only `hq|m1`, never echo the token, reject a duplicate pair, and return only replica ID, stored/pair-ready/restart-required booleans. Require the release bundle to contain a signed `Contents/Helpers/EngramCLI`.

- [ ] **Step 2: Observe RED**

  Run focused `EngramCLIArchiveCommandTests`, `ArchiveV2OperatorIPCTests`, and the build/release script Vitest. Expected: missing parser/DTO/handler/helper assertions fail before production edits.

- [ ] **Step 3: Implement service-side credential provisioning**

  Add an actor that serializes writes through the existing update-or-add `ArchiveCredentialStore`, validates canonical base64 decoding to exactly 32 bytes, checks the other replica token before and after writing, never deletes, and returns only bounded booleans. Expose it through the peer-euid-checked Unix socket with capability-token protection. Saving reports `serviceRestartRequired=true` because settings/backends/resolver are frozen at startup.

- [ ] **Step 4: Implement and bundle EngramCLI**

  Read at most one bounded token line from non-TTY stdin, send it only over the default product socket, then clear the in-memory buffer. Do not provide a socket override for archive commands. Add the CLI target as an unlinked app dependency, copy/sign it before outer app signing, and make `release-verify.sh` require it.

- [ ] **Step 5: Verify, review, and commit**

  Run focused tests, EngramTests, EngramServiceCore, app build, release verification, XcodeGen drift, safety gate, script matrix, and `git diff --check`. Commit with `feat(archive): ship protected operator commands`, then require Orca Opus + Grok SPEC PASS/CODE APPROVED before Task 4.

---

### Task 4: Add a Zero-Mutation Remote Recovery Probe

**Files:**

- Modify: `macos/Shared/Service/EngramCLIArchiveCommand.swift`
- Modify: `macos/EngramService/Core/ArchiveTranscriptResolver.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler.swift`
- Modify: `macos/EngramService/Core/EngramServiceCommandHandler+ArchiveV2.swift`
- Modify: `macos/Shared/Service/EngramServiceModels.swift`
- Modify: `macos/Shared/Service/EngramServiceClient.swift`
- Modify: `macos/Shared/Service/ServiceCapabilityToken.swift`
- Modify: `macos/EngramCLI/main.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveTranscriptResolverTests.swift`
- Modify: `macos/EngramServiceCoreTests/ArchiveV2OperatorIPCTests.swift`
- Modify: `macos/EngramTests/EngramCLIArchiveCommandTests.swift`

**Interfaces:**

- CLI: `EngramCLI archive probe-remote --session-id <bounded-id> [--json]`.
- Protected IPC: `archiveV2RemoteRecoveryProbe`.
- Response: exactly `tier`, `receiptSHA256`, `manifestSHA256`, `wholeSourceSHA256`.

- [ ] **Step 1: Write failing remote-only resolver and IPC tests**

  Prove the probe accepts only session ID, never accepts URL/path/digest/replica/skip flags, never reads or mutates live source/local CAS/catalog state, and shares the production HQ→M1 remote-selection helper. HQ success returns `tier=hq`; HQ transport/absence/integrity failure falls through to M1; cancellation does not advance; parser is not invoked; checked temp cleanup must succeed before a proof returns.

- [ ] **Step 2: Observe RED**

  Run focused resolver/operator/CLI tests and require missing API failures caused by the new assertions.

- [ ] **Step 3: Implement digest-only proof**

  Lock the latest bound manifest for the session, require the persisted per-replica verified receipt, independently GET and compare canonical receipt bytes/digest/identity, GET and verify manifest, stream and verify every object plus whole-source digest into an owner-only temporary file, then checked-clean it. Return only `hq|m1` and the three digests; do not return session ID, paths, origins, bytes, object lists, or remote error bodies.

- [ ] **Step 4: Verify, review, and commit**

  Run focused tests, full Service/Engram/CLI coverage, safety/static/build gates, and `git diff --check`. Commit with `feat(archive): add remote recovery probe`, then require Orca Opus + Grok SPEC PASS/CODE APPROVED before production deployment.

---

### Task 5: Deploy the HQ Canary and M1 Replica

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

### Task 6: Activate the Client and Prove Production Recovery

**Files/Systems:**

- Local Keychain service: `com.engram.remote-archive-v2`
- Accounts: `replica:hq`, `replica:m1`
- Local settings: `~/.engram/settings.json`
- Installed app: `/Applications/Engram.app`

- [ ] **Step 1: Preserve client rollback state**

  Save the installed app hash/version and an owner-only copy of settings. Record whether each archive Keychain account exists without printing passwords. Do not remove legacy credentials.

- [ ] **Step 2: Store tokens without argv/history exposure**

  Stream each token from its own server over the verified SSH channel into `EngramCLI archive token set --replica <id> --stdin`; never interpolate it into a command string or argument. Verify both Keychain items exist and differ without printing them, then restart the service as required.

- [ ] **Step 3: Install and enable**

  Build/sign/verify the current Engram app, install it using the existing release/install path, then write only the non-secret `exactArchiveEnabled` and strict `remoteArchiveV2` settings with the two HTTPS origins. Restart the app/service through the repository-supported mechanism.

- [ ] **Step 4: Production dual-receipt proof**

  Wait for a bounded cycle, query `archiveV2Status`, and require at least one manifest with separately verified `hq` and `m1` receipts. Confirm server-side immutable receipt GET and object read-back match the local manifest and whole-source hashes. Keep every source file intact.

- [ ] **Step 5: HQ-to-M1 fallback proof**

  Run `EngramCLI archive probe-remote` with both replicas available and require `tier=hq`. Stop only HQ after recording its rollback handle; run the same session probe and require `tier=m1` with equal manifest and whole-source digests but the M1 receipt digest; restore HQ immediately. The probe must not move/delete live sources or local CAS, and ordinary indexing/local reads must remain available throughout.

- [ ] **Step 6: Final review, PR, and closeout**

  Run the full Swift/static/build matrix and two final Orca reviews. Push `bbingz/archive-v2-dual-replica`, create a PR to `main`, and record exact commits, artifact hashes, remote release paths, LaunchAgent/Tailscale states, live receipt proof, rollback handles, skipped checks, and residual FileVault cold-boot risk in the existing runbook/TODO/followups surfaces. Do not merge without green GitHub checks and clean review findings.
