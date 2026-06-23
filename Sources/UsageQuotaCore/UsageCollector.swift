import Foundation
import QuotaProcessSupport

/// Collects usage by shelling out to the official `ccusage`:
/// - locally via `npx ccusage@latest daily --json`
/// - optionally on a remote host via `ssh <host> ccusage daily --json`
///
/// The two ends are merged by day. The remote end is best-effort: if it is not
/// configured or unreachable, the local data is used as-is and `reachableHosts`
/// records the degradation so the app/widget can surface it. There is no other
/// fallback — the acquisition path is the single source of truth, and all the
/// week/month/total/breakdown aggregation is derived locally from one `daily`
/// call per end (summation is free; process spawns are the only cost, so every
/// invocation is issued concurrently).
public struct UsageCollector: Sendable {
    public init() {}

    /// How ccusage should price token usage. `.auto` runs ccusage online every
    /// refresh because ccusage's embedded pricing can miss or misprice local
    /// models; `.offline` is kept only as an explicit manual fast path.
    public enum PricingMode: Sendable {
        case auto
        case online
        case offline
    }

    public func collect(now: Date = Date(), calendar: Calendar = .current, mode: PricingMode = .auto) -> UsageSnapshot {
        let offline = Self.shouldRunCcusageOffline(mode: mode)
        let pricingArgs = offline ? ["--offline"] : []
        let hosts = UsageRemoteConfig.remoteHosts
        let remoteEndpoints = hosts.map { Endpoint.remote($0) }
        let zcodeTask = Self.startZCodeCollection(now: now, calendar: calendar, mode: mode)
        let litellmTask = Self.startLiteLLMCatalog(now: now, calendar: calendar, mode: mode)

        // Wave 1: combined `daily --json` on local + every configured remote,
        // concurrently. Only the remotes that respond get merged in.
        let wave1 = Self.runCommands(([Endpoint.local] + remoteEndpoints).map { ($0, ["daily", "--json"] + pricingArgs) })

        var localRows: [DailyRow]?
        var localError = wave1[0].errorMessage ?? UsageCollectorError.ccusageNotFound.localizedDescription
        if let output = wave1[0].output {
            do {
                localRows = try Self.parseCombined(output)
                localError = ""
            } catch {
                localError = error.localizedDescription
            }
        }

        var hostRows: [HostRows] = []
        var endpoints: [Endpoint] = []
        if let localRows {
            hostRows.append(HostRows(id: "host:local", name: "本机", rows: localRows))
            endpoints.append(.local)
        }

        var reachableHosts: [String] = []
        for (offset, host) in hosts.enumerated() {
            if let output = wave1[offset + 1].output, let rows = try? Self.parseCombined(output) {
                hostRows.append(HostRows(id: "host:\(host)", name: host, rows: rows))
                endpoints.append(.remote(host))
                reachableHosts.append(host)
            }
        }
        let ccusageModelPrices = Self.ccusageModelPriceRecords(
            from: hostRows,
            fetchedAt: now,
            unitPrices: litellmTask.wait()
        )

        // Wave 2: per-agent `<agent> daily --json`. Only hit the remotes whose
        // combined call succeeded — the rest would just fail again.
        var agentRowsByHostID: [String: [String: [DailyRow]]] = [:]
        if !hostRows.isEmpty {
            let jobs = zip(hostRows, endpoints).flatMap { host, endpoint in
                host.agentIDs.map { AgentJob(hostID: host.id, endpoint: endpoint, agent: $0) }
            }
            let wave2 = Self.runCommands(jobs.map { ($0.endpoint, [$0.agent, "daily", "--json"] + pricingArgs) })

            for (index, job) in jobs.enumerated() {
                if let output = wave2[index].output, let rows = try? Self.parseAgent(output, agent: job.agent), !rows.isEmpty {
                    agentRowsByHostID[job.hostID, default: [:]][job.agent] = rows
                }
            }
        }

        let zcodeResult = zcodeTask.wait()
        let zcodeRows = zcodeResult.rows
        let localExtensions = zcodeRows.isEmpty ? [] : [ZCodeUsageCollector.agentName]
        if !zcodeRows.isEmpty {
            if let localIndex = hostRows.firstIndex(where: { $0.id == "host:local" }) {
                hostRows[localIndex].rows = Self.mergeRows([hostRows[localIndex].rows, zcodeRows])
            } else {
                hostRows.insert(HostRows(id: "host:local", name: "本机", rows: zcodeRows), at: 0)
            }
            agentRowsByHostID["host:local", default: [:]][ZCodeUsageCollector.agentName] = zcodeRows
        }

        guard !hostRows.isEmpty else {
            let reason = localError.isEmpty ? "所有 ccusage 来源均不可用" : localError
            return UsageSnapshot(
                generatedAt: now,
                sources: UsageSources(localReachable: false, remoteHosts: hosts, reachableHosts: []),
                error: reason
            )
        }

        return Self.snapshot(
            generatedAt: now,
            calendar: calendar,
            localReachable: localRows != nil,
            remoteHosts: hosts,
            reachableHosts: reachableHosts,
            hostRows: hostRows,
            agentRowsByHostID: agentRowsByHostID,
            localExtensions: localExtensions,
            modelPrices: Self.mergeModelPriceRecords(ccusageModelPrices + zcodeResult.modelPrices)
        )
    }

