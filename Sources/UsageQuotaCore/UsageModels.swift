import Foundation

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var currency: String
    public var daily: UsageSummary
    public var weekly: UsageSummary
    public var monthly: UsageSummary
    public var total: UsageSummary
    public var weekDays: [UsageDay]
    public var breakdowns: [UsageBreakdownSection]
    /// Per-day usage with per-model detail for the app's calendar heatmap and
    /// day/range detail. Ascending by period.
    /// Backward-compatible: old snapshots without this key decode to `[]`.
    /// The widget ignores this.
    public var calendarDays: [UsageCalendarDay]
    public var sources: UsageSources?
    public var hosts: [UsageHostSnapshot]
    public var agents: [UsageAgentSnapshot]
    /// Per-end breakdown (本机 + each reachable remote) for the app's "按端查看".
    /// Empty in local-only mode. The widget ignores this.
    public var ends: [UsageAgentSnapshot]
    public var modelPrices: [UsageModelPriceRecord]
    public var error: String?

    public init(
        generatedAt: Date,
        currency: String = "USD",
        daily: UsageSummary = UsageSummary(),
        weekly: UsageSummary = UsageSummary(),
        monthly: UsageSummary = UsageSummary(),
        total: UsageSummary = UsageSummary(),
        weekDays: [UsageDay] = [],
        breakdowns: [UsageBreakdownSection] = [],
        calendarDays: [UsageCalendarDay] = [],
        sources: UsageSources? = nil,
        hosts: [UsageHostSnapshot] = [],
        agents: [UsageAgentSnapshot] = [],
        ends: [UsageAgentSnapshot] = [],
        modelPrices: [UsageModelPriceRecord] = [],
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.currency = currency
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.total = total
        self.weekDays = weekDays
        self.breakdowns = breakdowns
        self.calendarDays = calendarDays
        self.sources = sources
        self.hosts = hosts
        self.agents = agents
        self.ends = ends
        self.modelPrices = modelPrices
        self.error = error
    }
}

extension UsageSnapshot {
    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case currency
        case daily
        case weekly
        case monthly
        case total
        case weekDays
        case breakdowns
        case calendarDays
        case sources
        case hosts
        case agents
        case ends
        case modelPrices
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        daily = try container.decodeIfPresent(UsageSummary.self, forKey: .daily) ?? UsageSummary()
        weekly = try container.decodeIfPresent(UsageSummary.self, forKey: .weekly) ?? UsageSummary()
        monthly = try container.decodeIfPresent(UsageSummary.self, forKey: .monthly) ?? UsageSummary()
        total = try container.decodeIfPresent(UsageSummary.self, forKey: .total) ?? UsageSummary()
        weekDays = try container.decodeIfPresent([UsageDay].self, forKey: .weekDays) ?? []
        breakdowns = try container.decodeIfPresent([UsageBreakdownSection].self, forKey: .breakdowns) ?? []
        calendarDays = try container.decodeIfPresent([UsageCalendarDay].self, forKey: .calendarDays) ?? []
        sources = try container.decodeIfPresent(UsageSources.self, forKey: .sources)
        hosts = try container.decodeIfPresent([UsageHostSnapshot].self, forKey: .hosts) ?? []
        agents = try container.decodeIfPresent([UsageAgentSnapshot].self, forKey: .agents) ?? []
        ends = try container.decodeIfPresent([UsageAgentSnapshot].self, forKey: .ends) ?? []
        modelPrices = try container.decodeIfPresent([UsageModelPriceRecord].self, forKey: .modelPrices) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(currency, forKey: .currency)
        try container.encode(daily, forKey: .daily)
        try container.encode(weekly, forKey: .weekly)
        try container.encode(monthly, forKey: .monthly)
        try container.encode(total, forKey: .total)
        try container.encode(weekDays, forKey: .weekDays)
        try container.encode(breakdowns, forKey: .breakdowns)
        try container.encode(calendarDays, forKey: .calendarDays)
        try container.encodeIfPresent(sources, forKey: .sources)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(agents, forKey: .agents)
        try container.encode(ends, forKey: .ends)
        try container.encode(modelPrices, forKey: .modelPrices)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public enum UsageModelPriceSource: String, Codable, Equatable, Sendable {
    case zaiOfficial
    case zaiCache
    case builtinFallback
    case ccusageReport
}

public enum UsageModelUnitPriceSource: String, Codable, Equatable, Sendable {
    case zaiOfficial
    case zaiCache
    case builtinFallback
    case litellmCache
}

public struct UsageModelPriceRecord: Codable, Equatable, Sendable, Identifiable {
    public var modelName: String
    public var source: UsageModelPriceSource
    public var fetchedAt: Date?
    public var unitPriceSource: UsageModelUnitPriceSource?
    public var unitPriceFetchedAt: Date?
    public var inputCostPerMTokUSD: Double?
    public var outputCostPerMTokUSD: Double?
    public var cacheCreationCostPerMTokUSD: Double?
    /// 1-hour-TTL cache-write unit price (2× input). Distinct from the 5-minute
    /// `cacheCreationCostPerMTokUSD` (1.25× input); ccusage bills the 1-hour rate.
    public var cacheCreation1hCostPerMTokUSD: Double?
    public var cacheReadCostPerMTokUSD: Double?
    public var effectiveCostPerMTokUSD: Double?
    public var totalTokens: Int
    public var totalCost: Double
    public var agents: [String]

