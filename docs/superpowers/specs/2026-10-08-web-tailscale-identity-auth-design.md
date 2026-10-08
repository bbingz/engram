# Design Doc: Web login from Tailscale Serve identity headers

- **Status**: In review (owner chose this option on 2026-10-08; phase 1
  implemented the same day on branch
  `feat/web-tailscale-identity-auth-20261008`, not yet merged or deployed)
- **Owner**: RemoteServer / Web maintainers
- **Date**: 2026-10-08
- **Related**: `docs/superpowers/specs/2026-09-05-collector-server-web-design.md`
  (Web auth rows at lines 588-600, Funnel exclusion at line 209);
  `docs/invariants.md` "Web Reader and Editor Authority" (line 166);
  `docs/followups.md` `cutover-web-editor-hardening-1` (line 22);
  `CHANGELOG.md` 2026-10-07 (HQ Web reader proof as viewer);
  Tailscale KB "Tailscale Serve", identity headers section,
  https://tailscale.com/kb/1312/serve (fetched 2026-10-08).

All `path:line` anchors are at commit `466879ff` unless marked otherwise.

## Problem

The Web reader on HQ is reached only through a shared static credential. The
owner's verdict on 2026-10-08 was that the login is too crude. The concrete
defects, observed on HQ the same day:

- One viewer credential and one optional editor credential are the whole
  identity model. Nothing records who logged in or who changed an alias or
  moved a project; the service audits Web project moves as actor `mcp`
  (`macos/EngramService/Core/EngramServiceCommandHandler.swift:2735`,
  default applied by `normalizedActor` at `:3585`).
- Sessions expire 900 seconds after login with no renewal
  (`macos/EngramRemoteServer/Core/WebAuthSessionStore.swift:7`), so a reader
  is sent back to the form every 15 minutes.
- Login throttling is one global five-attempt window per 60 seconds
  (`WebAuthSessionStore.swift:52`); any tailnet member can lock the editor
  out by failing five times.
- Both credentials sit in plaintext in the receiver LaunchAgent environment
  on HQ (`~/Library/LaunchAgents/com.engram.capture-core.receiver.plist`,
  keys `ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL` and
  `ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL`). Rotation means editing the plist
  and restarting the receiver.
- The credential digest is unsalted SHA-256 (`EngramRemoteWebConfig.swift:
  60-62`). That is fine for a random high-entropy string and weak for a
  human-chosen one; nothing enforces the former.

Why now: cutover decision D5 (`2026-10-02-hq-local-collector-cutover-design.md`
§8) keeps the App off HQ, so the Web reader is the only reader on the busiest
host and the login sits on the daily path.

The deployment already has a stronger identity source that the receiver
ignores. On HQ the receiver binds `127.0.0.1:18787` and `tailscale serve`
publishes it as `https://macmini-hq.tail1cb16.ts.net:8443` (tailnet only,
Tailscale 1.102.5). The Tailscale KB states that Serve adds
`Tailscale-User-Login`, `Tailscale-User-Name` and
`Tailscale-User-Profile-Pic` to every request it proxies to the backend,
strips client-supplied headers of those names before adding its own, and
omits them for Funnel traffic and for traffic from tagged devices. The
tailnet currently has one user; `tailscale whois` prints the login as
`zzbhlx@gmail.com` for both HQ and the Daily Mac.

## Goals / Non-goals

Goals:

1. A tailnet user opens the Web origin and is signed in; no password.
2. Read and write authority come from explicit allowlists of exact Tailscale
   logins, not from which shared string was typed.
3. Every existing CSRF, Host, Origin, marker-header and cookie guarantee in
   `docs/invariants.md` "Web Reader and Editor Authority" stays in force.
4. Explicit opt-in. A deployment that does not set the new mode behaves
   byte-for-byte as today.
5. The Web write path can name the tailnet login as the audit actor
   (phase 2, separate PR; see Rollout).

Non-goals:

- WebAuthn, passkeys, OIDC or any browser-side dependency. The Web design
  forbids external CDN and runtime Node (`2026-09-05` design line 593).
- Tailscale Funnel exposure. Identity headers are absent there and public
  exposure is already excluded (`2026-09-05` design line 209).
- Per-user data scoping. Every permitted login sees the same corpus.
- Changing archive v1/v2 or MCP bearer authentication.
- Sliding sessions or per-client throttling for credential mode. Those stay
  parked in `docs/followups.md` for deployments that keep credential mode.

## Current state

