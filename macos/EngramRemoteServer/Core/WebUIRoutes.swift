import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Same-origin static viewer. HTML/JS/CSS are constant strings; no inline script or style.
enum WebUIRoutes {
    static func mount<Context: RequestContext>(on router: Router<Context>) {
        router.get("/web") { _, _ in asset("text/html; charset=utf-8", html) }
        router.get("/web/app.js") { _, _ in asset("text/javascript; charset=utf-8", javascript) }
        router.get("/web/app.css") { _, _ in asset("text/css; charset=utf-8", css) }
    }

    private static func asset(_ type: String, _ body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = type
        headers[.contentLength] = "\(body.utf8.count)"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: body)))
    }

    static let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Engram</title>
        <link rel="stylesheet" href="/web/app.css">
        </head>
        <body>
        <header>
        <h1>Engram</h1>
        <form id="login">
        <label>Credential <input id="credential" name="credential" type="password" autocomplete="current-password"></label>
        <button type="submit">Log in</button>
        </form>
        <button id="logout" type="button">Log out</button>
        <p id="status"></p>
        </header>
        <main>
        <section id="overview"></section>
        <form id="search">
        <input id="query" name="query" type="search" placeholder="Search">
        <input id="source" name="source" placeholder="source">
        <input id="machineId" name="machineId" placeholder="machine">
        <input id="projectKey" name="projectKey" placeholder="project">
        <button type="submit">Search</button>
        </form>
        <section id="sessions"></section>
        <button id="more" type="button">Load more</button>
        <section id="detail"></section>
        <section id="messages"></section>
        <button id="more-messages" type="button">Load more messages</button>
        </main>
        <script src="/web/app.js"></script>
        </body>
        </html>
        """

    static let css = """
        html { font-family: system-ui, sans-serif; line-height: 1.4; }
        body { margin: 0 auto; max-width: 52rem; padding: 1rem; }
        header, form, section { margin-bottom: 1rem; }
        input { margin: 0.25rem 0.25rem 0.25rem 0; }
        button { margin-right: 0.25rem; }
        #sessions button, #more, #more-messages { display: block; margin: 0.35rem 0; }
        #messages p { white-space: pre-wrap; }
        """

    static let javascript = """
        const statusNode = document.getElementById("status");
        const overviewNode = document.getElementById("overview");
        const sessionsNode = document.getElementById("sessions");
        const detailNode = document.getElementById("detail");
        const messagesNode = document.getElementById("messages");
        const moreNode = document.getElementById("more");
        const moreMessagesNode = document.getElementById("more-messages");
        const encoder = new TextEncoder();
        const decoder = new TextDecoder("utf-8", { fatal: true });
        let sessionSnapshotId = "";
        let sessionCursor = "";
        let messageSessionId = "";
        let messageGeneration = "";
        let messageCursor = "";
        let messageBuf = null;
        let requestEpoch = 0;
        function bumpEpoch() {
          requestEpoch += 1;
          return requestEpoch;
        }
        function setText(node, value) {
          node.textContent = value == null ? "" : String(value);
        }
        function headers(json) {
          const fields = { "X-Engram-Web": "1" };
          if (json) fields["Content-Type"] = "application/json";
          return fields;
        }
        function clearSessionPaging() {
          sessionSnapshotId = "";
          sessionCursor = "";
        }
        function clearMessages() {
          messageSessionId = "";
          messageGeneration = "";
          messageCursor = "";
          messageBuf = null;
          setText(messagesNode, "");
        }
        async function api(method, path, body) {
          const response = await fetch(path, {
            method: method,
            credentials: "same-origin",
            headers: headers(body !== undefined),
            body: body
          });
          if (!response.ok) {
            setText(statusNode, String(response.status));
            throw new Error("request failed");
          }
          const type = response.headers.get("content-type") || "";
          if (type.indexOf("application/json") >= 0) return response.json();
          return null;
        }
        async function login(event) {
          event.preventDefault();
          const credential = document.getElementById("credential").value;
          await api("POST", "/web/api/auth", JSON.stringify({ credential: credential }));
          document.getElementById("credential").value = "";
          setText(statusNode, "signed in");
          clearSessionPaging();
          clearMessages();
          await loadOverview();
          await loadSessions(false);
        }
        async function logout() {
          bumpEpoch();
          await api("DELETE", "/web/api/auth", "{}");
          setText(statusNode, "signed out");
          setText(overviewNode, "");
          setText(sessionsNode, "");
          setText(detailNode, "");
          clearSessionPaging();
          clearMessages();
        }
        function sessionQuery(more) {
          const params = new URLSearchParams();
          const query = document.getElementById("query").value;
          const source = document.getElementById("source").value;
          const machineId = document.getElementById("machineId").value;
          const projectKey = document.getElementById("projectKey").value;
          if (query) params.set("query", query);
          if (source) params.set("source", source);
          if (machineId) params.set("machineId", machineId);
          if (projectKey) params.set("projectKey", projectKey);
          if (more && sessionSnapshotId && sessionCursor) {
            params.set("snapshotId", sessionSnapshotId);
            params.set("cursor", sessionCursor);
          }
          const encoded = params.toString();
          return encoded ? ("?" + encoded) : "";
        }
        async function loadOverview() {
          const token = bumpEpoch();
          const page = await api("GET", "/web/api/overview");
          if (token !== requestEpoch) return;
          setText(overviewNode, "");
          const streams = page.streams || [];
          streams.forEach(function (stream) {
            const line = document.createElement("p");
            const machine = stream.machineId || "";
            const instance = stream.sourceInstanceId || "";
            setText(line, machine + " " + instance);
            overviewNode.appendChild(line);
          });
        }
        async function loadSessions(more) {
          const token = bumpEpoch();
          if (!more) {
            clearSessionPaging();
            setText(sessionsNode, "");
            setText(detailNode, "");
            clearMessages();
          }
          const page = await api("GET", "/web/api/sessions" + sessionQuery(more));
          if (token !== requestEpoch) return;
          sessionSnapshotId = page.snapshotId || "";
          sessionCursor = page.nextCursor || "";
          (page.items || []).forEach(function (item) {
            const button = document.createElement("button");
            button.type = "button";
            setText(button, item.title || item.sessionId || "");
            button.addEventListener("click", function () {
              openDetail(item.sessionId).catch(function () {});
            });
            sessionsNode.appendChild(button);
          });
        }
        async function openDetail(sessionId) {
          const token = bumpEpoch();
          setText(detailNode, "");
          clearMessages();
          try {
            const page = await api("GET", "/web/api/sessions/" + encodeURIComponent(sessionId));
            if (token !== requestEpoch) return;
            const detail = page.detail;
            if (!detail || !detail.session) {
              setText(detailNode, "unavailable");
              return;
            }
            const session = detail.session;
            const title = document.createElement("h2");
            setText(title, session.title || session.sessionId);
            detailNode.appendChild(title);
            const meta = document.createElement("p");
            setText(meta, [session.source, session.projectKey, session.projectLabel].filter(Boolean).join(" "));
            detailNode.appendChild(meta);
            const generation = detail.transcriptGeneration;
            if (!generation) {
              const note = document.createElement("p");
              setText(note, "transcript unavailable");
              messagesNode.appendChild(note);
              return;
            }
            await loadMessages(token, session.sessionId, generation, "");
          } catch (error) {
            if (token !== requestEpoch) return;
            throw error;
          }
        }
        function renderMessage(role, payload) {
          const line = document.createElement("p");
          const parts = [role || "", payload && payload.content ? payload.content : ""];
          const calls = payload && payload.toolCalls ? payload.toolCalls : [];
          calls.forEach(function (call) {
            parts.push([call.name, call.input, call.output].filter(Boolean).join(" "));
          });
          setText(line, parts.filter(Boolean).join(" "));
          messagesNode.appendChild(line);
        }
        function acceptFragment(fragment) {
          const piece = encoder.encode(fragment.payloadFragment || "");
          const ordinal = fragment.messageOrdinal;
          const hash = fragment.payloadSHA256;
          if (!messageBuf || messageBuf.ordinal !== ordinal || messageBuf.hash !== hash) {
            if (messageBuf) {
              setText(statusNode, "incomplete message");
              return;
            }
            if (fragment.utf8Offset !== 0) {
              setText(statusNode, "invalid fragment offset");
              return;
            }
            messageBuf = { ordinal: ordinal, hash: hash, bytes: Array.from(piece), role: fragment.role };
          } else {
            if (fragment.utf8Offset !== messageBuf.bytes.length) {
              setText(statusNode, "invalid fragment offset");
              return;
            }
            for (let i = 0; i < piece.length; i += 1) messageBuf.bytes.push(piece[i]);
          }
          if (fragment.isLastFragment) {
            const text = decoder.decode(new Uint8Array(messageBuf.bytes));
            renderMessage(messageBuf.role, JSON.parse(text));
            messageBuf = null;
          }
        }
        async function loadMessages(token, sessionId, generation, cursor) {
          messageSessionId = sessionId;
          messageGeneration = generation;
          let path = "/web/api/sessions/" + encodeURIComponent(sessionId) + "/messages?generation=" + encodeURIComponent(generation);
          if (cursor) path += "&cursor=" + encodeURIComponent(cursor);
          const page = await api("GET", path);
          if (token !== requestEpoch) return;
          (page.fragments || []).forEach(acceptFragment);
          messageCursor = page.nextCursor || "";
          if (messageBuf && !messageCursor) setText(statusNode, "incomplete message");
        }
        document.getElementById("login").addEventListener("submit", function (event) {
          login(event).catch(function () {});
        });
        document.getElementById("logout").addEventListener("click", function () {
          logout().catch(function () {});
        });
        document.getElementById("search").addEventListener("submit", function (event) {
          event.preventDefault();
          bumpEpoch();
          loadSessions(false).catch(function () {});
        });
        moreNode.addEventListener("click", function () {
          if (!sessionCursor || !sessionSnapshotId) return;
          loadSessions(true).catch(function () {});
        });
        moreMessagesNode.addEventListener("click", function () {
          if (!messageCursor || !messageSessionId || !messageGeneration) return;
          loadMessages(requestEpoch, messageSessionId, messageGeneration, messageCursor).catch(function () {});
        });
        """
}
