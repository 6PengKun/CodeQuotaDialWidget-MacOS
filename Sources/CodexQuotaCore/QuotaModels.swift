import Foundation

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var fiveHour: CodexQuotaWindow?
    public var weekly: CodexQuotaWindow?
    public var monthly: CodexQuotaWindow?
    public var planType: String?
    public var error: String?

    public init(
        generatedAt: Date,
        fiveHour: CodexQuotaWindow? = nil,
        weekly: CodexQuotaWindow? = nil,
        monthly: CodexQuotaWindow? = nil,
        planType: String? = nil,
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
        self.planType = planType
        self.error = error
    }

    /// 免费版（Plus 到期或从未订阅）：服务端只下发单个 30 天窗口。
    public var isFreePlan: Bool {
        planType?.lowercased() == "free"
    }

    public var hasCompleteDisplayData: Bool {
        // 免费版只有一个 30 天窗口；付费版需要 5h + weekly 两个窗口。
        if monthly != nil, fiveHour == nil, weekly == nil {
            return true
        }
        return fiveHour != nil && weekly != nil
    }

    public var isRefreshFailure: Bool {
        error != nil || !hasCompleteDisplayData
    }
}

public struct CodexQuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Int?
    public var usedPercent: Int?
    public var resetsAt: Date?
    public var windowDurationMins: Int?

    public init(
        remainingPercent: Int? = nil,
        usedPercent: Int? = nil,
        resetsAt: Date? = nil,
        windowDurationMins: Int? = nil
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }
}
