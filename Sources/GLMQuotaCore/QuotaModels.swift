import Foundation

public struct GLMQuotaSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var timeLimit: GLMQuotaWindow?
    public var tokensLimit5: GLMQuotaWindow?
    public var tokensLimitWeek: GLMQuotaWindow?
    public var level: String?
    public var error: String?

    public init(
        generatedAt: Date,
        timeLimit: GLMQuotaWindow? = nil,
        tokensLimit5: GLMQuotaWindow? = nil,
        tokensLimitWeek: GLMQuotaWindow? = nil,
        level: String? = nil,
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.timeLimit = timeLimit
        self.tokensLimit5 = tokensLimit5
        self.tokensLimitWeek = tokensLimitWeek
        self.level = level
        self.error = error
    }

    public var hasCompleteDisplayData: Bool {
        timeLimit != nil && tokensLimit5 != nil && tokensLimitWeek != nil
    }

    public var isRefreshFailure: Bool {
        error != nil || !hasCompleteDisplayData
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case timeLimit
        case tokensLimit5
        case tokensLimitWeek
        case legacyTokensLimitMonth = "tokensLimitMonth"
        case level
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        timeLimit = try container.decodeIfPresent(GLMQuotaWindow.self, forKey: .timeLimit)
        tokensLimit5 = try container.decodeIfPresent(GLMQuotaWindow.self, forKey: .tokensLimit5)
        tokensLimitWeek = try container.decodeIfPresent(GLMQuotaWindow.self, forKey: .tokensLimitWeek)
            ?? container.decodeIfPresent(GLMQuotaWindow.self, forKey: .legacyTokensLimitMonth)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(timeLimit, forKey: .timeLimit)
        try container.encodeIfPresent(tokensLimit5, forKey: .tokensLimit5)
        try container.encodeIfPresent(tokensLimitWeek, forKey: .tokensLimitWeek)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public struct GLMQuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Int
    public var usedPercent: Int
    public var resetsAt: Date?
    public var usage: Int?
    public var remaining: Int?
    public var total: Int?

    public init(
        remainingPercent: Int = 0,
        usedPercent: Int = 0,
        resetsAt: Date? = nil,
        usage: Int? = nil,
        remaining: Int? = nil,
        total: Int? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.usage = usage
        self.remaining = remaining
        self.total = total
    }
}