Configuration. `EngramRemoteWebConfig.fromEnvironment`
(`macos/EngramRemoteServer/Core/EngramRemoteWebConfig.swift:68-85`) turns
the Web on with `ENGRAM_REMOTE_WEB_ENABLED=1`, requires an HTTPS
`ENGRAM_REMOTE_WEB_ORIGIN` and `ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL`, and
takes an optional `ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL`. Both credentials
must differ from every server bearer token; the app re-checks that at
startup (`EngramRemoteServerApp.swift:98-103`). The cookie name is
`__Host-engram_web` outside loopback tests (`EngramRemoteWebConfig.swift:64`).
The server config reads the bind host from `ENGRAM_REMOTE_HOST`, default
loopback (`EngramRemoteServerConfig.swift:169-170`).

Sessions. `WebAuthSessionStore.login(credential:)`
(`WebAuthSessionStore.swift:43-77`) purges expired sessions, applies the
global attempt window, compares the SHA-256 digest of the submitted string
against the viewer and editor digests in constant time (`:59-60`), caps live
sessions at 64, mints a 32-byte random token and stores only its digest with
`expiresAt` and `canWrite`. Nothing is persisted.

Routes. `POST /web/api/auth` accepts exactly `{"credential": "<string>"}`
(`WebAuthRoutes.swift:24, 107-124`) and answers 204 with the hardened cookie
(`:133-137`), 401, 429 with `Retry-After`, or 503. `GET /web/api/auth`
returns `{"canWrite": bool}` for a live session, else 401 with no body.
`DELETE /web/api/auth` requires a `{}` body and revokes the session.

Boundary. `WebRequestBoundary` requires the exact configured authority in
the request target and any `Host` header (`WebRequestBoundary.swift:10-14`),
a single `X-Engram-Web: 1`, and either an exact `Origin` or, for GET only,
same-origin fetch metadata (`:16-27`). The middleware (`:168` onward) applies
those checks per path class and requires a live session for every
`/web/api/*` route except the login POST.

Write actor. Web write routes decode the browser body straight into the
service request type and forward it (`WebWriteRoutes.swift:214`). The Web
project request models carry no actor
(`macos/Shared/Service/EngramServiceWebProjectModels.swift`); the service
side models do (`EngramServiceProjectModels.swift:9, 80, 116`) and default
to `mcp`.

UI. The page renders a single `Credential` password field
(`WebUIRoutes.swift:34-37`); `login()` posts it (`:2376-2391`); every 401
calls `expireSession()` (`:928, 1311, 1387, 1467, 2100, 2127, 2270, 2352`),
which shows the signed-out view.

Packaging. The remote wrapper sources `secrets/web.env` when present
(`macos/EngramRemoteServer/Packaging/run-engram-remote.zsh.template:11-12`);
the P3 planner treats `web-env-file` as optional
(`scripts/plan-headless-install.mjs:58, 448-449`). HQ does not use that file
today; its Web environment is in the LaunchAgent plist.

## Proposed design

### 1. A mode switch in the Web configuration

New environment key `ENGRAM_REMOTE_WEB_AUTH` with two values:

- `credential` (the default when the key is absent): today's behavior,
  unchanged.
- `tailscale-serve`: identity comes from the `Tailscale-User-Login` header
  that the local Serve proxy adds.

In `tailscale-serve` mode the config requires:

- `ENGRAM_REMOTE_WEB_VIEWERS`: comma-separated exact Tailscale logins allowed
  to read. Required, at least one entry.
- `ENGRAM_REMOTE_WEB_EDITORS`: optional comma-separated exact logins allowed
  to write. An editor can also read; a login in both lists is an editor.
- Neither `ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL` nor
  `ENGRAM_REMOTE_WEB_EDITOR_CREDENTIAL` may be set. Presence is a config
  error, so no shared secret can linger next to the identity mode.
- `ENGRAM_REMOTE_HOST` must be a loopback literal. The only legitimate path
  for an identity header is the Serve proxy on the same host; a receiver
  bound to a tailnet or LAN address would accept a header any peer can
  write. Non-loopback is a config error in this mode.
- `ENGRAM_REMOTE_WEB_ORIGIN` keeps its HTTPS requirement unchanged.

Allowlist parsing: split on `,`, trim nothing, reject empty entries,
whitespace, control characters, entries longer than 254 bytes, and
duplicates within a list. Matching is exact and case-sensitive against the
header value; the configured string must equal what `tailscale whois`
prints.

