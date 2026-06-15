import Foundation

public struct ClaudeQuotaSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var fiveHour: ClaudeQuotaWindow?
    public var weekly: ClaudeQuotaWindow?
    public var error: String?

    public init(
        generatedAt: Date,
        fiveHour: ClaudeQuotaWindow? = nil,
        weekly: ClaudeQuotaWindow? = nil,
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.error = error
    }

    public var hasCompleteDisplayData: Bool {
        fiveHour != nil && weekly != nil
    }

    public var isRefreshFailure: Bool {
        error != nil || !hasCompleteDisplayData
    }
}

public struct ClaudeQuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Int?
    public var usedPercent: Int?
    public var resetsAt: Date?

    public init(
        remainingPercent: Int? = nil,
        usedPercent: Int? = nil,
        resetsAt: Date? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}