    public var id: String { "\(source.rawValue):\(modelName)" }

    public init(
        modelName: String,
        source: UsageModelPriceSource,
        fetchedAt: Date? = nil,
        unitPriceSource: UsageModelUnitPriceSource? = nil,
        unitPriceFetchedAt: Date? = nil,
        inputCostPerMTokUSD: Double? = nil,
        outputCostPerMTokUSD: Double? = nil,
        cacheCreationCostPerMTokUSD: Double? = nil,
        cacheCreation1hCostPerMTokUSD: Double? = nil,
        cacheReadCostPerMTokUSD: Double? = nil,
        effectiveCostPerMTokUSD: Double? = nil,
        totalTokens: Int = 0,
        totalCost: Double = 0,
        agents: [String] = []
    ) {
        self.modelName = modelName
        self.source = source
        self.fetchedAt = fetchedAt
        self.unitPriceSource = unitPriceSource
        self.unitPriceFetchedAt = unitPriceFetchedAt
        self.inputCostPerMTokUSD = inputCostPerMTokUSD
        self.outputCostPerMTokUSD = outputCostPerMTokUSD
        self.cacheCreationCostPerMTokUSD = cacheCreationCostPerMTokUSD
        self.cacheCreation1hCostPerMTokUSD = cacheCreation1hCostPerMTokUSD
        self.cacheReadCostPerMTokUSD = cacheReadCostPerMTokUSD
        self.effectiveCostPerMTokUSD = effectiveCostPerMTokUSD
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.agents = agents
    }
}

public struct UsageHostSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var overview: UsageAgentSnapshot
    public var agents: [UsageAgentSnapshot]

    public init(
        id: String,
        name: String,
        overview: UsageAgentSnapshot,
        agents: [UsageAgentSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.overview = overview
        self.agents = agents
    }
}

public struct UsageAgentSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var daily: UsageSummary
    public var weekly: UsageSummary
    public var monthly: UsageSummary
    public var total: UsageSummary
    public var weekDays: [UsageDay]
    public var breakdowns: [UsageBreakdownSection]
    /// Per-day usage with per-model detail scoped to this agent/host/end.
    /// Backward-compatible: old snapshots without this key decode to `[]`.
    /// The widget ignores this.
    public var calendarDays: [UsageCalendarDay]

    public init(
        id: String,
        name: String,
        daily: UsageSummary = UsageSummary(),
        weekly: UsageSummary = UsageSummary(),
        monthly: UsageSummary = UsageSummary(),
        total: UsageSummary = UsageSummary(),
        weekDays: [UsageDay] = [],
        breakdowns: [UsageBreakdownSection] = [],
        calendarDays: [UsageCalendarDay] = []
    ) {
        self.id = id
        self.name = name
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.total = total
        self.weekDays = weekDays
        self.breakdowns = breakdowns
        self.calendarDays = calendarDays
    }
}

extension UsageAgentSnapshot {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case daily
        case weekly
        case monthly
        case total
        case weekDays
        case breakdowns
        case calendarDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        daily = try container.decodeIfPresent(UsageSummary.self, forKey: .daily) ?? UsageSummary()
        weekly = try container.decodeIfPresent(UsageSummary.self, forKey: .weekly) ?? UsageSummary()
        monthly = try container.decodeIfPresent(UsageSummary.self, forKey: .monthly) ?? UsageSummary()
        total = try container.decodeIfPresent(UsageSummary.self, forKey: .total) ?? UsageSummary()
        weekDays = try container.decodeIfPresent([UsageDay].self, forKey: .weekDays) ?? []
        breakdowns = try container.decodeIfPresent([UsageBreakdownSection].self, forKey: .breakdowns) ?? []
        calendarDays = try container.decodeIfPresent([UsageCalendarDay].self, forKey: .calendarDays) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(daily, forKey: .daily)
        try container.encode(weekly, forKey: .weekly)
        try container.encode(monthly, forKey: .monthly)
        try container.encode(total, forKey: .total)
        try container.encode(weekDays, forKey: .weekDays)
        try container.encode(breakdowns, forKey: .breakdowns)
        try container.encode(calendarDays, forKey: .calendarDays)
    }
}

/// One model's token + cost usage for a single calendar day (or aggregated
/// range). Used by the app's calendar heatmap and day/range detail card.
public struct UsageModelUsage: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var summary: UsageSummary

    public var id: String { name }

    public init(name: String, summary: UsageSummary = UsageSummary()) {
        self.name = name
        self.summary = summary
    }
}

/// Per-day usage with per-model detail. Powers the calendar heatmap and the
/// click-to-inspect / date-range detail in the app. `period` is a "YYYY-MM-DD"
/// date key, ascending by period. The widget ignores this.
public struct UsageCalendarDay: Codable, Equatable, Sendable, Identifiable {
    public var period: String
    public var summary: UsageSummary
    public var models: [UsageModelUsage]

