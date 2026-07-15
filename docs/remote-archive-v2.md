# Exact-source remote archive v2 — operations and safety boundary

**Implementation status (2026-07-15):** archive v2 remains default OFF for a
fresh install, while the current deployment is explicitly operator-enabled for
local capture, both private replicas, and opt-in local reclamation. The client
runs Engram `1.0.4 (1205)`. Both live servers run source revision
`38326d62b9c11fcfd561966c6a9d61bbece4277b`; its bodyless HEAD-error fix is
deployed and verified over reused authenticated connections. At 2026-07-15
12:14:20 +0800 all 11,119 remotely eligible bindings were dual-verified with
zero single-replica, queued, retrying, or quarantined rows. Current recovery
drills passed on HQ at 12:23:33 and M1 at 12:24:16, and reclamation then reported
`recoveryLeaseCurrent=true` with a zero-item preview. Configuration in this
document is an example and never enables another installation by itself. No
remote-server deletion or GC surface exists.

Archive v2 preserves the exact source bytes behind supported sessions. It is a
different feature from the older remote-offload protocol:

| Contract | Legacy `/v1/bundles` offload | Exact-source `/v2/archive` |
|---|---|---|
| Purpose | Move regenerable FTS and summary artifacts | Preserve replayable raw source bytes as the fact source |
| Raw transcript upload | Never | Yes, but only after explicit v2 enablement and source proof |
| Local reclamation | May purge regenerable index artifacts and rehydrate them | Initial release was zero-delete; current runtime supports opt-in local source reclamation and CAS eviction after dual receipts plus current recovery drills; remote deletion and GC remain forbidden |
| Remote API | Mutable bundle lifecycle, including legacy DELETE | Immutable object/manifest/receipt API; every v2 DELETE returns `405` |
| Credential namespace | `com.engram.remote-offload` | `com.engram.remote-archive-v2`, accounts `replica:hq` and `replica:m1` |

See [`remote-offload.md`](remote-offload.md) only for the legacy v1 feature.
Neither feature silently enables the other.

## Accepted topology

```text
EngramService on the client Mac
  ~/.engram/archive-v2/ (local immutable CAS + archive.sqlite)
            |
            | direct application-level replication; Tailscale-only
            | no hq-to-m1 replication
            +---------------------------+
            |                           |
            v                           v
  macmini-hq (primary read)    macmini-m1 (fallback replica)
  own site/power/network       different site/power/network
  server id hq                server id m1
  own token/key/root          different token/key/root
```

`macmini-hq` is tried before `macmini-m1` for a cold read. Durability status is
dual-replica only after Engram independently verifies one immutable receipt from
each server for the same bound manifest. The servers never replicate to one
another and neither server is allowed to mint the other server's identity.

Both endpoints are private tailnet services. The current deployment binds each
server directly to its literal Tailscale IPv4 address on port `8787`; the client
therefore uses `http://<tailscale-ip>:8787` with `requireTLS: false`. This is not
cleartext on the physical network: Tailscale supplies authenticated WireGuard
transport, while the archive API still requires its separate bearer token. The
client accepts this HTTP form only for literal Tailscale IPv4 addresses and
rejects DNS, LAN, public, wildcard, and non-Tailscale HTTP origins. Do not use
Tailscale Funnel, a public reverse proxy, a LAN-only address, or a third-party
object store. A separately approved deployment may instead use an HTTPS
MagicDNS name ending in `.ts.net` with `requireTLS: true`.

## Security boundary

- Each replica needs a distinct bearer token, archive-at-rest AES key, archive
  root, and stable server ID. The two client Keychain tokens must also differ.
- Archive v2 credentials must differ from legacy v1 credentials. Server AES
  keys remain on their respective servers; the client sends plaintext over the
  authenticated Tailscale transport and verifies returned content and receipts.
- Hashing identifies the exact raw chunk before compression and encryption.
  Stored envelopes are immutable and verified before a receipt can be issued.
- At-rest encryption protects a powered-off or separately copied store when its
  key is absent. It is not zero-knowledge. An **online compromise** of a running
  server that can read its key can read that server's archive plaintext and use
  its bearer credential. A compromised client can also read any session it is
  authorized to retrieve.
- The v2 API has no successful DELETE path. Explicit DELETE guards return
  `405`; the replica client protocol has no delete method. Legacy v1 DELETE is
  intentionally unchanged and is not evidence of v2 deletion capability.

