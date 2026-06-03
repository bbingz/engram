import Foundation

indirect enum OrderedJSONValue {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([OrderedJSONValue])
    case object([(String, OrderedJSONValue)])

    func prettyJSONString() -> String {
        jsonString(pretty: true)
    }

    func compactJSONString() -> String {
        jsonString(pretty: false)
    }

    private func jsonString(pretty: Bool, depth: Int = 0) -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            guard value.isFinite else { return "null" }
            if value.rounded(.towardZero) == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return quotedJSONString(value)
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            if !pretty {
                return "[\(values.map { $0.jsonString(pretty: false, depth: depth + 1) }.joined(separator: ","))]"
            }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = values
                .map { "\(childIndent)\($0.jsonString(pretty: true, depth: depth + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(indent)]"
        case .object(let entries):
            guard !entries.isEmpty else { return "{}" }
            let rendered = entries.map { key, value in
                "\(quotedJSONString(key))\(pretty ? ": " : ":")\(value.jsonString(pretty: pretty, depth: depth + 1))"
            }
            if !pretty {
                return "{\(rendered.joined(separator: ","))}"
            }
            let indent = String(repeating: "  ", count: depth)
            let childIndent = String(repeating: "  ", count: depth + 1)
            let body = rendered.map { "\(childIndent)\($0)" }.joined(separator: ",\n")
            return "{\n\(body)\n\(indent)}"
        }
    }

    private func quotedJSONString(_ value: String) -> String {
        // JSONSerialization throws on invalid UTF-8 / unpaired surrogates that
        // can sneak in via slice(0, N) truncation. Falling back to a manual
        // escaper keeps the MCP process alive instead of crashing the stdio
        // server on a single malformed input.
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let arrayText = String(data: data, encoding: .utf8) {
            return String(arrayText.dropFirst().dropLast())
                .replacingOccurrences(of: "\\/", with: "/")
        }
        return manualEscape(value)
    }

    private func manualEscape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else if scalar.value >= 0xD800 && scalar.value <= 0xDFFF {
                    // Replace stray surrogate halves with U+FFFD so the output
                    // is still valid JSON.
                    out += "\u{FFFD}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

extension OrderedJSONValue {
    init(_ value: JSONValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let raw):
            self = .bool(raw)
        case .int(let raw):
            self = .int(raw)
        case .double(let raw):
            self = .double(raw)
        case .string(let raw):
            self = .string(raw)
        case .array(let raw):
            self = .array(raw.map(OrderedJSONValue.init))
        case .object(let raw):
            self = .object(raw.map { ($0.key, OrderedJSONValue($0.value)) })
        }
    }
}

extension JSONRPCId {
    var orderedJSONValue: OrderedJSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .int(value)
        }
    }
}

extension JSONRPCError {
    var orderedJSONValue: OrderedJSONValue {
        .object([
            ("code", .int(code)),
            ("message", .string(message)),
        ])
    }
}

extension JSONRPCResponse {
    var orderedJSONValue: OrderedJSONValue {
        var entries: [(String, OrderedJSONValue)] = [("jsonrpc", .string(jsonrpc))]
        if let id {
            entries.append(("id", id.orderedJSONValue))
        }
        if let result {
            entries.append(("result", OrderedJSONValue(result)))
        }
        if let error {
            entries.append(("error", error.orderedJSONValue))
        }
        return .object(entries)
    }
}
