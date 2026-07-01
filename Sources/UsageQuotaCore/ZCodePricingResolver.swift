import Foundation
import QuotaProcessSupport

struct ZCodeModelPrice: Codable, Equatable, Sendable {
    var inputCostPerToken: Double
    var outputCostPerToken: Double
    var cacheCreationCostPerToken: Double?
    var cacheReadCostPerToken: Double?

    func cost(for summary: UsageSummary) -> Double {
        let cacheCreate = cacheCreationCostPerToken ?? inputCostPerToken
        let cacheRead = cacheReadCostPerToken ?? inputCostPerToken
        return Double(summary.inputTokens) * inputCostPerToken
            + Double(summary.outputTokens) * outputCostPerToken
            + Double(summary.cacheCreationTokens) * cacheCreate
            + Double(summary.cacheReadTokens) * cacheRead
    }
}

struct ZCodePriceEntry: Codable, Equatable, Sendable {
    var price: ZCodeModelPrice
    var source: UsageModelPriceSource
    var fetchedAt: Date?
}

struct ZCodePriceCatalog: Sendable {
    private var entriesByKey: [String: ZCodePriceEntry]

    init(
        _ prices: [String: ZCodeModelPrice] = [:],
        source: UsageModelPriceSource = .builtinFallback,
        fetchedAt: Date? = nil
    ) {
        var normalized: [String: ZCodePriceEntry] = [:]
        for (key, price) in prices {
            normalized[Self.normalize(key)] = ZCodePriceEntry(price: price, source: source, fetchedAt: fetchedAt)
        }
        entriesByKey = normalized
    }

    init(entries: [String: ZCodePriceEntry]) {
        var normalized: [String: ZCodePriceEntry] = [:]
        for (key, entry) in entries {
            normalized[Self.normalize(key)] = entry
        }
        entriesByKey = normalized
    }

    func price(for modelID: String, providerID: String) -> ZCodeModelPrice? {
        entry(for: modelID, providerID: providerID)?.price
    }