## Supported source boundary

The first release captures only adapter-declared, replay-proven, single-file
locators for **Claude Code** and **Codex**. Eligibility does not depend on the
session search tier, so `skip` does not mean "discard the only source bytes."

Directories, symlinks, virtual selectors, composite or adjacent-shard sources,
database-backed locators, and adapters without a canonical replay export remain
unsupported or unsafe. That includes the current Kimi context/wire shape,
Copilot checkpoint indexes and bodies, Antigravity path-sensitive sources, and
database-backed Cursor/OpenCode sources. A regular-file `stat` alone never
upgrades one of those locators to supported.

Capture precedes parsing. A stable generation binds device, inode, byte size,
nanosecond mtime and ctime, regular-file mode, and the SHA-256 of all bytes.
Parser failure therefore does not discard an already captured generation.

### Locator discovery limit

Startup discovery for Claude Code and Codex is cooperative-cancellable but
currently **O(N)**: it traverses and sorts the complete current locator set
before applying the work budget. `batchSize` bounds only the post-discovery
capture, bind, policy, and replication work. It does not bound filesystem
discovery time or memory.

True restart-stable bounded discovery needs a **durable locator inventory** or
work queue, normally bootstrapped by one explicit full crawl and maintained by
FSEvents. Directory cookies cannot safely provide that guarantee after a
restart, and a path cursor still has to rescan from the root. Until that future
work lands, operations and UI must not describe discovery itself as bounded.

## Client configuration contract

Configuration is strict and fail-closed. With neither setting present, no
archive directory is created, no archive Keychain item is read, and no archive
network client is constructed.

```jsonc
// ~/.engram/settings.json — example only. These are placeholder Tailscale IPs;
// do not copy them, and do not enable before both servers and recovery evidence
// are ready.
{
  "exactArchiveEnabled": true,
  "remoteArchiveV2": {
    "enabled": true,
    "batchSize": 20,
    "replicas": [
      {
        "id": "hq",
        "serverURL": "http://100.64.0.1:8787",
        "requireTLS": false
      },
      {
        "id": "m1",
        "serverURL": "http://100.64.0.2:8787",
        "requireTLS": false
      }
    ],
    "excludedProjectRoots": ["/absolute/path/to/excluded/project"]
  }
}
```

- `batchSize` is `1...100`; default is `20`.
- Replica IDs are exactly `hq` and `m1`, with distinct canonical origins.
- `excludedProjectRoots` accepts normalized absolute paths only. Local exact
  capture remains possible, but excluded sessions cannot be remotely eligible.
- `ENGRAM_EXACT_ARCHIVE_ENABLED` can strictly override the local-capture flag.
  `ENGRAM_REMOTE_ARCHIVE_V2_CONFIG_JSON` can strictly replace the remote object.
  Invalid booleans, unknown fields, malformed origins, or invalid paths disable
  the unsafe portion and surface a symbolic configuration error.

The client reads bearer tokens from macOS Keychain service
`com.engram.remote-archive-v2`, accounts `replica:hq` and `replica:m1`. The
deployment operation must use update-or-add semantics and must never put tokens
in `settings.json`, shell history, launch arguments, or this repository.

## Server configuration contract

Each server runs the existing `EngramRemoteServer` binary with an additional
v2 store. The current combined binary still requires legacy v1 token/key values;
the v2 token/key/root are separate and must not reuse them.

| Environment variable | `macmini-hq` | `macmini-m1` |
|---|---|---|
| `ENGRAM_REMOTE_ARCHIVE_ENABLED` | `1` | `1` |
| `ENGRAM_REMOTE_ARCHIVE_SERVER_ID` | `hq` | `m1` |
| `ENGRAM_REMOTE_ARCHIVE_ROOT` | absolute hq-only root | different absolute m1-only root |
| `ENGRAM_REMOTE_ARCHIVE_TOKEN` | hq-only random token | different m1-only random token |
| `ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY` | hq-only base64 32-byte key | different m1-only base64 32-byte key |

`ENGRAM_REMOTE_HOST` must be a literal loopback or Tailscale address when v2 is
enabled. The current deployment sets it to each host's exact Tailscale IPv4 and
serves port `8787` directly; there is no current Tailscale Serve configuration.
Never bind the archive listener to `0.0.0.0`, `::`, a LAN/public address, or a
public Funnel. The v2 archive root and legacy v1 store root must be disjoint.