`EngramRemoteWebConfig` gains an `authority` enum with two cases,
`credential(viewerDigest:editorDigest:)` and
`tailscaleServe(viewers:editors:)`. The existing public initializer keeps
its signature and produces the credential case so current tests compile; a
second initializer builds the identity case. The `credentialMustBeDistinct`
re-check in `EngramRemoteServerApp` runs only for the credential case.

### 2. Minting a session from an identity

Sessions, cookies and the middleware stay. The cookie is what proves that
the browser went through `POST /web/api/auth` with an exact `Origin`; an
identity header alone is also present on a cross-site request the user's
browser was tricked into sending, so it must not grant authority by itself.

`WebAuthSessionStore` gains `login(identity: WebIdentity) -> LoginResult`.
`WebIdentity` holds the login string. The method:

- purges expired sessions exactly as the credential path does;
- does not consult the attempt window (there is no secret to guess) but
  still enforces the 64-session capacity and the token-collision guard;
- resolves `canWrite` from the editor list and rejects a login in neither
  list with a new `LoginResult.forbidden`;
- stores the login in the session record so `actor(sessionToken:)` can
  return it (used by phase 2 and by `GET /web/api/auth`).

The credential path is untouched. In credential mode
`login(identity:)` is never called; in identity mode `login(credential:)`
is never called. The store receives the config and refuses the wrong entry
point with `.unavailable`, which a guard test pins.

Session lifetime stays 900 seconds absolute. The UI re-mints silently (§5),
so the limit bounds exposure without interrupting the reader.

### 3. Extracting the identity

`WebRequestBoundary.tailscaleIdentity(in:)` returns a `WebIdentity` only
when the request carries exactly one `Tailscale-User-Login` header whose
value is non-empty, printable ASCII without whitespace, and at most 254
bytes. Two headers, an empty value or a malformed value yield `nil`, which
the login route turns into 401. `Tailscale-User-Name` and
`Tailscale-User-Profile-Pic` are not read.

The boundary consults the header only when the configuration is in
`tailscale-serve` mode. In credential mode the header is never read, so a
forged header on a credential deployment has no effect; a guard test pins
that too.

### 4. Auth routes

`POST /web/api/auth` in identity mode:

- the same `validateAPI(requiresOrigin: true)` as today, so the mint is
  CSRF-safe;
- the body must be exactly `{}` (the logout check reused); a credential
  body is 400, so a stale page that still posts a credential cannot log in;
- no identity header: 401, empty body;
- identity not in any list: 403, empty body (the lists are never echoed);
- success: 204 with the same hardened cookie.

`GET /web/api/auth`:

- In identity mode the 200 body becomes `{"canWrite": bool, "login":
  "<login>"}`. Credential mode keeps `{"canWrite": bool}` unchanged.
- 401 responses are unchanged in both modes. The UI learns the mode from
  the document instead: identity mode serves the same HTML with
  `<body data-auth-mode="tailscale-serve">` and the credential form shipped
  `hidden`, so no request is spent on mode discovery, the form never
  flashes before the script runs, and every credential-mode response stays
  byte-identical.

`DELETE /web/api/auth` is unchanged.

### 5. UI

- On load the page probes the session list as today. A 401 in identity
  mode (read from the body attribute) posts `{}` once; 204 re-runs the
  normal signed-in restore and then shows `Signed in as <login>` from
  `GET /web/api/auth`; 403 shows "Your tailnet login is not permitted for
  this Web origin"; any other failure shows the signed-out view. In
  credential mode a 401 shows today's form.
- `expireSession()` in identity mode re-mints once instead of showing the
  form, with a five-second floor between attempts so a mint that is
  immediately rejected cannot loop; if the re-mint fails it falls back to
  the signed-out view. A reader never sees the 15-minute boundary.
- The credential form and the `Log out` button are hidden in identity
  mode. There is nothing to log out of; closing the tailnet session is the
  logout.

### 6. Phase 2: actor propagation (separate PR)

Add an optional `actor` to the Web write envelope for the routes whose
service request has one (alias add/remove, project move, archive, undo,
move-batch). The RemoteServer sets it from `sessions.actor(sessionToken:)`
and never from the browser body; in credential mode it sets `web-editor`.
The service maps it through to the existing `actor` field, so audit rows
name the tailnet login instead of `mcp`. This touches IPC DTOs on both
sides and the write-client allowlist, so it gets its own tests and PR.

### 7. Deployment shape

