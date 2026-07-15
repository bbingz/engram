# Remote session offload — deployment & operations

> This page documents the legacy `/v1/bundles` feature for regenerable FTS and
> summary artifacts. It does not configure or verify exact raw transcript
> archival. For the separate default-off, zero-delete `/v2/archive` design, see
> [`remote-archive-v2.md`](remote-archive-v2.md).

Remote offload reclaims local disk/CPU by moving the **regenerable index
artifacts** of cold/archived sessions to a server you control, keeping each
session keyword-searchable via a local "shadow" line and rehydrating full content
on demand. It is **opt-in and OFF by default**. Raw transcript files are never
moved — only `sessions_fts` content + summary, AES-GCM encrypted.

> Privacy summary in `docs/PRIVACY.md`. This file is the operator runbook.

## Architecture

```
Engram.app ──IPC──▶ EngramService (helper)        macmini / private host
                       │ RemoteSyncCoordinator        ┌───────────────────────────┐
                       │ EngramRemoteBackend           │ nginx :8443 (TLS, *)       │
                       └─────HTTPS over Tailscale──────▶│   → 127.0.0.1:8787         │
                         (utun, bypasses Local Network) │ EngramRemoteServer (loop)  │
                                                        │   AES-GCM blob store       │
                                                        └───────────────────────────┘
```

- `EngramRemoteServer` — standalone Hummingbird blob server. Plain HTTP, bound to
  loopback (`127.0.0.1:8787`). Bearer auth, AES-GCM at-rest (server-held key).
  **Never bundled in `Engram.app`.**
- **nginx** terminates TLS on `*:8443` and reverse-proxies `/v1/` to the loopback
  server. The app server is never exposed directly.
- The app's `EngramRemoteBackend` (URLSession) refuses non-HTTPS, non-loopback URLs.

## ⚠️ Use a Tailscale IP, not the LAN IP

Offload runs in the **`EngramService` helper** (a separate process), and macOS
**Local Network Privacy** firewalls a background helper off the **local subnet** —
pointing the app at a LAN IP (e.g. `10.0.8.9`) makes every upload fail with
`-1009 "Local network prohibited"`, and a background helper cannot get the
consent prompt.

