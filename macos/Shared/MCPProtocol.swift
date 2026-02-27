// macos/Shared/MCPProtocol.swift
import Foundation

// MARK: - Recursive JSON value

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                            { self = .null;   return }
        if let v = try? c.decode(Bool.self)         { self = .bool(v); return }
        if let v = try? c.decode(Int.self)          { self = .int(v);  return }
        if let v = try? c.decode(Double.self)       { self = .double(v); return }
        if let v = try? c.decode(String.self)       { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self)  { self = .array(v);  return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // Convenience accessors
    public subscript(key: String) -> JSONValue? {
        guard case .object(let d) = self else { return nil }
        return d[key]
    }
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, index < a.count else { return nil }
        return a[index]
    }
    public var stringValue: String?  { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int?        { if case .int(let i)    = self { return i }; return nil }
    public var boolValue: Bool?      { if case .bool(let b)   = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

// MARK: - JSON-RPC ID (string or number)

public enum JSONRPCId: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Int.self)    { self = .number(n); return }
        throw DecodingError.typeMismatch(JSONRPCId.self,
            .init(codingPath: decoder.codingPath, debugDescription: "ID must be string or int"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }
}

// MARK: - JSON-RPC wire types

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let method: String
    public let params: JSONValue?
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCId?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public static func ok(id: JSONRPCId?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }
    public static func err(id: JSONRPCId?, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil,
                        error: JSONRPCError(code: code, message: message))
    }
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
}

// MARK: - MCP tool definition

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}