    func entry(for modelID: String, providerID: String) -> ZCodePriceEntry? {
        let model = Self.normalize(modelID)
        let provider = Self.normalize(providerID)
        let candidates = [
            "\(provider)/\(model)",
            "zai/\(model)",
            "bigmodel/\(model)",
            "builtin:zai/\(model)",
            "builtin:bigmodel/\(model)",
            model
        ]

        for candidate in candidates {
            if let entry = entriesByKey[candidate] {
                return entry
            }
        }

        return entriesByKey.first { key, _ in key.hasSuffix("/\(model)") }?.value
    }

    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct ZCodePricingResolver: Sendable {
    private static let pricingURL = "https://docs.z.ai/guides/overview/pricing"

    func catalog(mode: UsageCollector.PricingMode, now: Date, calendar: Calendar) -> ZCodePriceCatalog {
        let lastOnlineDay = (try? String(contentsOf: Self.markerURL(), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = UsageCollector.shouldRunOffline(mode: mode, lastOnlineDay: lastOnlineDay, now: now, calendar: calendar)

        if !offline, let official = try? fetchOfficialPrices(), !official.isEmpty {
            try? Self.saveCache(official)
            try? Self.stampOnlineRefresh(now: now, calendar: calendar)
            return ZCodePriceCatalog(entries: Self.fallbackEntries().merging(
                Self.entries(official, source: .zaiOfficial, fetchedAt: now)
            ) { _, official in official })
        }

        if let cached = try? Self.loadCache(), !cached.isEmpty {
            return ZCodePriceCatalog(entries: Self.fallbackEntries().merging(
                Self.entries(cached, source: .zaiCache, fetchedAt: Self.cacheModificationDate())
            ) { _, cached in cached })
        }

        return ZCodePriceCatalog(entries: Self.fallbackEntries())
    }

    static let fallbackPrices: [String: ZCodeModelPrice] = [
        "GLM-5.2": ZCodeModelPrice(
            inputCostPerToken: 1.4 / 1_000_000,
            outputCostPerToken: 4.4 / 1_000_000,
            cacheCreationCostPerToken: 1.4 / 1_000_000,
            cacheReadCostPerToken: 0.26 / 1_000_000
        ),
        "GLM-5-Turbo": ZCodeModelPrice(
            inputCostPerToken: 1.2 / 1_000_000,
            outputCostPerToken: 4.0 / 1_000_000,
            cacheCreationCostPerToken: 1.2 / 1_000_000,
            cacheReadCostPerToken: 0.24 / 1_000_000
        )
    ]

    private static func fallbackEntries() -> [String: ZCodePriceEntry] {
        entries(fallbackPrices, source: .builtinFallback, fetchedAt: nil)
    }

    private static func entries(
        _ prices: [String: ZCodeModelPrice],
        source: UsageModelPriceSource,
        fetchedAt: Date?
    ) -> [String: ZCodePriceEntry] {
        var entries: [String: ZCodePriceEntry] = [:]
        for (key, price) in prices {
            entries[ZCodePriceCatalog.normalize(key)] = ZCodePriceEntry(
                price: price,
                source: source,
                fetchedAt: fetchedAt
            )
        }
        return entries
    }

    private func fetchOfficialPrices() throws -> [String: ZCodeModelPrice] {
        var configLines = [
            "silent",
            "show-error",
            QuotaProcessSupport.curlConfigLine("max-time", "20"),
            QuotaProcessSupport.curlConfigLine("url", Self.pricingURL),
            QuotaProcessSupport.curlConfigLine("header", "Accept: text/html,application/xhtml+xml")
        ]
        if let proxy = QuotaProxyResolver.curlProxy(
            for: Self.pricingURL,
            manualOverride: UsageProxyConfig.proxyURL
        ) {
            configLines.append(QuotaProcessSupport.curlConfigLine("proxy", proxy))
        }

        let configURL = try QuotaProcessSupport.writeCurlConfig(configLines)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let result = try QuotaProcessSupport.run(executable: "/usr/bin/curl", arguments: ["-K", configURL.path], timeout: 25)
        guard result.status == 0, !result.stdout.isEmpty else { return [:] }
        return Self.parseZAIPricingPage(result.stdout)
    }

    static func parseZAIPricingPage(_ data: Data) -> [String: ZCodeModelPrice] {
        guard let html = String(data: data, encoding: .utf8) else { return [:] }
        let text = htmlToText(html)
        guard let start = text.range(of: "Prices per 1M tokens. Model Input") else { return [:] }

        let tail = String(text[start.lowerBound...])
        let endMarkers = ["Vision Models", "Prices per 1M tokens."]
            .compactMap { marker -> String.Index? in
                let searchRange = tail.index(after: tail.startIndex)..<tail.endIndex
                return tail.range(of: marker, range: searchRange)?.lowerBound
            }
        let sectionEnd = endMarkers.min() ?? tail.endIndex
        let section = String(tail[..<sectionEnd])
        var prices: [String: ZCodeModelPrice] = [:]

        let pattern = #"\b(GLM-[A-Za-z0-9.\-]+)\s+(\$[0-9.]+|Free)\s+(\$[0-9.]+|Free|-|--)\s+(Limited-time Free|Free|-|--)\s+(\$[0-9.]+|Free)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(section.startIndex..<section.endIndex, in: section)
        for match in regex.matches(in: section, range: nsRange) {
            guard
                let modelRange = Range(match.range(at: 1), in: section),
                let inputRange = Range(match.range(at: 2), in: section),
                let cachedRange = Range(match.range(at: 3), in: section),
                let outputRange = Range(match.range(at: 5), in: section),
                let inputPerMTok = priceValue(String(section[inputRange])),
                let outputPerMTok = priceValue(String(section[outputRange]))
            else { continue }

            let cachedPerMTok = priceValue(String(section[cachedRange]))
            let name = String(section[modelRange])
            prices[name] = ZCodeModelPrice(
                inputCostPerToken: inputPerMTok / 1_000_000,
                outputCostPerToken: outputPerMTok / 1_000_000,
                cacheCreationCostPerToken: inputPerMTok / 1_000_000,
                cacheReadCostPerToken: cachedPerMTok.map { $0 / 1_000_000 }
            )
        }
        return prices
    }

    private static func htmlToText(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: #"(?is)<(script|style|noscript)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = [
            "&nbsp;": " ",
            "&#x27;": "'",
            "&quot;": "\"",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func priceValue(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-" || trimmed == "--" { return nil }
        if trimmed.lowercased() == "free" { return 0 }
        return Double(trimmed.replacingOccurrences(of: "$", with: ""))
    }

    private static func cacheURL() -> URL {
        UsageSnapshotStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("usage_zai_pricing_cache.json")
    }

    private static func markerURL() -> URL {
        UsageSnapshotStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("usage_zai_pricing_refresh")
    }

    private static func loadCache() throws -> [String: ZCodeModelPrice] {
        let data = try Data(contentsOf: cacheURL())
        return try JSONDecoder().decode([String: ZCodeModelPrice].self, from: data)
    }

    private static func cacheModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL().path)
        return attributes?[.modificationDate] as? Date
    }

    private static func saveCache(_ prices: [String: ZCodeModelPrice]) throws {
        let url = cacheURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prices)
        try data.write(to: url, options: .atomic)
    }

    private static func stampOnlineRefresh(now: Date, calendar: Calendar) throws {
        let url = markerURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageCollector.dateKey(now, calendar: calendar).write(to: url, atomically: true, encoding: .utf8)
    }
}