**Tailscale IPs (`100.x`) route over the `utun` interface, are not the local
subnet, and are exempt from Local Network Privacy.** Point `remoteOffloadServerURL`
at the host's **Tailscale IP** (or a tailnet DNS name). The TLS cert's SAN must
include that IP. (LAN HTTPS still works for `curl`/Terminal, which have Local
Network access — but the app won't.)

## Build a relocatable server package

Build `EngramRemoteServer` on the development Mac and package the complete
Release/arm64 runtime before any separately approved host deployment. The
server core and package dependencies are statically linked into the executable.
The packager resolves the remaining Swift runtime dependencies through the
active Xcode toolchain, ad-hoc signs nested code in dependency order, and writes
a sorted SHA-256 manifest plus source metadata.

```bash
DERIVED_DATA=/tmp/engram-remote-derived
PACKAGE=/tmp/engram-remote-package
SOURCE_REVISION="$(git rev-parse HEAD)"

xcodebuild build \
  -project macos/Engram.xcodeproj \
  -scheme EngramRemoteServer \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO

bash macos/scripts/package-remote-server.sh \
  --derived-data "$DERIVED_DATA" \
  --configuration Release \
  --arch arm64 \
  --source-revision "$SOURCE_REVISION" \
  --output "$PACKAGE"
bash macos/scripts/package-remote-server.sh --verify-only "$PACKAGE"
```

Ship the package as one directory; do not reconstruct it with ad-hoc `cp`
commands on the host. It contains `bin/EngramRemoteServer`, the adjacent
`bin/swift-nio_NIOPosix.bundle`, `Frameworks/`, owner-only wrapper/LaunchAgent
templates, `BUILD-METADATA.json`, and `SHA256SUMS`. Run `--verify-only` again
after transfer and before activation. Host transfer, rollback capture, and
launchd changes are production operations outside this build procedure.

The M1 nginx `:8443` listener described below remains a legacy `/v1/bundles`
route only. Exact-source archive v2 does not use or alter that listener; its
current topology is direct HTTP on each server's literal Tailscale IPv4 address
at port `8787`; Tailscale Serve HTTPS is only a separately approved alternative,
as documented in
[`remote-archive-v2.md`](remote-archive-v2.md).

### Secrets, wrapper, launchd (on the host)

Secrets live in a `0600` env file (never in the plist/argv), sourced by a wrapper:

```bash
# ~/.engram-remote/env  (chmod 600)
ENGRAM_REMOTE_TOKEN=<openssl rand -hex 32>
ENGRAM_REMOTE_AT_REST_KEY=<EngramRemoteServer keygen>   # base64 of 32 bytes, server-held
ENGRAM_REMOTE_STORE=/Users/<you>/.engram-remote/store
ENGRAM_REMOTE_HOST=127.0.0.1
ENGRAM_REMOTE_PORT=8787

# ~/.engram-remote/run.sh  (chmod 700)
#!/bin/bash
set -a; . ~/.engram-remote/env; set +a
exec ~/.engram-remote/bin/EngramRemoteServer
```

LaunchAgent `~/Library/LaunchAgents/com.engram.remote-server.plist` runs `run.sh`
with `RunAtLoad` + `KeepAlive`. Load it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.engram.remote-server.plist
curl -s 127.0.0.1:8787/v1/health    # → ok
```

> A GUI LaunchAgent only runs while the user is logged in (use a LaunchDaemon for
> login-independent start). Rotating `ENGRAM_REMOTE_AT_REST_KEY` makes existing
> stored bundles undecryptable — only rotate against an empty/rehydrated store.

## TLS reverse proxy (nginx + private CA)

Generate a private CA + a server cert whose SAN includes the **Tailscale IP**,
loopback, and (optionally) the LAN IP / hostname. Apple trust requires SAN +
`extendedKeyUsage=serverAuth` + ≤825-day validity.

```bash
cd ~/.engram-remote/tls
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=Engram Remote Internal CA" -out ca.crt
openssl genrsa -out server.key 2048
cat > san.cnf <<EOF
subjectAltName=IP:<TAILSCALE_IP>,IP:127.0.0.1,IP:<LAN_IP>,DNS:<host>.local,DNS:localhost
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
basicConstraints=CA:FALSE
EOF
openssl req -new -key server.key -subj "/CN=<host>.local" -out server.csr
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -sha256 \
  -extfile san.cnf -out server.crt
chmod 600 ca.key server.key
```

nginx vhost (drop into the `include servers/*.conf` dir; `client_max_body_size`
must exceed the 64 MiB `maxBundleBytes`):

```nginx
server {
    listen 8443 ssl;
    http2 on;
    ssl_certificate     /Users/<you>/.engram-remote/tls/server.crt;
    ssl_certificate_key /Users/<you>/.engram-remote/tls/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 96m;
    location /v1/ { proxy_pass http://127.0.0.1:8787; proxy_read_timeout 120s; }
    location /   { return 404; }
}
```

`nginx -t && nginx -s reload`.

### Trust the CA on each client

URLSession does standard TLS validation (no pinning), so copy `ca.crt` to each
client and trust it once (needs admin):

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
curl https://<TAILSCALE_IP>:8443/v1/health    # → ok (validates against the trusted CA)
```

## Enable the app

```jsonc
// ~/.engram/settings.json
"remoteOffloadEnabled": true,
"remoteOffloadBackend": "http",
"remoteOffloadServerURL": "https://<TAILSCALE_IP>:8443",
"remoteOffloadColdAgeDays": 365    // visible sessions cold this long become eligible
```

Store the bearer token in the Keychain so the helper can read it:

```bash
security add-generic-password -A -s com.engram.remote-offload -a default -w <TOKEN>
```

Restart `Engram.app` so the service rebuilds its coordinator with the new config.

## Operations

- **Status:** the service answers `remoteSyncStatus` IPC with
  `{enabled, backendKind, localCount, offloadedCount, pendingOffload, pendingRehydrate}`.
- **Eligibility / candidate window:** each cycle scans the **500 largest local
  sessions** (`ORDER BY size_bytes DESC LIMIT 500`) then applies the policy
  (hidden/archived always; visible cold ≥ `coldAgeDays`; never `skip` or
  subagents). Sessions smaller than the 500th-largest are not considered until the
  larger ones are offloaded — an all-hidden run is a no-op if the hidden sessions
  are small. Up to `remoteOffloadBatch` (default 20) move per cycle.
- **Rehydrate:** opening an offloaded session enqueues a rehydrate (read-path
  lazy); the next cycle re-downloads and restores full FTS. Disk is reclaimed by
  `VACUUM` once freed pages exceed the threshold.
- **Disable:** set `remoteOffloadEnabled: false` (already-offloaded sessions stay
  offloaded and rehydrate on access). Settings changes take effect immediately for
  IPC-triggered cycles but need a service restart for the background loop.
- **Reversible:** rehydrate restores content byte-for-byte; the encrypted bundle
  stays on the server for re-offload.

## Verify

`RemoteSyncCoordinatorTests.testLiveOffloadRehydrateAgainstDeployedServer` runs a
real offload→rehydrate against a deployed server. It is gated — provide
`ENGRAM_LIVE_OFFLOAD_URL` + `ENGRAM_LIVE_OFFLOAD_TOKEN` (or `~/.engram-live-offload.json`
with `{"url":...,"token":...}`) or it skips. If the test process can't reach the
server (Local Network Privacy / VPN routing), tunnel to loopback first
(`ssh -L 8788:127.0.0.1:8443 HOST` → `https://127.0.0.1:8788`), which is exempt
from Local Network Privacy and matches the cert's `127.0.0.1` SAN.