    // MARK: - Pricing mode

    static func shouldRunCcusageOffline(mode: PricingMode) -> Bool {
        switch mode {
        case .offline: return true
        case .online, .auto: return false
        }
    }

    /// Daily online refresh policy for extension pricing sources such as ZCode.
    /// ccusage does not use this helper: it runs online for every `.auto` refresh.
    static func shouldRunOffline(mode: PricingMode, lastOnlineDay: String?, now: Date, calendar: Calendar) -> Bool {
        switch mode {
        case .offline: return true
        case .online: return false
        case .auto:
            guard let lastOnlineDay, !lastOnlineDay.isEmpty else { return false }
            return lastOnlineDay == dateKey(now, calendar: calendar)
        }
    }

    private static func startZCodeCollection(now: Date, calendar: Calendar, mode: PricingMode) -> ZCodeTask {
        guard UsageZCodeConfig.enabled else { return ZCodeTask.empty }

        let result = Box<ZCodeUsageCollector.Result?>(nil)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "usage.zcode.collect", qos: .utility)
        group.enter()
        queue.async {
            let collected = (try? ZCodeUsageCollector().collect(now: now, calendar: calendar, mode: mode)) ?? ZCodeUsageCollector.Result()
            result.withLock { $0 = collected }
            group.leave()
        }
        return ZCodeTask(group: group, result: result)
    }

    private static func startLiteLLMCatalog(now: Date, calendar: Calendar, mode: PricingMode) -> CatalogTask {
        let result = Box<LiteLLMPricingCatalog?>(nil)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "usage.litellm.pricing", qos: .utility)
        group.enter()
        queue.async {
            let catalog = LiteLLMPricingResolver().catalog(mode: mode, now: now, calendar: calendar)
            result.withLock { $0 = catalog }
            group.leave()
        }
        return CatalogTask(group: group, result: result)
    }

    static func snapshot(
        generatedAt: Date,
        calendar: Calendar,
        localReachable: Bool,
        remoteHosts: [String],
        reachableHosts: [String],
        hostRows: [HostRows],
        agentRowsByHostID: [String: [String: [DailyRow]]],
        localExtensions: [String] = [],
        modelPrices: [UsageModelPriceRecord] = []
    ) -> UsageSnapshot {
        let overviewRows = Self.mergeRows(hostRows.map(\.rows))
        let hosts = hostRows.map { host in
            Self.hostSnapshot(
                id: host.id,
                name: host.name,
                combinedRows: host.rows,
                agentRowsByAgent: agentRowsByHostID[host.id] ?? [:],
                now: generatedAt,
                calendar: calendar
            )
        }
        let agents = Self.globalAgentSnapshots(from: hosts, now: generatedAt, calendar: calendar)
        let ends = reachableHosts.isEmpty ? [] : hostRows.map { host in
            Self.scopeSnapshot(
                id: host.id == "host:local" ? "end:local" : "end:\(host.name)",
                name: host.name,
                rows: host.rows,
                now: generatedAt,
                calendar: calendar,
                idPrefix: "\(host.id)-end-"
            )
        }
        let overview = Self.scope(rows: overviewRows, now: generatedAt, calendar: calendar, idPrefix: "")
        return UsageSnapshot(
            generatedAt: generatedAt,
            daily: overview.daily,
            weekly: overview.weekly,
            monthly: overview.monthly,
            total: overview.total,
            weekDays: overview.weekDays,
            breakdowns: overview.breakdowns,
            sources: UsageSources(
                localReachable: localReachable,
                remoteHosts: remoteHosts,
                reachableHosts: reachableHosts,
                localExtensions: localExtensions,
                agents: agents.map(\.name)
            ),
            hosts: hosts,
            agents: agents,
            ends: ends,
            modelPrices: modelPrices
        )
    }

    // MARK: - Aggregation (pure)

    struct HostRows {
        var id: String
        var name: String
        var rows: [DailyRow]

        var agentIDs: [String] {
            Set(rows.flatMap(\.agents)).sorted()
        }
    }

    struct AgentJob {
        var hostID: String
        var endpoint: Endpoint
        var agent: String
    }

    struct Scope {
        var daily: UsageSummary
        var weekly: UsageSummary
        var monthly: UsageSummary
        var total: UsageSummary
        var weekDays: [UsageDay]
        var breakdowns: [UsageBreakdownSection]
    }

    static func hostSnapshot(
        id: String,
        name: String,
        combinedRows: [DailyRow],
        agentRowsByAgent: [String: [DailyRow]],
        now: Date,
        calendar: Calendar
    ) -> UsageHostSnapshot {
        let overview = Self.scopeSnapshot(
            id: "\(id):overview",
            name: "总览",
            rows: combinedRows,
            now: now,
            calendar: calendar,
            idPrefix: "\(id)-overview-"
        )
        let agents = agentRowsByAgent.keys.sorted().map { agent in
            let rows = Self.borrowModelCosts(
                into: Self.mergeRows([agentRowsByAgent[agent] ?? []]),
                from: combinedRows
            )
            return Self.scopeSnapshot(
                id: "\(id):agent:\(agent)",
                name: agent,
                rows: rows,
                now: now,
                calendar: calendar,
                idPrefix: "\(id)-\(agent)-"
            )
        }
        return UsageHostSnapshot(id: id, name: name, overview: overview, agents: agents)
    }

    private static func globalAgentSnapshots(
        from hosts: [UsageHostSnapshot],
        now: Date,
        calendar: Calendar
    ) -> [UsageAgentSnapshot] {
        let agentNames = Set(hosts.flatMap { $0.agents.map(\.name) }).sorted()
        return agentNames.map { agent in
            let rows = hosts.compactMap { host in
                host.agents.first { $0.name == agent }
            }
            return Self.mergeAgentSnapshots(id: agent, name: agent, snapshots: rows, now: now, calendar: calendar)
        }
    }

    private static func mergeAgentSnapshots(
        id: String,
        name: String,
        snapshots: [UsageAgentSnapshot],
        now: Date,
        calendar: Calendar
    ) -> UsageAgentSnapshot {
        let weekKeys = currentWeekKeys(now: now, calendar: calendar)
        let breakdowns = ["today-models", "week-models", "month-models", "total-models"].map { suffix in
            let items = mergeBreakdownItems(snapshots.flatMap { snapshot in
                snapshot.breakdowns.first { $0.id.hasSuffix(suffix) }?.items ?? []
            })
            return UsageBreakdownSection(id: "\(id)-\(suffix)", title: breakdownTitle(suffix), items: items)
        }
        return UsageAgentSnapshot(
            id: id,
            name: name,
            daily: snapshots.reduce(UsageSummary()) { $0 + $1.daily },
            weekly: snapshots.reduce(UsageSummary()) { $0 + $1.weekly },
            monthly: snapshots.reduce(UsageSummary()) { $0 + $1.monthly },
            total: snapshots.reduce(UsageSummary()) { $0 + $1.total },
            weekDays: weekKeys.map { key in
                let summary = snapshots
                    .compactMap { $0.weekDays.first { $0.period == key }?.summary }
                    .reduce(UsageSummary(), +)
                return UsageDay(period: key, summary: summary)
            },
            breakdowns: breakdowns
        )
    }

    private static func mergeBreakdownItems(_ items: [UsageBreakdownItem]) -> [UsageBreakdownItem] {
        var grouped: [String: UsageSummary] = [:]
        for item in items {
            grouped[item.name, default: UsageSummary()] = grouped[item.name, default: UsageSummary()] + UsageSummary(
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheCreationTokens: item.cacheCreationTokens,
                cacheReadTokens: item.cacheReadTokens,
                totalTokens: item.totalTokens,
                totalCost: item.totalCost
            )
        }
        let totalCost = grouped.values.reduce(0) { $0 + $1.totalCost }
        return grouped.map { name, summary in
            UsageBreakdownItem(
                name: name,
                inputTokens: summary.inputTokens,
                outputTokens: summary.outputTokens,
                cacheCreationTokens: summary.cacheCreationTokens,
                cacheReadTokens: summary.cacheReadTokens,
                totalTokens: summary.totalTokens,
                totalCost: rounded(summary.totalCost),
                percent: totalCost > 0 ? rounded(summary.totalCost / totalCost * 100, digits: 1) : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost { return lhs.name < rhs.name }
            return lhs.totalCost > rhs.totalCost
        }
    }

    static func ccusageModelPriceRecords(
        from hostRows: [HostRows],
        fetchedAt: Date,
        unitPrices: LiteLLMPricingCatalog? = nil
    ) -> [UsageModelPriceRecord] {
        struct Accumulator {
            var summary = UsageSummary()
            var agents = Set<String>()
        }

        var grouped: [String: Accumulator] = [:]
        for host in hostRows {
            for row in host.rows {
                for (model, summary) in row.models {
                    var accumulator = grouped[model] ?? Accumulator()
                    accumulator.summary = accumulator.summary + summary
                    accumulator.agents.formUnion(row.agents)
                    grouped[model] = accumulator
                }
            }
        }

        return grouped.map { model, accumulator in
            let unitPrice = unitPrices?.entry(for: model)
            return UsageModelPriceRecord(
                modelName: model,
                source: .ccusageReport,
                fetchedAt: fetchedAt,
                unitPriceSource: unitPrice == nil ? nil : .litellmCache,
                unitPriceFetchedAt: unitPrice?.fetchedAt,
                inputCostPerMTokUSD: unitPrice?.price.inputCostPerToken.map(perMillionTokens),
                outputCostPerMTokUSD: unitPrice?.price.outputCostPerToken.map(perMillionTokens),
                cacheCreationCostPerMTokUSD: unitPrice?.price.cacheCreationInputTokenCost.map(perMillionTokens),
                cacheReadCostPerMTokUSD: unitPrice?.price.cacheReadInputTokenCost.map(perMillionTokens),
                effectiveCostPerMTokUSD: effectiveCostPerMTok(accumulator.summary),
                totalTokens: accumulator.summary.totalTokens,
                totalCost: accumulator.summary.totalCost,
                agents: accumulator.agents.sorted()
            )
        }
        .filter { $0.totalTokens > 0 }
        .sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost { return lhs.modelName < rhs.modelName }
            return lhs.totalCost > rhs.totalCost
        }
    }

    static func mergeModelPriceRecords(_ records: [UsageModelPriceRecord]) -> [UsageModelPriceRecord] {
        var grouped: [String: UsageModelPriceRecord] = [:]
        for record in records {
            let key = "\(record.source.rawValue):\(record.modelName)"
            if var existing = grouped[key] {
                existing.totalTokens += record.totalTokens
                existing.totalCost += record.totalCost
                existing.effectiveCostPerMTokUSD = effectiveCostPerMTok(UsageSummary(
                    totalTokens: existing.totalTokens,
                    totalCost: existing.totalCost
                ))
                existing.agents = Array(Set(existing.agents).union(record.agents)).sorted()
                if existing.fetchedAt == nil {
                    existing.fetchedAt = record.fetchedAt
                }
                if existing.unitPriceSource == nil {
                    existing.unitPriceSource = record.unitPriceSource
                }
                if existing.unitPriceFetchedAt == nil {
                    existing.unitPriceFetchedAt = record.unitPriceFetchedAt
                }
                if existing.inputCostPerMTokUSD == nil {
                    existing.inputCostPerMTokUSD = record.inputCostPerMTokUSD
                }
                if existing.outputCostPerMTokUSD == nil {
                    existing.outputCostPerMTokUSD = record.outputCostPerMTokUSD
                }
                if existing.cacheCreationCostPerMTokUSD == nil {
                    existing.cacheCreationCostPerMTokUSD = record.cacheCreationCostPerMTokUSD
                }
                if existing.cacheReadCostPerMTokUSD == nil {
                    existing.cacheReadCostPerMTokUSD = record.cacheReadCostPerMTokUSD
                }
                grouped[key] = existing
            } else {
                grouped[key] = record
            }
        }

        return grouped.values.sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost {
                if lhs.modelName == rhs.modelName { return lhs.source.rawValue < rhs.source.rawValue }
                return lhs.modelName < rhs.modelName
            }
            return lhs.totalCost > rhs.totalCost
        }
    }

    private static func effectiveCostPerMTok(_ summary: UsageSummary) -> Double? {
        guard summary.totalTokens > 0 else { return nil }
        return summary.totalCost / Double(summary.totalTokens) * 1_000_000
    }

    private static func perMillionTokens(_ costPerToken: Double) -> Double {
        costPerToken * 1_000_000
    }

    private static func breakdownTitle(_ suffix: String) -> String {
        switch suffix {
        case "today-models": return "今日模型"
        case "week-models": return "本周模型"
        case "month-models": return "本月模型"
        case "total-models": return "总计模型"
        default: return "模型"
        }
    }

    private static func scopeSnapshot(
        id: String,
        name: String,
        rows: [DailyRow],
        now: Date,
        calendar: Calendar,
        idPrefix: String
    ) -> UsageAgentSnapshot {
        let scope = Self.scope(rows: rows, now: now, calendar: calendar, idPrefix: idPrefix)
        return UsageAgentSnapshot(
            id: id,
            name: name,
            daily: scope.daily,
            weekly: scope.weekly,
            monthly: scope.monthly,
            total: scope.total,
            weekDays: scope.weekDays,
            breakdowns: scope.breakdowns
        )
    }

    /// Merge daily rows from several ends into one set keyed by day.
    static func mergeRows(_ rowSets: [[DailyRow]]) -> [DailyRow] {
        var byPeriod: [String: DailyRow] = [:]
        for rows in rowSets {
            for row in rows {
                if var existing = byPeriod[row.period] {
                    existing.summary = existing.summary + row.summary
                    existing.agents = Array(Set(existing.agents).union(row.agents)).sorted()
                    for (model, summary) in row.models {
                        existing.models[model, default: UsageSummary()] = existing.models[model, default: UsageSummary()] + summary
                    }
                    byPeriod[row.period] = existing
                } else {
                    byPeriod[row.period] = row
                }
            }
        }
        return byPeriod.values.sorted { $0.period < $1.period }
    }

    /// Fill in per-model cost that an agent's report omits (e.g. codex reports
    /// per-model tokens but no per-model cost) by borrowing the real per-model
    /// cost from the combined overview report. The combined cost for a model is
    /// split by the agent's token share of that model — exact, because tokens of
    /// the same model share a price. Models that already carry a cost are left
    /// untouched.
    static func borrowModelCosts(into agentRows: [DailyRow], from combinedRows: [DailyRow]) -> [DailyRow] {
        var combinedByPeriod: [String: [String: UsageSummary]] = [:]
        for row in combinedRows {
            combinedByPeriod[row.period] = row.models
        }

        return agentRows.map { row in
            guard let realModels = combinedByPeriod[row.period] else { return row }
            var models = row.models
            for (name, summary) in models where summary.totalCost == 0 {
                guard let real = realModels[name], real.totalTokens > 0, real.totalCost > 0 else { continue }
                var updated = summary
                updated.totalCost = real.totalCost * Double(summary.totalTokens) / Double(real.totalTokens)
                models[name] = updated
            }
            var copy = row
            copy.models = models
            return copy
        }
    }

    /// Derive day/week/month/total/weekDays/breakdowns from merged daily rows.
    static func scope(rows: [DailyRow], now: Date, calendar: Calendar, idPrefix: String) -> Scope {
        let today = dateKey(now, calendar: calendar)
        let monthPrefix = String(today.prefix(7))
        let weekKeys = currentWeekKeys(now: now, calendar: calendar)
        let weekSet = Set(weekKeys)

        let todayRows = rows.filter { $0.period == today }
        let weekRows = rows.filter { weekSet.contains($0.period) }
        let monthRows = rows.filter { $0.period.hasPrefix(monthPrefix) }

        return Scope(
            daily: summarize(todayRows),
            weekly: summarize(weekRows),
            monthly: summarize(monthRows),
            total: summarize(rows),
            weekDays: weekKeys.map { key in
                UsageDay(period: key, summary: summarize(rows.filter { $0.period == key }))
            },
            breakdowns: [
                UsageBreakdownSection(id: "\(idPrefix)today-models", title: "今日模型", items: breakdownItems(todayRows)),
                UsageBreakdownSection(id: "\(idPrefix)week-models", title: "本周模型", items: breakdownItems(weekRows)),
                UsageBreakdownSection(id: "\(idPrefix)month-models", title: "本月模型", items: breakdownItems(monthRows)),
                UsageBreakdownSection(id: "\(idPrefix)total-models", title: "总计模型", items: breakdownItems(rows))
            ]
        )
    }

    private static func summarize(_ rows: [DailyRow]) -> UsageSummary {
        rows.reduce(UsageSummary()) { $0 + $1.summary }
    }

    private static func breakdownItems(_ rows: [DailyRow]) -> [UsageBreakdownItem] {
        var grouped: [String: UsageSummary] = [:]
        for row in rows {
            for (model, summary) in row.models {
                grouped[model, default: UsageSummary()] = grouped[model, default: UsageSummary()] + summary
            }
        }

        let totalCost = grouped.values.reduce(0) { $0 + $1.totalCost }
        return grouped
            .map { name, summary in
                UsageBreakdownItem(
                    name: name,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    cacheCreationTokens: summary.cacheCreationTokens,
                    cacheReadTokens: summary.cacheReadTokens,
                    totalTokens: summary.totalTokens,
                    totalCost: rounded(summary.totalCost),
                    percent: totalCost > 0 ? rounded(summary.totalCost / totalCost * 100, digits: 1) : 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalCost == rhs.totalCost { return lhs.name < rhs.name }
                return lhs.totalCost > rhs.totalCost
            }
    }

    // MARK: - Parsing (pure)

    /// Official combined `ccusage daily --json` → unified rows.
    static func parseCombined(_ output: String) throws -> [DailyRow] {
        let report = try JSONDecoder().decode(CombinedReport.self, from: Data(output.utf8))
        return report.daily.map { row in
            var models: [String: UsageSummary] = [:]
            for model in row.modelBreakdowns {
                let key = Self.modelKey(model.modelName)
                models[key, default: UsageSummary()] = models[key, default: UsageSummary()] + model.summary
            }
            return DailyRow(period: row.period, summary: row.summary, agents: row.metadata?.agents ?? [], models: models)
        }
    }

    /// Official per-agent `ccusage <agent> daily --json` → unified rows. This
    /// schema differs from the combined one (`date`, `costUSD`, `models` object).
    static func parseAgent(_ output: String, agent: String) throws -> [DailyRow] {
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(output.utf8))
        return report.daily.compactMap { row in
            guard !row.period.isEmpty else { return nil }
            return DailyRow(period: row.period, summary: row.summary, agents: [agent], models: row.models)
        }
    }

    static func modelKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Process execution

    enum Endpoint: Hashable, Sendable {
        case local
        case remote(String)
    }

    struct CmdResult: Sendable {
        var output: String?
        var errorMessage: String?
    }

    /// Run several ccusage invocations concurrently; results are index-aligned
    /// with `specs`.
    static func runCommands(_ specs: [(Endpoint, [String])]) -> [CmdResult] {
        guard !specs.isEmpty else { return [] }
        let results = Box([CmdResult?](repeating: nil, count: specs.count))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "usage.ccusage.batch", attributes: .concurrent)
        for (index, spec) in specs.enumerated() {
            queue.async(group: group) {
                let result: CmdResult
                do {
                    result = CmdResult(output: try runCcusage(endpoint: spec.0, ccusageArgs: spec.1), errorMessage: nil)
                } catch {
                    result = CmdResult(output: nil, errorMessage: error.localizedDescription)
                }
                results.withLock { $0[index] = result }
            }
        }
        group.wait()
        return results.value.map { $0 ?? CmdResult(output: nil, errorMessage: nil) }
    }

    private static func runCcusage(endpoint: Endpoint, ccusageArgs: [String]) throws -> String {
        switch endpoint {
        case .local:
            // Keep local collection local-only; global ccusage may be a wrapper that already merges remotes.
            guard let npx = locateExecutable("npx") else { throw UsageCollectorError.ccusageNotFound }
            return try runProcess(executable: npx, arguments: ["-y", "ccusage@latest"] + ccusageArgs)
        case .remote(let host):
            let ssh = locateExecutable("ssh") ?? "/usr/bin/ssh"
            // `ssh host <cmd>` runs a non-interactive, non-login shell that lacks
            // the user's PATH (nvm/npm-global/homebrew), so `ccusage` would not be
            // found. Run it through a login shell and quote the whole command so
            // the remote shell does not re-split it.
            let remoteCommand = (["ccusage"] + ccusageArgs).joined(separator: " ")
            let arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "bash -lc \(shellQuote(remoteCommand))"]
            return try runProcess(executable: ssh, arguments: arguments)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runProcess(executable: String, arguments: [String]) throws -> String {
        let result = try QuotaProcessSupport.run(executable: executable, arguments: arguments, timeout: 90)
        let output = result.stdoutString
        let errorOutput = result.stderrString

        guard result.status == 0 else {
            throw UsageCollectorError.commandFailed(errorOutput.isEmpty ? output : errorOutput)
        }
        return output
    }

    private static func locateExecutable(_ name: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for dir in dirs {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Date helpers

    private static func currentWeekKeys(now: Date, calendar: Calendar) -> [String] {
        let start = startOfWeek(now, calendar: calendar)
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { dateKey($0, calendar: calendar) }
        }
    }

    private static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysFromMonday = weekday == 1 ? 6 : weekday - 2
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: dayStart) ?? dayStart
    }

    static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func rounded(_ value: Double, digits: Int = 6) -> Double {
        let scale = pow(10, Double(digits))
        return (value * scale).rounded() / scale
    }
}

