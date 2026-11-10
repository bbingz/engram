import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import Logging
import NIOCore
@testable import EngramRemoteServerCore
import XCTest

final class WebUIRoutesTests: XCTestCase {
    private let viewer = "test-only-viewer-credential"
    private let origin = "https://viewer.example"

    func testUnauthenticatedGetWebHTMLUsesExternalAssetsWithoutInlineCode() async throws {
        let harness = try UIHarness(configuration: configuration())
        for path in ["/web", "/web/"] {
            let response = try await harness.respond(request(path: path, headers: [("Host", "viewer.example")]))
            XCTAssertEqual(response.status, .ok, path)
            XCTAssertEqual(response.headers[.cacheControl], "no-store", path)
            XCTAssertEqual(response.headers[HTTPField.Name("X-Content-Type-Options")!], "nosniff", path)
            let type = response.headers[.contentType] ?? ""
            XCTAssertTrue(type.hasPrefix("text/html"), "\(path) \(type)")
            assertUnchangedCSP(response)
            let html = try await bodyText(response)
            XCTAssertTrue(html.localizedCaseInsensitiveContains("<!doctype html>"), path)
            XCTAssertTrue(html.contains("src=\"/web/app.js\""), path)
            XCTAssertTrue(html.contains("href=\"/web/app.css\""), path)
            XCTAssertFalse(containsInlineScript(html), path)
            XCTAssertFalse(containsInlineStyle(html), path)
            XCTAssertFalse(html.contains(viewer), path)
            for hook in ["login", "logout", "overview", "sessions", "search", "detail", "messages", "more",
                         "workspace", "signed-out", "query", "source-picker", "machineId", "project-picker", "back",
                         "nav-settings", "settings-page", "settings-content", "settings-refresh", "settings-more",
                         "since", "until", "hide-tools", "session-previous", "session-page-status",
                         "search-options", "search-mode", "search-limit", "search-capabilities", "search-result-status",
                         "stats-view-costs", "costs-content", "costs-form", "costs-totals", "costs-rows", "costs-sessions", "costs-more"] {
                XCTAssertTrue(html.contains(hook), "\(path) missing \(hook)")
            }
            XCTAssertTrue(html.contains(">Search<") || html.contains(">Search "), path)
            XCTAssertTrue(html.contains("id=\"source-options\""), path)
            XCTAssertTrue(html.contains("All sources"), path)
            XCTAssertTrue(html.contains("Machine ID"), path)
            XCTAssertTrue(html.contains("All projects"), path)
            XCTAssertTrue(html.contains("for=\"project-query\""), path)
            XCTAssertFalse(html.localizedCaseInsensitiveContains("replica"), path)
            XCTAssertFalse(html.localizedCaseInsensitiveContains("publication"), path)
        }
    }

    func testSameOriginJavaScriptAndCSSAreServedSeparately() async throws {
        let harness = try UIHarness(configuration: configuration())
        let script = try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(script.status, .ok)
        XCTAssertTrue((script.headers[.contentType] ?? "").hasPrefix("text/javascript")
            || (script.headers[.contentType] ?? "").hasPrefix("application/javascript"))
        assertUnchangedCSP(script)
        let css = try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(css.status, .ok)
        XCTAssertTrue((css.headers[.contentType] ?? "").hasPrefix("text/css"))
        assertUnchangedCSP(css)
        let cssText = try await bodyText(css)
        XCTAssertFalse(containsInlineScript(cssText))
        XCTAssertTrue(cssText.contains("overflow-wrap: anywhere"))
        XCTAssertTrue(cssText.contains("--bg:#0f172a"))
        XCTAssertTrue(cssText.contains("--accent:#22c55e"))
        XCTAssertTrue(cssText.contains(".session"))
        XCTAssertTrue(cssText.contains(".badge"))
        XCTAssertTrue(cssText.contains(".message .body"))
        XCTAssertTrue(cssText.contains("font: inherit"))
        XCTAssertTrue(cssText.contains("[hidden]"))
        XCTAssertTrue(cssText.contains("display: none !important"))
        XCTAssertTrue(cssText.contains("showing-detail"))
    }

