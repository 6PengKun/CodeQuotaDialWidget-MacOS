import Foundation
import QuotaProcessSupport

struct ZCodeUsageCollector: Sendable {
    static let agentName = "zcode"

    var databaseURL: URL
    var pricingResolver: ZCodePricingResolver

    init(
        databaseURL: URL = ZCodeUsageCollector.defaultDatabaseURL(),
        pricingResolver: ZCodePricingResolver = ZCodePricingResolver()
    ) {
        self.databaseURL = databaseURL
        self.pricingResolver = pricingResolver
    }

    func collect(now: Date, calendar: Calendar, mode: UsageCollector.PricingMode) throws -> Result {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return Result() }
        let records = try queryRecords()
        guard !records.isEmpty else { return Result() }
        let prices = pricingResolver.catalog(mode: mode, now: now, calendar: calendar)
        let rows = Self.dailyRows(from: records, prices: prices, calendar: calendar)
        return Result(rows: rows, modelPrices: Self.modelPriceRecords(from: records, prices: prices))
    }

    static func dailyRows(from records: [Record], prices: ZCodePriceCatalog, calendar: Calendar) -> [DailyRow] {
        var byPeriod: [String: DailyRow] = [:]

        for record in records where record.hasUsage {
            let summary = summary(for: record, prices: prices)
            guard summary.totalTokens > 0 else { continue }

            let date = Date(timeIntervalSince1970: TimeInterval(record.startedAt) / 1000.0)
            let period = UsageCollector.dateKey(date, calendar: calendar)
            let model = UsageCollector.modelKey(record.modelID.isEmpty ? record.providerID : record.modelID)

            if var existing = byPeriod[period] {
                existing.summary = existing.summary + summary
                existing.agents = [Self.agentName]
                existing.models[model, default: UsageSummary()] = existing.models[model, default: UsageSummary()] + summary
                byPeriod[period] = existing
            } else {
                byPeriod[period] = DailyRow(
                    period: period,
                    summary: summary,
                    agents: [Self.agentName],
                    models: [model: summary]
                )
            }
        }

        return byPeriod.values.sorted { $0.period < $1.period }
    }

    private static func summary(for record: Record, prices: ZCodePriceCatalog) -> UsageSummary {
        let cacheCreate = max(0, record.cacheCreationInputTokens)
        let cacheRead = max(0, record.cacheReadInputTokens)
        let input = max(0, record.inputTokens - cacheCreate - cacheRead)
        let output = max(0, record.outputTokens + record.reasoningTokens)

        var summary = UsageSummary(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheCreate + cacheRead
        )
        if let price = prices.price(for: record.modelID, providerID: record.providerID) {
            summary.totalCost = price.cost(for: summary)
        }
        return summary
    }

    static func modelPriceRecords(
        from records: [Record],
        prices: ZCodePriceCatalog
    ) -> [UsageModelPriceRecord] {
        struct Accumulator {
            var summary = UsageSummary()
            var entry: ZCodePriceEntry?
        }

        var grouped: [String: Accumulator] = [:]
        for record in records where record.hasUsage {
            let model = UsageCollector.modelKey(record.modelID.isEmpty ? record.providerID : record.modelID)
            let entry = prices.entry(for: record.modelID, providerID: record.providerID)
            let source = entry?.source ?? .builtinFallback
            let key = "\(source.rawValue):\(model)"
            var accumulator = grouped[key] ?? Accumulator()
            accumulator.summary = accumulator.summary + summary(for: record, prices: prices)
            if accumulator.entry == nil {
                accumulator.entry = entry
            }
            grouped[key] = accumulator
        }

        return grouped.map { key, accumulator in
            let modelName = String(key.split(separator: ":", maxSplits: 1).last ?? "")
            let price = accumulator.entry?.price
            let source = accumulator.entry?.source ?? .builtinFallback
            return UsageModelPriceRecord(
                modelName: modelName,
                source: source,
                fetchedAt: accumulator.entry?.fetchedAt,
                unitPriceSource: unitPriceSource(for: source),
                unitPriceFetchedAt: accumulator.entry?.fetchedAt,
                inputCostPerMTokUSD: price.map { $0.inputCostPerToken * 1_000_000 },
                outputCostPerMTokUSD: price.map { $0.outputCostPerToken * 1_000_000 },
                cacheCreationCostPerMTokUSD: price?.cacheCreationCostPerToken.map { $0 * 1_000_000 },
                cacheReadCostPerMTokUSD: price?.cacheReadCostPerToken.map { $0 * 1_000_000 },
                effectiveCostPerMTokUSD: effectiveCostPerMTok(accumulator.summary),
                totalTokens: accumulator.summary.totalTokens,
                totalCost: accumulator.summary.totalCost,
                agents: [Self.agentName]
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost { return lhs.modelName < rhs.modelName }
            return lhs.totalCost > rhs.totalCost
        }
    }

    private static func unitPriceSource(for source: UsageModelPriceSource) -> UsageModelUnitPriceSource? {
        switch source {
        case .zaiOfficial: return .zaiOfficial
        case .zaiCache: return .zaiCache
        case .builtinFallback: return .builtinFallback
        case .ccusageReport: return nil
        }
    }

    private static func effectiveCostPerMTok(_ summary: UsageSummary) -> Double? {
        guard summary.totalTokens > 0 else { return nil }
        return summary.totalCost / Double(summary.totalTokens) * 1_000_000
    }

    private func queryRecords() throws -> [Record] {
        let sqlite = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: sqlite) else {
            throw ZCodeUsageError.sqliteNotFound
        }

        let query = """
        select
          provider_id as providerID,
          model_id as modelID,
          started_at as startedAt,
          input_tokens as inputTokens,
          output_tokens as outputTokens,
          reasoning_tokens as reasoningTokens,
          cache_creation_input_tokens as cacheCreationInputTokens,
          cache_read_input_tokens as cacheReadInputTokens
        from model_usage
        where status = 'completed'
          and (input_tokens > 0 or output_tokens > 0 or reasoning_tokens > 0
               or cache_creation_input_tokens > 0 or cache_read_input_tokens > 0)
        order by started_at
        """

        let result = try QuotaProcessSupport.run(
            executable: sqlite,
            arguments: ["-json", sqliteURI(for: databaseURL), query],
            timeout: 30
        )
        guard result.status == 0 else {
            throw ZCodeUsageError.queryFailed(result.stderrString.isEmpty ? result.stdoutString : result.stderrString)
        }
        guard !result.stdout.isEmpty else { return [] }
        return try JSONDecoder().decode([Record].self, from: result.stdout)
    }

    private func sqliteURI(for url: URL) -> String {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "file:\(path)?mode=ro&immutable=1"
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite")
    }

    struct Record: Decodable, Sendable {
        var providerID: String
        var modelID: String
        var startedAt: Int64
        var inputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var cacheCreationInputTokens: Int
        var cacheReadInputTokens: Int

        var hasUsage: Bool {
            inputTokens > 0 || outputTokens > 0 || reasoningTokens > 0
                || cacheCreationInputTokens > 0 || cacheReadInputTokens > 0
        }
    }

    struct Result: Sendable {
        var rows: [DailyRow] = []
        var modelPrices: [UsageModelPriceRecord] = []
    }
}

enum ZCodeUsageError: LocalizedError {
    case sqliteNotFound
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqliteNotFound:
            return "未找到 sqlite3，无法读取 ZCode 用量数据库"
        case .queryFailed(let message):
            return "ZCode 用量查询失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