/// Unified daily row used internally so the combined and per-agent ccusage
/// schemas funnel into one aggregation path.
struct DailyRow {
    var period: String
    var summary: UsageSummary
    var agents: [String]
    var models: [String: UsageSummary]
}

struct ZCodeTask {
    var group: DispatchGroup?
    var result: Box<ZCodeUsageCollector.Result?>?

    static let empty = ZCodeTask(group: nil, result: nil)

    func wait() -> ZCodeUsageCollector.Result {
        guard let group, let result else { return ZCodeUsageCollector.Result() }
        group.wait()
        return result.value ?? ZCodeUsageCollector.Result()
    }
}

/// Background fetch of the LiteLLM unit-price catalog, awaited before the
/// ccusage model-price records are assembled.
struct CatalogTask {
    var group: DispatchGroup?
    var result: Box<LiteLLMPricingCatalog?>?

    func wait() -> LiteLLMPricingCatalog? {
        guard let group, let result else { return nil }
        group.wait()
        return result.value
    }
}

/// Lock-guarded holder so reader/worker closures can write results without
/// tripping Swift's concurrent-capture diagnostics. Each slot is written once
/// and only read after the owning `DispatchGroup` has completed.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
}

enum UsageCollectorError: LocalizedError {
    case ccusageNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .ccusageNotFound:
            return "未找到 ccusage（需要本机可执行 npx）"
        case .commandFailed(let message):
            return "ccusage 执行失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

// MARK: - ccusage JSON (combined `daily`)

private struct CombinedReport: Decodable {
    var daily: [CombinedRow]
}

private struct CombinedRow: Decodable {
    var period: String
    var metadata: CombinedMetadata?
    var modelBreakdowns: [CombinedModel]
    var summary: UsageSummary

