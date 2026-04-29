import Foundation

struct CascadeConversationSummary: Equatable, Sendable {
    var cascadeId: String
    var title: String
    var summary: String
    var createdAt: String
    var updatedAt: String
    var cwd: String
}

struct CascadeTrajectoryMessage: Equatable, Sendable {
    var role: NormalizedMessageRole
    var content: String
}

final class CascadeClient {
    private let baseURL: URL
    private let csrfToken: String
    private let session: URLSession

    init(baseURL: URL, csrfToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.csrfToken = csrfToken
        self.session = session
    }

    convenience init(port: Int, csrfToken: String, session: URLSession = .shared) {
        self.init(baseURL: URL(string: "http://localhost:\(port)")!, csrfToken: csrfToken, session: session)
    }

    func listConversations() async throws -> [CascadeConversationSummary] {
        let data = try await postJSON(path: "GetAllCascadeTrajectories", body: "{}")
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject,
              let summaries = object["trajectorySummaries"] as? [String: Any]
        else {
            return []
        }

        return summaries.keys.sorted().compactMap { cascadeId in
            guard let summary = summaries[cascadeId] as? JSONLAdapterSupport.JSONObject else { return nil }
            let textSummary = JSONLAdapterSupport.string(summary["summary"]) ?? ""
            let cwd = Self.cwd(from: JSONLAdapterSupport.array(summary["workspaces"]))
            return CascadeConversationSummary(
                cascadeId: cascadeId,
                title: textSummary,
                summary: textSummary,
                createdAt: Self.timestamp(from: summary["createdTime"]),
                updatedAt: Self.timestamp(from: summary["lastModifiedTime"]),
                cwd: cwd
            )
        }
    }

    func getTrajectoryMessages(cascadeId: String) async throws -> [CascadeTrajectoryMessage] {
        let data = try await postJSON(path: "GetCascadeTrajectory", body: "{\"cascadeId\":\"\(escapeJSON(cascadeId))\"}")
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject,
              let trajectory = JSONLAdapterSupport.object(object["trajectory"]),
              let steps = JSONLAdapterSupport.array(trajectory["steps"])
        else {
            return []
        }

        var messages: [CascadeTrajectoryMessage] = []
        for stepValue in steps {
            guard let step = JSONLAdapterSupport.object(stepValue),
                  let type = JSONLAdapterSupport.string(step["type"])
            else {
                continue
            }
            if type.contains("USER_INPUT"),
               let input = JSONLAdapterSupport.object(step["userInput"]),
               let text = JSONLAdapterSupport.string(input["userResponse"]),
               !text.isEmpty
            {
                messages.append(CascadeTrajectoryMessage(role: .user, content: text))
            } else if type.contains("PLANNER_RESPONSE"),
                      let response = JSONLAdapterSupport.object(step["plannerResponse"]),
                      let text = JSONLAdapterSupport.string(response["response"]),
                      !text.isEmpty
            {
                messages.append(CascadeTrajectoryMessage(role: .assistant, content: text))
            } else if type.contains("NOTIFY_USER"),
                      let notification = JSONLAdapterSupport.object(step["notifyUser"]),
                      let text = JSONLAdapterSupport.string(notification["notificationContent"]),
                      !text.isEmpty
            {
                messages.append(CascadeTrajectoryMessage(role: .assistant, content: text))
            }
        }
        return messages
    }

    func getMarkdown(cascadeId: String) async throws -> String {
        let body = "{\"trajectory\":{\"cascadeId\":\"\(escapeJSON(cascadeId))\"}}"
        let data = try await postJSON(path: "ConvertTrajectoryToMarkdown", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject else {
            return ""
        }
        return JSONLAdapterSupport.string(object["markdown"]) ?? ""
    }

    private func postJSON(path method: String, body: String) async throws -> Data {
        let url = URL(
            string: "/exa.language_server_pb.LanguageServerService/\(method)",
            relativeTo: baseURL
        )!.absoluteURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func cwd(from workspaces: [Any]?) -> String {
        guard let workspace = workspaces?.first as? JSONLAdapterSupport.JSONObject,
              let uri = JSONLAdapterSupport.string(workspace["workspaceFolderAbsoluteUri"])
        else {
            return ""
        }
        let withoutScheme = uri.replacingOccurrences(of: #"^file://"#, with: "", options: .regularExpression)
        return withoutScheme.removingPercentEncoding ?? withoutScheme
    }

    private static func timestamp(from value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        guard let object = value as? JSONLAdapterSupport.JSONObject else {
            return ""
        }
        if let seconds = object["seconds"] as? NSNumber {
            return isoString(seconds: seconds.doubleValue)
        }
        if let seconds = object["seconds"] as? String,
           let value = Double(seconds)
        {
            return isoString(seconds: value)
        }
        return ""
    }

    private static func isoString(seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
