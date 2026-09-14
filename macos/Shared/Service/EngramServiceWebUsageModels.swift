import Foundation

struct EngramServiceWebUsageRequest: Codable, Equatable, Sendable {}

enum EngramServiceWebUsageBasis: String, Codable, Sendable {
    case indexedSessions, reported
}

struct EngramServiceWebUsageItem: Codable, Equatable, Sendable {
    let source: String
    let metric: String
    let value: Double
    let unit: String?
    let limit: Double?
    let resetAt: String?
    let status: String?
    let collectedAt: String
    let basis: EngramServiceWebUsageBasis
}

struct EngramServiceWebUsageResponse: Codable, Equatable, Sendable {
    let observedAt: Int64
    let scope: String
    let items: [EngramServiceWebUsageItem]

    init(observedAt: Int64, scope: String = "server", items: [EngramServiceWebUsageItem]) {
        self.observedAt = observedAt; self.scope = scope; self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(observedAt: try c.decode(Int64.self, forKey: .observedAt),
                  scope: try c.decode(String.self, forKey: .scope),
                  items: try c.decode([EngramServiceWebUsageItem].self, forKey: .items))
        typealias V = EngramServiceWebMetadataValidation
        try V.time(observedAt)
        try V.require(scope == "server" && items.count <= 1000)
        var keys: Set<Data> = []
        for item in items {
            try V.source(item.source)
            try V.text(item.metric, maximumBytes: 128, allowEmpty: false)
            try V.require(item.value.isFinite && item.value >= 0)
            if let limit = item.limit { try V.require(limit.isFinite && limit >= 0) }
            try V.text(item.collectedAt, maximumBytes: 64, allowEmpty: false)
            for text in [item.unit, item.resetAt, item.status].compactMap({ $0 }) {
                try V.text(text, maximumBytes: 128)
            }
            try V.require(keys.insert(Data((item.source + "\0" + item.metric).utf8)).inserted)
        }
    }
}