    private enum CodingKeys: String, CodingKey {
        case period, metadata, modelBreakdowns
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens, totalCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decode(String.self, forKey: .period)
        metadata = try container.decodeIfPresent(CombinedMetadata.self, forKey: .metadata)
        modelBreakdowns = try container.decodeIfPresent([CombinedModel].self, forKey: .modelBreakdowns) ?? []
        summary = UsageSummary(
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            cacheCreationTokens: try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0,
            cacheReadTokens: try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0,
            totalCost: try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        )
    }
}

private struct CombinedMetadata: Decodable {
    var agents: [String]?
}

private struct CombinedModel: Decodable {
    var modelName: String
    var summary: UsageSummary

    private enum CodingKeys: String, CodingKey {
        case modelName, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try container.decode(String.self, forKey: .modelName)
        let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        let cacheCreate = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        summary = UsageSummary(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheCreate + cacheRead,
            totalCost: try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        )
    }
}

// MARK: - ccusage JSON (per-agent `<agent> daily`)

private struct AgentReport: Decodable {
    var daily: [AgentRow]
}

private struct AgentRow: Decodable {
    var period: String
    var summary: UsageSummary
    var models: [String: UsageSummary]

    private enum CodingKeys: String, CodingKey {
        case period, date, models, modelBreakdowns
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens
        case costUSD, totalCost, cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decodeIfPresent(String.self, forKey: .period)
            ?? container.decodeIfPresent(String.self, forKey: .date)
            ?? ""

