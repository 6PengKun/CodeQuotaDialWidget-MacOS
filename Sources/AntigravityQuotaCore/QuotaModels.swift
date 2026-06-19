import Foundation

public struct AntigravityQuotaSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var method: String?
    public var email: String?
    public var planType: String?
    public var models: [AntigravityModelQuota]
    public var error: String?

    public init(
        generatedAt: Date,
        method: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        models: [AntigravityModelQuota] = [],
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.method = method
        self.email = email
        self.planType = planType
        self.models = models
        self.error = error
    }

    public var hasCompleteDisplayData: Bool {
        !models.isEmpty
    }

    public var isRefreshFailure: Bool {
        error != nil || !hasCompleteDisplayData
    }

    public func model(for family: AntigravityModelFamily) -> AntigravityModelQuota? {
        models.first { $0.family == family }
    }

    public func model(for bucket: AntigravityQuotaBucket) -> AntigravityModelQuota? {
        let families: [AntigravityModelFamily]
        switch bucket {
        case .claude:
            families = [.opus, .sonnet]
        case .gemini:
            families = [.pro, .flash]
        }

        return models
            .filter { families.contains($0.family) }
            .sorted { lhs, rhs in
                switch (lhs.remainingPercent, rhs.remainingPercent) {
                case let (left?, right?):
                    return left < right
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    return lhs.family.rawValue < rhs.family.rawValue
                }
            }
            .first
    }
}

public enum AntigravityModelFamily: String, Codable, CaseIterable, Sendable {
    case opus
    case sonnet
    case pro
    case flash

    public var displayName: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .pro: return "Pro"
        case .flash: return "Flash"
        }
    }
}

public enum AntigravityQuotaBucket: String, Codable, CaseIterable, Sendable {
    case claude
    case gemini

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }
}

public struct AntigravityModelQuota: Codable, Equatable, Sendable {
    public var family: AntigravityModelFamily
    public var label: String
    public var modelId: String
    public var remainingPercent: Int?
    public var usedPercent: Int?
    public var resetsAt: Date?
    public var isExhausted: Bool

    public init(
        family: AntigravityModelFamily,
        label: String,
        modelId: String,
        remainingPercent: Int? = nil,
        usedPercent: Int? = nil,
        resetsAt: Date? = nil,
        isExhausted: Bool = false
    ) {
        self.family = family
        self.label = label
        self.modelId = modelId
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.isExhausted = isExhausted
    }
}
