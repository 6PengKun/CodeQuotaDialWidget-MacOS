import Foundation

struct LiteLLMModelPrice: Decodable, Equatable, Sendable {
    var inputCostPerToken: Double?
    var outputCostPerToken: Double?
    var cacheCreationInputTokenCost: Double?
    /// 1-hour-TTL cache-write price (2× input). ccusage bills this rate for
    /// Claude Code's 1-hour caches; the 5-minute `cacheCreationInputTokenCost`
    /// (1.25× input) alone can't reconcile with ccusage totals.
    var cacheCreationInputTokenCostAbove1hr: Double?
    var cacheReadInputTokenCost: Double?

    private enum CodingKeys: String, CodingKey {
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
        case cacheCreationInputTokenCostAbove1hr = "cache_creation_input_token_cost_above_1hr"
        case cacheReadInputTokenCost = "cache_read_input_token_cost"
    }

    var hasUnitPrice: Bool {
        inputCostPerToken != nil
            || outputCostPerToken != nil
            || cacheCreationInputTokenCost != nil
            || cacheCreationInputTokenCostAbove1hr != nil
            || cacheReadInputTokenCost != nil
    }
}

struct LiteLLMPriceEntry: Equatable, Sendable {
    var price: LiteLLMModelPrice
    var fetchedAt: Date?
}

struct LiteLLMPricingCatalog: Sendable {
    private var entriesByKey: [String: LiteLLMPriceEntry]

    var isEmpty: Bool { entriesByKey.isEmpty }

    init(_ prices: [String: LiteLLMModelPrice] = [:], fetchedAt: Date? = nil) {
        var normalized: [String: LiteLLMPriceEntry] = [:]
        for (key, price) in prices where price.hasUnitPrice {
            normalized[Self.normalize(key)] = LiteLLMPriceEntry(price: price, fetchedAt: fetchedAt)
        }
        entriesByKey = normalized
    }

    func entry(for modelName: String) -> LiteLLMPriceEntry? {
        let model = Self.normalize(modelName)
        var modelCandidates = [model]
        if model.hasPrefix("claude-") {
            modelCandidates.append(model.replacingOccurrences(of: ".", with: "-"))
        }
        modelCandidates.append(contentsOf: Self.aliases(for: model))

        var candidates: [String] = []
        for candidate in Array(Set(modelCandidates)).sorted() {
            candidates.append(candidate)
            candidates.append("openai/\(candidate)")
            candidates.append("anthropic/\(candidate)")
            candidates.append("zai/\(candidate)")
        }

        for candidate in candidates {
            if let entry = entriesByKey[candidate] {
                return entry
            }
        }
        return entriesByKey.first { key, _ in key.hasSuffix("/\(model)") }?.value
    }

    private static func aliases(for model: String) -> [String] {
        switch model {
        case "glm-5.1":
            return [
                "fireworks_ai/glm-5p1",
                "fireworks_ai/accounts/fireworks/models/glm-5p1"
            ]
        case "glm-5.2":
            return [
                "fireworks_ai/glm-5p2",
                "fireworks_ai/accounts/fireworks/models/glm-5p2"
            ]
        default:
            return []
        }
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

import QuotaProcessSupport

/// Resolves LiteLLM unit prices the same way ZCode resolves Z.AI prices: online
/// at most once per calendar day (gated by a marker file), otherwise the local
/// cache.
struct LiteLLMPricingResolver: Sendable {
    private static let pricingURL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

    func catalog(mode: UsageCollector.PricingMode, now: Date, calendar: Calendar) -> LiteLLMPricingCatalog? {
        let lastOnlineDay = (try? String(contentsOf: LiteLLMPricingCache.markerURL(), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = UsageCollector.shouldRunOffline(mode: mode, lastOnlineDay: lastOnlineDay, now: now, calendar: calendar)

        if !offline, let data = try? fetchOfficialData(), let catalog = Self.catalog(from: data, fetchedAt: now) {
            try? LiteLLMPricingCache.saveCache(data)
            try? LiteLLMPricingCache.stampOnlineRefresh(now: now, calendar: calendar)
            return catalog
        }

        if let data = try? Data(contentsOf: LiteLLMPricingCache.cacheURL()),
           let catalog = Self.catalog(from: data, fetchedAt: LiteLLMPricingCache.cacheModificationDate()) {
            return catalog
        }

        return nil
    }

    private static func catalog(from data: Data, fetchedAt: Date?) -> LiteLLMPricingCatalog? {
        guard let prices = try? JSONDecoder().decode([String: LiteLLMModelPrice].self, from: data) else { return nil }
        let catalog = LiteLLMPricingCatalog(prices, fetchedAt: fetchedAt)
        return catalog.isEmpty ? nil : catalog
    }

    private func fetchOfficialData() throws -> Data {
        var configLines = [
            "silent",
            "show-error",
            QuotaProcessSupport.curlConfigLine("connect-timeout", "10"),
            QuotaProcessSupport.curlConfigLine("max-time", "60"),
            QuotaProcessSupport.curlConfigLine("url", Self.pricingURL)
        ]
        if let proxy = UsageProxyConfig.proxyURL, !proxy.isEmpty {
            configLines.append(QuotaProcessSupport.curlConfigLine("proxy", proxy))
        }

        let configURL = try QuotaProcessSupport.writeCurlConfig(configLines)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let result = try QuotaProcessSupport.run(executable: "/usr/bin/curl", arguments: ["-K", configURL.path], timeout: 65)
        guard result.status == 0, !result.stdout.isEmpty else { return Data() }
        return result.stdout
    }
}

enum LiteLLMPricingCache {
    static func cacheURL() -> URL {
        UsageSnapshotStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("usage_litellm_pricing_cache.json")
    }

    static func markerURL() -> URL {
        UsageSnapshotStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("usage_litellm_pricing_refresh")
    }

    static func cacheModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL().path)
        return attributes?[.modificationDate] as? Date
    }

    static func saveCache(_ data: Data) throws {
        let url = cacheURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func stampOnlineRefresh(now: Date, calendar: Calendar) throws {
        let url = markerURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageCollector.dateKey(now, calendar: calendar).write(to: url, atomically: true, encoding: .utf8)
    }
}