    public var id: String { period }

    public init(period: String, summary: UsageSummary = UsageSummary(), models: [UsageModelUsage] = []) {
        self.period = period
        self.summary = summary
        self.models = models
    }
}

public struct UsageSummary: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int
    public var totalCost: Double

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int = 0,
        totalCost: Double = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
    }

    public static func + (lhs: UsageSummary, rhs: UsageSummary) -> UsageSummary {
        UsageSummary(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            totalCost: lhs.totalCost + rhs.totalCost
        )
    }
}

public struct UsageDay: Codable, Equatable, Sendable, Identifiable {
    public var period: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int
    public var totalCost: Double

    public var id: String { period }

    public init(period: String, summary: UsageSummary = UsageSummary()) {
        self.period = period
        self.inputTokens = summary.inputTokens
        self.outputTokens = summary.outputTokens
        self.cacheCreationTokens = summary.cacheCreationTokens
        self.cacheReadTokens = summary.cacheReadTokens
        self.totalTokens = summary.totalTokens
        self.totalCost = summary.totalCost
    }

    public var summary: UsageSummary {
        UsageSummary(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            totalTokens: totalTokens,
            totalCost: totalCost
        )
    }
}

public struct UsageBreakdownSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var items: [UsageBreakdownItem]

    public init(id: String, title: String, items: [UsageBreakdownItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct UsageBreakdownItem: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int
    public var totalCost: Double
    public var percent: Double

    public var id: String { name }

    public init(
        name: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int = 0,
        totalCost: Double = 0,
        percent: Double = 0
    ) {
        self.name = name
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.percent = percent
    }
}

public struct UsageSources: Codable, Equatable, Sendable {
    /// Whether the local `npx ccusage@latest daily --json` call succeeded.
    public var localReachable: Bool
    /// The configured remote SSH hosts (empty = local-only mode).
    public var remoteHosts: [String]
    /// The subset of `remoteHosts` that responded and were merged in.
    public var reachableHosts: [String]
    /// Local-only extension sources merged outside ccusage, e.g. ZCode.
    public var localExtensions: [String]
    public var agents: [String]

    public init(
        localReachable: Bool = true,
        remoteHosts: [String] = [],
        reachableHosts: [String] = [],
        localExtensions: [String] = [],
        agents: [String] = []
    ) {
        self.localReachable = localReachable
        self.remoteHosts = remoteHosts
        self.reachableHosts = reachableHosts
        self.localExtensions = localExtensions
        self.agents = agents
    }

    public enum RemoteStatus: Sendable, Equatable {
        case localOnly  // no remote configured
        case joint      // all configured remotes merged in
        case partial    // some remotes merged, some unreachable
        case degraded   // configured but none reachable → local only
    }

    public var remoteStatus: RemoteStatus {
        guard !remoteHosts.isEmpty else { return .localOnly }
        if reachableHosts.isEmpty { return .degraded }
        if reachableHosts.count < remoteHosts.count { return .partial }
        return .joint
    }

    public var statusLabel: String? {
        let localParts = (localReachable ? ["本地"] : []) + localExtensions.map(Self.displayName)
        let localLabel = localParts.isEmpty ? nil : localParts.joined(separator: "+")

        if remoteHosts.isEmpty {
            return localLabel ?? "无来源"
        }

        let remoteLabel = "多端(\(reachableHosts.count)/\(remoteHosts.count))"
        return localLabel.map { "\($0)+\(remoteLabel)" } ?? remoteLabel
    }

    public var hasMissingSources: Bool {
        !localReachable || reachableHosts.count < remoteHosts.count
    }

    private enum CodingKeys: String, CodingKey {
        case localReachable, remoteHosts, reachableHosts, localExtensions, agents
        case remoteHost, remoteReachable  // legacy single-host snapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localReachable = try container.decodeIfPresent(Bool.self, forKey: .localReachable) ?? true
        localExtensions = try container.decodeIfPresent([String].self, forKey: .localExtensions) ?? []
        agents = try container.decodeIfPresent([String].self, forKey: .agents) ?? []
        if let hosts = try container.decodeIfPresent([String].self, forKey: .remoteHosts) {
            remoteHosts = hosts
            reachableHosts = try container.decodeIfPresent([String].self, forKey: .reachableHosts) ?? []
        } else {
            // Migrate legacy single-host snapshots.
            let legacyHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
            let legacyReachable = try container.decodeIfPresent(Bool.self, forKey: .remoteReachable) ?? false
            remoteHosts = legacyHost.map { [$0] } ?? []
            reachableHosts = (legacyReachable ? legacyHost.map { [$0] } : nil) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localReachable, forKey: .localReachable)
        try container.encode(remoteHosts, forKey: .remoteHosts)
        try container.encode(reachableHosts, forKey: .reachableHosts)
        try container.encode(localExtensions, forKey: .localExtensions)
        try container.encode(agents, forKey: .agents)
    }

    private static func displayName(_ source: String) -> String {
        switch source.lowercased() {
        case "zcode": return "ZCode"
        default: return source
        }
    }
}