HQ receiver plist environment: add `ENGRAM_REMOTE_WEB_AUTH=tailscale-serve`,
`ENGRAM_REMOTE_WEB_VIEWERS=<login>`, `ENGRAM_REMOTE_WEB_EDITORS=<login>`;
delete both `*_CREDENTIAL` keys. With no secret left, the plist is an
acceptable home; `secrets/web.env` remains an option for the P3 wrapper.
Nothing changes on the Serve side.

## Invariants affected

- **Web Reader and Editor Authority** (`docs/invariants.md:166`). The
  statement is extended, not replaced: in `tailscale-serve` mode the viewer
  and editor authority of a session comes from the exact
  `Tailscale-User-Login` the local Serve proxy asserts, matched against
  explicit allowlists; the receiver must bind loopback; no shared Web
  credential may be configured; the header is never read in credential mode;
  session, cookie, exact-Host, marker-header and Origin rules are unchanged.
  The throttling sentence becomes credential-mode only. The sentence about
  not isolating a compromised RemoteServer process gains "or any process
  that can open the receiver's loopback port". Enforced-by adds no new path
  unless `WebIdentity` lands in its own file; Verified-by adds the tests in
  the test plan. Gate stays `none`. The ledger edit ships in the same PR.
- No other entry is touched. Archive, MCP and capture authority are not on
  this path.

## Alternatives considered

- Keep the credential and add sliding sessions plus per-client throttling.
  Fixes the interruption, not the missing identity or the plaintext secret.
- Bind the receiver to the Tailscale address and resolve the peer with
  `tailscale whois`, no Serve. The receiver speaks plain HTTP, so this loses
  the HTTPS origin the Web design requires.
- Read `X-Forwarded-For` through Serve and call the Tailscale LocalAPI
  `whois`. Serve does add that header (verified 2026-10-08, see the test
  plan), but it adds a LocalAPI socket dependency, and a locally forged
  forwarded address is no harder than a locally forged login header.
- WebAuthn or OIDC. Browser-side or external dependencies the Web design
  forbids, for a single-user tailnet.
- Funnel with identity. Funnel carries no identity headers and public
  exposure is excluded.

## Test plan

Config (`WebConfigTests`): mode absent equals `credential`; unknown mode is
an error; identity mode with any `*_CREDENTIAL` key is an error; identity
mode with a non-loopback `ENGRAM_REMOTE_HOST` is an error; empty,
whitespace, control-character, over-long and duplicate allowlist entries are
errors; a credential-mode environment round-trips unchanged.

Session (`WebAuthSessionTests`): `login(identity:)` mints a viewer for a
viewer-list login and an editor for an editor-list login; matching is
case-sensitive (`Zzbhlx@…` is not `zzbhlx@…`); a login in neither list is
`forbidden`; identity logins ignore the attempt window and respect the
64-session cap; `actor(sessionToken:)` returns the login; the credential
store answers `.unavailable` to `login(identity:)` and the identity store
answers `.unavailable` to `login(credential:)`.

Routes (`WebAuthRouteTests`): identity POST requires `{}` and an exact
`Origin`; a credential body in identity mode is 400; no header is 401; two
headers are 401; an unlisted login is 403 with an empty body; a forged
`Tailscale-User-Login` on a credential-mode responder is ignored and the
credential path still decides; GET 401 bodies carry only `mode`; GET 200
bodies carry `login` only in identity mode and never a credential or token.

Integration (`WebServerIntegrationTests`): default-off still returns 404
with zero factory calls; an identity-mode real responder sets the same
hardened cookie attributes as credential mode; a viewer identity POST to a
write route is 403 before the write surface is called (the
`testViewerPostIs403AndDoesNotCallWriteSurface` pattern).

UI (`WebUIRoutesTests`): the bundled HTML/JS contains the silent-mint path,
hides the form and logout in identity mode, and shows the 403 copy.
Behavior (`tests/scripts/collector-web-ui.test.ts`, which runs the shipped
script in a fake DOM): a 401 restore probe in identity mode posts `{}` and
re-runs the restore, then shows `Signed in as <login>`; a 403 shows the
not-permitted copy with the form still hidden; an expired authenticated read
re-mints once and a second 401 inside the five-second floor does not; and
credential mode never posts an identity login.

Not tested in CI: the real Serve header injection, which needs a tailnet.
It is covered once by the manual pre-check below, recorded in this doc
before implementation, and repeated after Tailscale upgrades on HQ.