An alternative, separately approved deployment may bind to loopback and expose
the API through tailnet-only Tailscale Serve HTTPS after its local authenticated
API checks pass:

```zsh
tailscale serve --bg --https=443 --yes http://127.0.0.1:8787
```

That alternative requires matching `.ts.net` client origins with
`requireTLS: true`; it is not the current topology and the command above must
not be run as reconciliation. Do not add `:8443`, enable Funnel, or reuse a
LAN/public listener. The existing M1 nginx `:8443` listener is legacy-only for
`/v1/bundles` and is outside archive v2; leave it unchanged.

### Two-site secret and launch procedure (deployed shape; template only)

The current operator deployment follows this shape, but the template below is
not an exact replay log and must not be rerun without separate deployment
authorization. Replace every placeholder only during an approved deployment;
do not paste real credentials into this repository, a ticket, or a command line.
Actual paths, Keychain writes, and launchctl operations require separate
deployment authorization for any new or replacement deployment.

Generate secrets independently on each server. Run the following template once
locally on `macmini-hq` with `replica_id=hq`, and independently on
`macmini-m1` with `replica_id=m1`. Each invocation uses the local CSPRNG for a
different 32-byte bearer token and a different 32-byte AES key. Never copy an
env file, token, or at-rest key from one server to the other, and keep these
directories out of iCloud and other sync tools.

```zsh
# TEMPLATE ONLY — do not run until deployment is separately approved.
set -euo pipefail
umask 077

replica_id='hq' # use 'm1' only when logged in locally to macmini-m1
secret_dir="$HOME/.engram-remote/secrets"
archive_root="$HOME/.engram-remote/archive-v2-$replica_id"
env_file="$secret_dir/archive-v2.env"

/usr/bin/install -d -m 0700 "$secret_dir" "$archive_root"
archive_token="$(/usr/bin/openssl rand -base64 32)"
archive_key="$(/usr/bin/openssl rand -base64 32)"

# zsh printf is a builtin, so these values are not placed in a child argv.
builtin printf '%s\n' \
  'ENGRAM_REMOTE_ARCHIVE_ENABLED=1' \
  "ENGRAM_REMOTE_ARCHIVE_SERVER_ID=$replica_id" \
  "ENGRAM_REMOTE_ARCHIVE_ROOT=$archive_root" \
  "ENGRAM_REMOTE_ARCHIVE_TOKEN=$archive_token" \
  "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY=$archive_key" \
  > "$env_file"
/bin/chmod 0600 "$env_file"
unset archive_token archive_key
```

The combined server also requires the existing legacy v1 variables. Keep those
in a separate owner-only `legacy-v1.env`; do not duplicate them into the v2
file. Install an owner-only wrapper on each host, with the replica-specific
absolute binary path supplied during deployment:

```zsh
#!/bin/zsh
set -euo pipefail
umask 077
set -a
source "$HOME/.engram-remote/secrets/legacy-v1.env"
source "$HOME/.engram-remote/secrets/archive-v2.env"
set +a
exec '/absolute/deployed/path/EngramRemoteServer'
```

```zsh
# TEMPLATE permission assignment; does not start the service.
/bin/chmod 0700 "$HOME/.engram-remote/bin/run-engram-remote"
```

The per-user LaunchAgent plist contains no secrets and no
`EnvironmentVariables` dictionary. Its only `ProgramArguments` entry is the
owner-only wrapper; this remains an illustrative shape rather than a record of
the installed absolute path:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.engram.remote-server</string>
  <key>ProgramArguments</key>
  <array><string>/absolute/owner-only/path/run-engram-remote</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