        let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        let cacheCreate = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        let totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        let cost = try container.decodeIfPresent(Double.self, forKey: .costUSD)
            ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            ?? container.decodeIfPresent(Double.self, forKey: .cost)
            ?? 0
        summary = UsageSummary(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: totalTokens ?? (input + output + cacheCreate + cacheRead),
            totalCost: cost
        )

        // Per-agent model breakdown varies by agent: some emit a `modelBreakdowns`
        // array (same shape as the combined report), others a `models` object,
        // and an empty array when there is nothing. Prefer the array, fall back
        // to the object, default to none.
        var built: [String: UsageSummary] = [:]
        if let breakdowns = try? container.decodeIfPresent([CombinedModel].self, forKey: .modelBreakdowns) {
            for model in breakdowns {
                let key = UsageCollector.modelKey(model.modelName)
                built[key, default: UsageSummary()] = built[key, default: UsageSummary()] + model.summary
            }
        } else if let object = try? container.decodeIfPresent([String: AgentModel].self, forKey: .models) {
            for (name, model) in object {
                let key = UsageCollector.modelKey(name)
                built[key, default: UsageSummary()] = built[key, default: UsageSummary()] + model.summary
            }
        }
        // Some agents (e.g. codex) report per-model tokens but no per-model cost.
        // Those zero costs are filled in later from the combined overview report
        // (see UsageCollector.borrowModelCosts).
        models = built
    }
}

private struct AgentModel: Decodable {
    var summary: UsageSummary

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, totalTokens
        case cost, costUSD, totalCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let input = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        let output = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        let cacheCreate = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        let cacheRead = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        let totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        let cost = try container.decodeIfPresent(Double.self, forKey: .cost)
            ?? container.decodeIfPresent(Double.self, forKey: .costUSD)
            ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            ?? 0
        summary = UsageSummary(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: totalTokens ?? (input + output + cacheCreate + cacheRead),
            totalCost: cost
        )
    }
}