Pre-implementation check on HQ (owner-authorized host change, reversible):
run a loopback echo server on a spare port, publish it with
`tailscale serve --bg --https=8444 http://127.0.0.1:<port>`, request
`https://macmini-hq.tail1cb16.ts.net:8444/` from another tailnet device and
confirm the echo shows `Tailscale-User-Login: zzbhlx@gmail.com`, then
`tailscale serve --https=8444 off`. Also send a client-supplied
`Tailscale-User-Login: attacker@example` on the same request and confirm the
echo shows only the Serve-asserted value.

Result, 2026-10-08 (owner-authorized, Tailscale 1.102.5 on HQ): **PASS.**
A Python header-echo server on `127.0.0.1:18799` was published on port 8444
and requested twice, from HQ itself and from the Daily Mac over SSH, each
request carrying `Tailscale-User-Login: attacker@example` and
`Tailscale-User-Name: Mallory`. Both echoes showed exactly one
`Tailscale-User-Login: zzbhlx@gmail.com`, `Tailscale-User-Name: Bing Z`,
`Tailscale-User-Profile-Pic: <url>`, `Tailscale-Headers-Info:
https://tailscale.com/s/serve-headers`, plus `X-Forwarded-For` with the
requesting node's tailnet address (`100.125.101.60` and `100.75.72.13`),
`X-Forwarded-Host: macmini-hq.tail1cb16.ts.net:8444` and
`X-Forwarded-Proto: https`. The spoofed values were removed, not appended.
A direct request to `127.0.0.1:18799` bypassing Serve delivered the spoofed
header unchanged, which is risk R1 as stated. The mapping was removed and
`tailscale serve status` returned to the two pre-existing entries; the 8443
Web origin answered 200 throughout.

Note on the alternatives: Serve does add `X-Forwarded-For`, contrary to the
KB summary read on 2026-10-08. The design still does not use it; the
identity header is the documented contract and the forwarded address is as
forgeable on loopback as the login.

No `_repro` test: this is new behavior, not a bug fix.

## Rollout

- Phase 1 (this doc): `EngramRemoteWebConfig`, `WebAuthSessionStore`,
  `WebRequestBoundary`, `WebAuthRoutes`, `WebUIRoutes`, tests, ledger edit.
  RemoteServer rebuild only; no service, App, MCP or schema change.
- Phase 2: actor propagation (§6), its own design addendum and PR.
- HQ deploy, after the pre-check passes: build and package with
  `macos/scripts/package-remote-server.sh`, `--verify-only`, back up the
  receiver plist, apply the §7 environment, `bootout` then `bootstrap`
  `com.engram.capture-core.receiver`, confirm `/v1/health` 200 on both
  origins, `GET /web/api/auth` 401 body shows the identity mode, and the
  Web origin opened from the MacBook signs in without a form. Each of those
  is a host mutation and needs owner authorization at the time.
- Revert: restore the backed-up plist and the prior package directory and
  bootstrap again. Sessions are process-local, so nothing persists across
  the revert.
- Deployments that never set `ENGRAM_REMOTE_WEB_AUTH` see no change.

## Risks and open questions

- **R1 Same-host header forgery.** Any process that can connect to
  `127.0.0.1:18787` can send a `Tailscale-User-Login` header. Likelihood
  low on a single-user host; impact is Web viewer or editor authority. That
  process can already read the plist credentials and the service capability
  token today, so no new privilege is created. Mitigation: the loopback-bind
  requirement and the explicit residual sentence in the ledger entry.
- **R2 Tailscale behavior drift.** The header contract is documented, not
  versioned. Mitigation: the pre-check is repeated after Tailscale upgrades
  on HQ and the KB fetch date is recorded here.
- **R3 Identity is the tailnet user, not the OS user.** A device signed into
  the tailnet grants Web access to whoever is at its keyboard. Same exposure
  as today's cookie; accepted.
- **R4 Tagged devices and Funnel never carry the header** and get 401
  forever. Document in the 401 copy; no fallback is planned.
- **Q1** Show `Tailscale-User-Name` next to the login? Proposed no; the
  login is unambiguous and one fewer header is parsed.
- **Q2** Keep 900 seconds absolute with silent re-mint, or lengthen?
  Proposed keep; the reader no longer notices it.
- **Q3** Must `ENGRAM_REMOTE_WEB_EDITORS` be a subset of
  `ENGRAM_REMOTE_WEB_VIEWERS`? Proposed no; editors read implicitly.
- **Q4** The P3 planner's `web-env-file` check
  (`scripts/plan-headless-install.mjs:448-449`) may assume credential keys.
  Verify at implementation and add a mode-aware branch if so.