```

Do not put `launchctl bootstrap`, `bootout`, `kickstart`, Tailscale Serve, DNS,
ACL, certificate, or reverse-proxy changes into an implementation-only run.
Those are persistent production operations and require the separate deployment
approval named above.

Both archive hosts use FileVault without automatic login. A cold power loss
therefore requires manual unlock at the FileVault login screen before the
per-user LaunchAgent can start. Do not weaken FileVault or describe this setup
as unattended cold-boot recovery.

On the Engram client, use **Keychain Access** (not a command containing the
token) to create two Generic Password items. Obtain the hq token directly from
hq through the approved secure channel and store it as service
`com.engram.remote-archive-v2`, account `replica:hq`; independently obtain the
m1 token from m1 and store it as account `replica:m1`. Never paste either token
into `settings.json`, shell history, launch arguments, or logs. In particular,
do not use `security add-generic-password -w <token>` with a literal token.

These offline checks reveal no secret and do not contact or start a server:

```zsh
env_file="$HOME/.engram-remote/secrets/archive-v2.env"
wrapper="$HOME/.engram-remote/bin/run-engram-remote"

# Expect 600 for the env file, 700 for its directory and wrapper.
/usr/bin/stat -f '%Lp %N' "$env_file" "${env_file:h}" "$wrapper"

# Both generated values must decode to exactly 32 bytes; grep emits nothing.
for name in ENGRAM_REMOTE_ARCHIVE_TOKEN ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY; do
  /usr/bin/awk -F= -v key="$name" '$1 == key { print substr($0, index($0, "=") + 1) }' "$env_file" \
    | /usr/bin/openssl base64 -d -A \
    | /usr/bin/wc -c \
    | /usr/bin/grep -Eq '^[[:space:]]*32$'
done

# The local token and key must be nonempty and different; awk emits nothing.
/usr/bin/awk -F= '
  $1 == "ENGRAM_REMOTE_ARCHIVE_TOKEN" { token=substr($0,index($0,"=")+1) }
  $1 == "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY" { key=substr($0,index($0,"=")+1) }
  END { exit !(length(token) && length(key) && token != key) }
' "$env_file"