    func testFoundationAssetsKeepSafeDOMThemeTokensAndPayloadBudget() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for hook in ["page-nav", "active-filters", "toast-region", "health-summary", "tools-col-tools"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        XCTAssertTrue(html.contains("aria-live=\"polite\""))
        XCTAssertTrue(js.contains("createElementNS"))
        for banned in ["insertAdjacentHTML", "outerHTML", "DOMParser", "new Function", "setAttribute(\"style\""] {
            XCTAssertFalse(js.contains(banned), banned)
        }
        XCTAssertTrue(css.contains("color-scheme: light dark"))
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: light)"))
        XCTAssertTrue(css.contains("@media (prefers-reduced-motion: reduce)"))
        XCTAssertTrue(css.contains("var(--mono)"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
        XCTAssertLessThanOrEqual(css.utf8.count, 80_000)
    }

    func testIt8StatsHeatmapAndSortAssetsUseSafeOptionalContracts() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        for hook in ["session-sort", "stats-source", "stats-project", "stats-choices", "dashboard-hours", "dashboard-hours-load"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        XCTAssertTrue(WebUIRoutes.javascript.contains("function renderHourOfWeek("))
        XCTAssertTrue(WebUIRoutes.javascript.contains("missing bins unknown"))
        XCTAssertTrue(WebUIRoutes.javascript.contains("params.set(\"sort\", \"lastActivity\")"))
        XCTAssertTrue(WebUIRoutes.javascript.contains("No filters were silently dropped"))
    }

    func testDashboardAndStatsChartsKeepLazySafeAccessibleAssetContract() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for hook in ["nav-dashboard", "dashboard-page", "dashboard-kpis", "dashboard-activity", "dashboard-cost",
                     "dashboard-sources", "dashboard-projects", "stats-chart", "costs-chart", "tools-chart",
                     "files-chart", "usage-chart", "repos-chart", "ai-chart"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        XCTAssertTrue(html.contains("Heatmap counts session starts, not work duration"))
        XCTAssertTrue(html.contains("id=\"nav-sessions\" href=\"#sessions\" aria-current=\"page\""))
        XCTAssertTrue(js.contains("function dailySeries("))
        XCTAssertTrue(js.contains("function renderChart("))
        XCTAssertTrue(js.contains("async function dashboardRead("))
        XCTAssertTrue(js.contains("overviewStreams === null"))
        XCTAssertTrue(js.contains("version !== dashboardVersion"))
        XCTAssertTrue(js.contains("Table · chart values"))
        XCTAssertTrue(css.contains("#workspace.data-page"))
        XCTAssertTrue(css.contains("--c1:"))
        XCTAssertTrue(css.contains("max-width: 960px"))
    }

    func testTranscriptReadingAssetsKeepSafeOrdinalAndLazyInfoContracts() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for hook in ["detail-header", "detail-view-info", "detail-info-panel", "detail-info-content",
                     "transcript-toolbar", "transcript-filters", "transcript-outline", "transcript-load-all"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        for contract in ["maxFragments=100", "data-line-number", "data-lang", "Thinking (detected)",
                         "Error (detected)", "in loaded", "async function loadDetailInfo()", "agents:\"all\"",
                         "typeof navigator.clipboard.writeText === \"function\"", "limit: \"500\"",
                         "renderMessage(messageBuf.role, JSON.parse(text), messageBuf.ordinal)",
                         "token !== requestEpoch || version !== detailExtrasVersion"] {
            XCTAssertTrue(js.contains(contract), contract)
        }
        XCTAssertTrue(css.contains("#detail-header { position: sticky"))
        XCTAssertTrue(css.contains("max-width: 960px"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
        XCTAssertLessThanOrEqual(css.utf8.count, 80_000)
    }

    func testNavigationSearchAndFindAssetsKeepSafeAddressableContracts() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        for hook in ["shortcuts-dialog", "shortcuts-help", "transcript-find", "transcript-find-query", "transcript-find-status", "transcript-find-preview", "transcript-find-more"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        for contract in ["function parseRoute(", "function routeHref(", "pushState", "replaceState",
                         "addEventListener(\"popstate\", historyChanged)", "addEventListener(\"hashchange\", historyChanged)",
                         "decodeURIComponent", "catch (error)", "budget.remaining", "function updateTranscriptFind()",
                         "event.isComposing", "function editableTarget(", "},350)"] {
            XCTAssertTrue(js.contains(contract), contract)
        }
        // Find searches decoded model fields and provides a safe, separate highlighted context.
        XCTAssertTrue(js.contains("fields.push(call.name"))
        XCTAssertFalse(js.contains("createTreeWalker"))
        XCTAssertFalse(js.contains("NodeFilter"))
        XCTAssertTrue(js.contains("routeFilterKeys"))
        XCTAssertTrue(js.contains("workspaceNode.hidden) return; // Leave the pending URL"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
    }

    func testPolishKeepsAccessibleDialogsScopeProvenanceAndSignedOutCopy() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for contract in ["Sign in to browse your session library.", "Browse your session library.", "identity-status",
                         "aria-modal=\"true\"", "role=\"dialog\"", "aria-controls=\"transcript-find\"",
                         "Message types in loaded messages", "Search availability &amp; index",
                         "Heartbeat shows collector liveness, not capture activity.", "Server configuration and captured-library metadata."] {
            XCTAssertTrue(html.contains(contract), contract)
        }
        for contract in ["function focusVisible(", "function openModal(", "function closeModal(", "addEventListener(\"focusin\"",
                         "Capture & sync provenance", "Clock ahead", "health-timestamp", "createElement(\"time\")", "focusedType"] {
            XCTAssertTrue(js.contains(contract), contract)
        }
        XCTAssertTrue(css.contains(".sign-in-card"))
        XCTAssertTrue(css.contains("input::placeholder, textarea::placeholder { color: var(--muted); opacity: 1; }"))
        XCTAssertTrue(css.contains("@media (prefers-reduced-motion: reduce)"))
        XCTAssertTrue(css.contains("max-width: 960px"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
        XCTAssertLessThanOrEqual(css.utf8.count, 80_000)
    }

    func testMinimapAndSyntaxKeepBoundedSafeLazyAssetContracts() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for hook in ["transcript-minimap-toggle", "transcript-minimap-box", "transcript-minimap", "transcript-minimap-status"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        for contract in ["function tokenizeCode(", "function renderSyntaxCode(", "function renderTranscriptMinimap(",
                         "32768", "2000", "120", "timeline known", "data-start", "data-end"] {
            XCTAssertTrue(js.contains(contract), contract)
        }
        XCTAssertTrue(css.contains(".syntax-keyword"))
        XCTAssertTrue(css.contains("#transcript-minimap"))
        XCTAssertTrue(css.contains("max-width: 960px"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
        XCTAssertLessThanOrEqual(css.utf8.count, 80_000)
    }

    func testCommandPaletteKeepsNativeAccessibleLocalAndFencedContracts() async throws {
        let harness = try UIHarness(configuration: configuration())
        let html = try await bodyText(try await harness.respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        let css = try await bodyText(try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")])))
        for hook in ["command-trigger", "command-dialog", "command-query", "command-results", "command-scope", "command-status", "command-close"] {
            XCTAssertTrue(html.contains("id=\"\(hook)\""), hook)
        }
        for contract in ["<dialog id=\"command-dialog\"", "role=\"combobox\"", "role=\"listbox\"", "Cmd/Ctrl+K"] {
            XCTAssertTrue(html.contains(contract), contract)
        }
        for contract in ["function commandScore(", "function availableCommands(", "commandContext !== commandState()",
                         "revision !== commandRevision", "command-option-", "not global search", "matches.slice(0, 60)",
                         "typeof dialog.showModal === \"function\"", "sessionActionCanWrite === true", "await loadSessionActionAccess()",
                         "sessionActionAccessRequest.key === key", "sessionActionAccessRequest === pending",
                         "JSON.stringify([token, version, id, generation])"] {
            XCTAssertTrue(js.contains(contract), contract)
        }
        XCTAssertTrue(css.contains("#command-dialog"))
        XCTAssertTrue(css.contains(".command-option[aria-selected=\"true\"]"))
        XCTAssertTrue(css.contains("max-width: 960px"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertLessThanOrEqual(js.utf8.count, 360_000)
        XCTAssertLessThanOrEqual(css.utf8.count, 80_000)
    }

    func testJavaScriptUsesTextContentAndExistingAPIsForLoginLogoutAndPaging() async throws {
        let harness = try UIHarness(configuration: configuration())
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertFalse(js.contains("eval("))
        XCTAssertFalse(js.contains("document.write"))
        for path in ["/web/api/auth", "/web/api/overview", "/web/api/sessions", "/web/api/settings", "/web/api/search/status", "/web/api/search", "/messages"] {
            XCTAssertTrue(js.contains(path), path)
        }
        for word in ["credential", "logout", "cursor", "more"] {
            XCTAssertTrue(js.contains(word), word)
        }
        XCTAssertTrue(js.contains("X-Engram-Web"))
        XCTAssertFalse(js.contains(viewer))
        XCTAssertTrue(js.contains("sessionSnapshotId"))
        XCTAssertTrue(js.contains("sessionCursor"))
        XCTAssertTrue(js.contains("sessionFilters"))
        XCTAssertTrue(js.contains("sessionQuery(more)"))
        XCTAssertTrue(js.contains("Network unavailable"))
        XCTAssertTrue(js.contains("messageRequest"))
        XCTAssertTrue(js.contains("No sessions found"))
        // Ready/parsed metadata may label counts; only the admitted generation authorizes reads.
        XCTAssertTrue(js.contains("const generation = detail.transcriptGeneration;"))
        XCTAssertTrue(js.contains("await loadMessages(token, session.sessionId, generation, provenMatch && typeof provenMatch.messageCursor"))
        XCTAssertFalse(js.contains("const generation = detail.lastReady"))
        XCTAssertTrue(js.contains("TextEncoder"))
        XCTAssertTrue(js.contains("utf8Offset"))
        XCTAssertTrue(js.contains("isLastFragment"))
        XCTAssertTrue(js.contains("JSON.parse"))
        XCTAssertTrue(js.contains("toolCalls"))
        XCTAssertTrue(js.contains("payloadSHA256"))
        XCTAssertTrue(js.contains("more-messages"))
        XCTAssertTrue(js.contains("requestEpoch"))
        XCTAssertTrue(js.contains("openDetail(item.sessionId).catch"))
        XCTAssertTrue(js.contains("projectLabel"))
        XCTAssertTrue(js.contains("createElement(\"details\")"))
        XCTAssertTrue(js.contains("signed-out"))
        XCTAssertTrue(js.contains("showSessionList"))
        XCTAssertTrue(js.contains("Select a session"))
        XCTAssertTrue(js.contains("Session expired"))
        XCTAssertTrue(js.contains("expireSession"))
        XCTAssertFalse(js.contains("machine + \" \" + instance"))
    }

    func testJavaScriptExpiresCurrentAuthenticatedRead401WithoutTreatingLogin401AsExpiry() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("function expireSession()"))
        XCTAssertTrue(js.contains("Session expired"))
        XCTAssertTrue(js.contains("response.status === 401 && method === \"GET\""))
        XCTAssertTrue(js.contains("token === requestEpoch"))
        XCTAssertFalse(js.contains("method === \"POST\" && response.status === 401"))
    }

    func testSessionsQuerySendsSnapshotCursorPairOnlyWhenLoadingMore() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("if (more && sessionSnapshotId && sessionCursor)"))
        XCTAssertTrue(js.contains("params.set(\"snapshotId\", sessionSnapshotId)"))
        XCTAssertTrue(js.contains("params.set(\"cursor\", sessionCursor)"))
        XCTAssertTrue(js.contains("new URLSearchParams(more ? sessionFilters : \"\")"))
        XCTAssertTrue(js.contains("clearSessionPaging"))
        XCTAssertTrue(js.contains("async function loadOverview()"))
        XCTAssertTrue(js.contains("Overview is temporarily unavailable."))
        XCTAssertFalse(js.contains("if (overviewEpoch !== requestEpoch) return"))
        XCTAssertFalse(js.contains("let snapshotId"))
        XCTAssertFalse(js.contains("sessionSnapshotId = page.snapshotId || sessionSnapshotId"))
    }

    func testMessagesReassembleCanonicalJSONAndKeepPartialBuffer() async throws {
        let html = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(html.contains("id=\"more-messages\""))
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("acceptFragment"))
        XCTAssertTrue(js.contains("encoder.encode(fragment.payloadFragment"))
        XCTAssertTrue(js.contains("fragment.utf8Offset !== messageBuf.bytes"))
        XCTAssertTrue(js.contains("chunks"))
        let fragmentCode = js.components(separatedBy: "function acceptFragment").last?
            .components(separatedBy: "async function loadMessages").first ?? ""
        XCTAssertFalse(fragmentCode.isEmpty)
        XCTAssertFalse(fragmentCode.contains("Array.from("))
        XCTAssertTrue(js.contains("JSON.parse(text)"))
        XCTAssertTrue(js.contains("payload.content"))
        XCTAssertTrue(js.contains("className = \"body\""))
        XCTAssertTrue(js.contains("role === \"tool\"") || js.contains("role === \"system\""))
        XCTAssertTrue(js.contains("incomplete message"))
        XCTAssertFalse(js.contains("setText(line, (fragment.role || \"\") + \" \" + (fragment.payloadFragment"))
        XCTAssertTrue(js.contains("messageCursor"))
        XCTAssertTrue(js.contains("loadMessages(requestEpoch, messageSessionId, messageGeneration, messageCursor)"))
        XCTAssertTrue(js.contains("if (messageRequest && messageRequest.token === token"))
    }

    func testOpenDetailUsesEpochToDropStalePaints() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("if (token !== requestEpoch) return"))
        XCTAssertTrue(js.contains("bumpEpoch()"))
        XCTAssertTrue(js.contains("openDetail(item.sessionId).catch(function () {})"))
        XCTAssertTrue(js.contains("const generation = detail.transcriptGeneration;"))
        XCTAssertTrue(js.contains("value.generationId === detail.transcriptGeneration"))
        XCTAssertFalse(js.contains("const generation = detail.lastParsed"))
    }

    func testIdentityModeMarksTheDocumentAndTheScriptSignsInSilently() async throws {
        let identity = try EngramRemoteWebConfig(origin: origin, tailscaleServeViewers: "reader@example.com", editors: nil)
        let marked = try await bodyText(try await UIHarness(configuration: identity, tailscaleServeIdentity: true)
            .respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        XCTAssertEqual(marked.components(separatedBy: "data-auth-mode=\"tailscale-serve\"").count, 2)
        XCTAssertTrue(marked.contains("<body data-auth-mode=\"tailscale-serve\">"))
        XCTAssertFalse(marked.contains("reader@example.com"))
        XCTAssertFalse(containsInlineScript(marked))
        let plain = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        XCTAssertFalse(plain.contains("data-auth-mode"))
        XCTAssertTrue(plain.contains("<form id=\"login\">"))
        XCTAssertTrue(marked.contains("<form id=\"login\" hidden>"))
        XCTAssertEqual(plain.replacingOccurrences(of: "<body>", with: "<body data-auth-mode=\"tailscale-serve\">")
            .replacingOccurrences(of: "<form id=\"login\">", with: "<form id=\"login\" hidden>"), marked)
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("document.body.dataset.authMode === \"tailscale-serve\""))
        XCTAssertTrue(js.contains("async function identitySignIn(restorePage)"))
        XCTAssertTrue(js.contains("await authWrite(\"POST\", \"{}\")"))
        XCTAssertTrue(js.contains("if (response.status === 401) { await identitySignIn(false); return; }"))
        XCTAssertTrue(js.contains("identityMode && Date.now() - identitySignInAt > 5000"))
        XCTAssertTrue(js.contains("Your tailnet login is not permitted for this Web origin."))
        XCTAssertTrue(js.contains("\"Signed in as \" + access.login"))
        XCTAssertTrue(js.contains("hidden = signedIn || identityMode"))
        XCTAssertTrue(js.contains("hidden = !signedIn || identityMode"))
    }

    func testWrongHostIsForbiddenAndNonGetWebUIIsRejectedWithoutWeakeningCSP() async throws {
        let harness = try UIHarness(configuration: configuration())
        let forbidden = try await harness.respond(request(path: "/web", authority: "evil.example", headers: [("Host", "evil.example")]))
        XCTAssertEqual(forbidden.status, .forbidden)
        assertUnchangedCSP(forbidden)
        let posted = try await harness.respond(request(.post, path: "/web", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(posted.status, .methodNotAllowed)
        assertUnchangedCSP(posted)
        let api = try await harness.respond(request(path: "/web/api/overview", headers: [
            ("Host", "viewer.example"), ("X-Engram-Web", "1"), ("Origin", "https://viewer.example"),
        ]))
        XCTAssertEqual(api.status, .unauthorized)
        assertUnchangedCSP(api)
    }

    private func configuration() throws -> EngramRemoteWebConfig {
        try EngramRemoteWebConfig(
            origin: origin, viewerCredential: viewer,
            serverBearerCredentials: ["test-v1-bearer"]
        )
    }

    private func request(
        _ method: HTTPRequest.Method = .get,
        path: String,
        scheme: String = "https",
        authority: String? = "viewer.example",
        headers: [(String, String)] = []
    ) -> Request {
        var fields = HTTPFields()
        for (name, value) in headers { fields.append(HTTPField(name: HTTPField.Name(name)!, value: value)) }
        return Request(
            head: HTTPRequest(method: method, scheme: scheme, authority: authority, path: path, headerFields: fields),
            body: RequestBody(buffer: ByteBuffer())
        )
    }

    private func assertUnchangedCSP(_ response: Response, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.headers[.cacheControl], "no-store", file: file, line: line)
        let csp = response.headers[HTTPField.Name("Content-Security-Policy")!] ?? ""
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'"] {
            XCTAssertTrue(csp.contains(directive), directive, file: file, line: line)
        }
        for forbidden in ["'unsafe-inline'", "'unsafe-eval'"] {
            XCTAssertFalse(csp.contains(forbidden), forbidden, file: file, line: line)
        }
    }

    private func containsInlineScript(_ html: String) -> Bool {
        html.range(of: #"<script(?![^>]*\bsrc=)[^>]*>"#, options: .regularExpression) != nil
    }

    private func containsInlineStyle(_ html: String) -> Bool {
        html.localizedCaseInsensitiveContains("<style") || html.localizedCaseInsensitiveContains(" style=")
    }
}

private struct UIHarness: Sendable {
    let boundary: WebRequestBoundary
    let sessions: WebAuthSessionStore
    let tailscaleServeIdentity: Bool

    init(configuration: EngramRemoteWebConfig, tailscaleServeIdentity: Bool = false) throws {
        boundary = WebRequestBoundary(configuration: configuration)
        sessions = WebAuthSessionStore(configuration: configuration)
        self.tailscaleServeIdentity = tailscaleServeIdentity
    }

    func respond(_ request: Request) async throws -> Response {
        let router = Router(context: UITestContext.self)
        WebAuthRoutes.mount(on: router, boundary: boundary, sessions: sessions)
        WebUIRoutes.mount(on: router, tailscaleServeIdentity: tailscaleServeIdentity)
        let responder = router.buildResponder()
        return try await WebRequestBoundary.Middleware<UITestContext>(
            boundary: boundary, sessions: sessions
        ).handle(request, context: UITestContext(source: UITestSource())) { request, context in
            try await responder.respond(to: request, context: context)
        }
    }
}

private struct UITestSource: RequestContextSource {
    let logger = Logger(label: "web-ui-routes-test")
}

private struct UITestContext: RequestContext {
    typealias Source = UITestSource
    var coreContext: CoreRequestContextStorage
    init(source: Source) { coreContext = CoreRequestContextStorage(source: source) }
}

private actor UIBodyBytes {
    private var bytes: [UInt8] = []
    func append(_ buffer: ByteBuffer) { bytes.append(contentsOf: buffer.readableBytesView) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

private struct UIBodyWriter: ResponseBodyWriter {
    let storage: UIBodyBytes
    mutating func write(_ buffer: ByteBuffer) async throws { await storage.append(buffer) }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

private func bodyText(_ response: Response) async throws -> String {
    let storage = UIBodyBytes()
    try await response.body.write(UIBodyWriter(storage: storage))
    return await storage.text
}