# Client-side existence checks do not print the stored passwords.
/usr/bin/security find-generic-password -s com.engram.remote-archive-v2 -a replica:hq >/dev/null
/usr/bin/security find-generic-password -s com.engram.remote-archive-v2 -a replica:m1 >/dev/null
```

## Status and retry

The native service exposes strict Unix-socket IPC commands through the bundled
operator CLI. Read current status without changing state:

```zsh
/Applications/Engram.app/Contents/Helpers/EngramCLI archive status --json
/Applications/Engram.app/Contents/Helpers/EngramCLI archive reclaim status --json
```

`archive retry`, `archive recovery-drill`, and reclamation enable/disable/run are
state-changing operator commands; use them only inside an approved operation.
There is no public HTTP status endpoint.

- `archiveV2Status` takes no payload. Inspect `enabled`,
  `localCaptureEnabled`, `remoteReplicationEnabled`, `configurationError`,
  capture/binding/policy counts, unsupported and unsafe counts, per-replica
  queued/retrying/quarantined/verified counts, single-versus-dual verified
  counts, latest verified receipt identities, last capture/replication symbols,
  and `cycleRunning` / `cycleCoalesced`.
- `archiveV2Retry` accepts `{"replicaID":"hq"}`, `{"replicaID":"m1"}`, or
  `{"replicaID":null}`. It resets only quarantined receipt work for the chosen
  replica (or both); it does not delete bytes, bypass eligibility, forge a
  receipt, or force an immediate successful cycle. Check `accepted`,
  `resetRows`, and the bounded symbolic `error`.
- `GET /v1/health` confirms that the combined server process is listening but
  does not prove v2 durability. A verified archive receipt and a successful
  read-back are the v2 evidence; HEAD alone is not.

Backlog replication keeps row-level exponential full-jitter deadlines separate
from its process-local replica breaker. An isolated timeout, network error,
rate-limit response, or server-unavailable response may use exactly one next
claim as a health probe. If that claim verifies, the rest of the batch continues
and only the failed row waits for its durable retry deadline. If the probe also
fails, if no probe is available, or if the resource gate closes before it can
start, the replica pauses for 60 seconds and releases all unstarted claims. This
bounds a real outage to at most two failed claims in a pass without letting one
sporadic request failure stall thousands of unrelated pending rows. HQ and M1
remain independent; authentication and configuration failures still require
explicit attention rather than an automatic probe.

Operational alerts should treat any configuration error, growing quarantine,
stale receipt age, or persistent single-replica count as degraded. One remote
being offline must not turn normal local indexing or reads into a failure.

### 2026-07-15 operational closeout evidence

- Both servers activate release `38326d62` and report the full source revision
  `38326d62b9c11fcfd561966c6a9d61bbece4277b`. A same-connection authenticated
  HEAD-miss then invalid-PUT probe returned a bodyless `404` followed by a
  correctly framed `422` on each site. The previous `3b0b5b1d` release remains
  the rollback anchor.
- Before the one approved catalog repair, the archive catalog was backed up to
  `~/.engram-archive-ops-backups/archive-before-retry-reset-38326d62.sqlite`.
  Its SHA-256 is
  `0a85b9d06824cf20b89f0a1e883f61f384aef456b1555a105601ebb818334ba8`,
  `PRAGMA integrity_check` returned `ok`, and the transaction reset exactly the
  seven pre-authorized stale transport retry rows before the normal drainer
  processed them.
- The terminal eligible snapshot is 11,119 dual-replica verified, zero
  single-replica, zero queued, zero retrying, and zero quarantined. The broader
  status may still say `draining` while discovery classifies unknown or new
  sources; use the eligible receipt/queue invariants for this closeout.
- HQ and M1 recovery drills both reconstructed manifest
  `01013743b72041ca9027d8d8baacf5007ce4feac10e85dff0f3c76f27113cec3`
  (199,159 bytes). The repository also fixes future candidate selection so a
  superseded session binding cannot poison a drill; the installed build 1205
  predates that client-side fix, so this closeout advanced its bounded cursor
  through the known superseded candidates before the successful current
  binding.

## Backup and recovery prerequisites

Automatic local reclamation remains opt-in and fail-closed. A receipt alone does
not authorize source deletion: reclamation additionally requires current
per-replica recovery leases, unchanged source generation, and the reviewed
write-ahead quarantine transition. Before enabling it, the operator must
establish all of the following independently on both sites:

1. Back up each complete v2 archive root without using a mirroring command that
   propagates deletions into the backup.
2. Preserve the current server-held key boundary. A copy of encrypted bytes
   without its original running server/key is not a recoverable replica and
   must not be counted as one. Any independent key-recovery mechanism remains a
   separate security decision and is required before remote erasure/GC can be
   considered.
3. Preserve and verify each server ID/key pairing; never make hq and m1 share a
   key or token.
4. Restore into a clean temporary root and reconstruct sampled sessions from
   immutable manifests and chunks. A health check or catalog-only restore is
   insufficient.
5. Record restore freshness and byte-level verification. Until both current
   drills pass, local reclamation stays paused.

The automated test matrix includes clean-machine reconstruction and fallback
from unavailable hq to m1, but that test is not proof of a production backup,
production secrets, Tailscale ACLs, launchd persistence, or real-site recovery.

## Rollback and disablement

Rollback is non-destructive:

1. Set `remoteArchiveV2.enabled` to `false` to stop remote replication while
   retaining local exact capture, or set `exactArchiveEnabled` to `false` to
   return to the dormant path.
2. Disable automatic reclamation before a rollback with
   `EngramCLI archive reclaim disable`; disabling stops new work but does not
   recreate source files or CAS objects already reclaimed.
3. Restarting/deploying the app or server remains a separate production
   operation and requires explicit authorization.
4. Do not delete `~/.engram/archive-v2`, either server archive root, receipts,
   or Keychain recovery material as part of rollback. Disabling v2 is enough.
5. Sources not yet reclaimed remain local. Completed reclamation is not undone;
   archived fallback remains available only while its local or remote material,
   credentials, and recovery path remain readable.

The first release deliberately provides no archive erasure UI/API. Manual
destruction is an operator action outside Engram and must not be mixed into a
routine rollback.

## Repository verification

The repository gate and test matrix are:

```bash
bash scripts/check-archive-v2-safety.sh
npm test -- tests/scripts/archive-v2-safety-gate.test.ts

cd macos
xcodegen generate
xcodebuild test -project Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS'
xcodebuild test -project Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Engram.xcodeproj -scheme EngramRemoteServerCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The static gate rejects archive filesystem deletion primitives except the three
named temporary cleanup implementations, delete-like methods on
`ArchiveReplicaBackend`, legacy offload commit/purge/vacuum coupling, and any v2
DELETE route outside the two explicit `405` guards. CI also builds the native
app and runs `macos/scripts/release-verify.sh --hygiene-only`, preserving the
Swift-only product-bundle boundary.
