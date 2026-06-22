import Foundation

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

    /// How ccusage should price token usage. The slow part of a refresh is not
    /// parsing the JSONL logs (~2s) but ccusage fetching live model pricing over
    /// the network (~10s extra). `--offline` uses the bundled pricing snapshot
    /// instead, which is exact for mainstream models but reports $0 for models
    /// missing from the snapshot (e.g. GLM/DeepSeek/MiMo). `.auto` therefore runs
    /// online at most once per calendar day to refresh those prices, and offline
    /// the rest of the time.
    public enum PricingMode: Sendable {
        case auto
        case online
        case offline
    }

    public func collect(now: Date = Date(), calendar: Calendar = .current, mode: PricingMode = .auto) -> UsageSnapshot {
        let offline = Self.resolveOffline(mode: mode, now: now, calendar: calendar)
        let pricingArgs = offline ? ["--offline"] : []
        let hosts = UsageRemoteConfig.remoteHosts
        let remoteEndpoints = hosts.map { Endpoint.remote($0) }

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

        guard !hostRows.isEmpty else {
            let reason = localError.isEmpty ? "所有 ccusage 来源均不可用" : localError
            return UsageSnapshot(
                generatedAt: now,
                sources: UsageSources(localReachable: false, remoteHosts: hosts, reachableHosts: []),
                error: reason
            )
        }

        // Wave 2: per-agent `<agent> daily --json`. Only hit the remotes whose
        // combined call succeeded — the rest would just fail again.
        let jobs = zip(hostRows, endpoints).flatMap { host, endpoint in
            host.agentIDs.map { AgentJob(hostID: host.id, endpoint: endpoint, agent: $0) }
        }
        let wave2 = Self.runCommands(jobs.map { ($0.endpoint, [$0.agent, "daily", "--json"] + pricingArgs) })

        var agentRowsByHostID: [String: [String: [DailyRow]]] = [:]
        for (index, job) in jobs.enumerated() {
            if let output = wave2[index].output, let rows = try? Self.parseAgent(output, agent: job.agent), !rows.isEmpty {
                agentRowsByHostID[job.hostID, default: [:]][job.agent] = rows
            }
        }

        // A successful online run has just refreshed ccusage's live pricing, so
        // record the day; `.auto` stays offline until the next calendar day.
        if !offline {
            Self.stampOnlineRefresh(now: now, calendar: calendar)
        }

        return Self.snapshot(
            generatedAt: now,
            calendar: calendar,
            localReachable: localRows != nil,
            remoteHosts: hosts,
            reachableHosts: reachableHosts,
            hostRows: hostRows,
            agentRowsByHostID: agentRowsByHostID
        )
    }

    // MARK: - Pricing freshness (`.auto`)

    /// `.auto` runs online when no online refresh has succeeded yet today, so the
    /// bundled-pricing gaps (third-party models priced at $0 offline) are filled
    /// in at most once per day; otherwise it stays on the fast offline path.
    static func resolveOffline(mode: PricingMode, now: Date, calendar: Calendar) -> Bool {
        let lastOnlineDay = (try? String(contentsOf: pricingMarkerURL(), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shouldRunOffline(mode: mode, lastOnlineDay: lastOnlineDay, now: now, calendar: calendar)
    }

    /// Pure pricing-mode decision: offline unless an online refresh is due. In
    /// `.auto`, online is due when no online run has succeeded on the current
    /// calendar day yet (no marker, or a marker from an earlier day).
    static func shouldRunOffline(mode: PricingMode, lastOnlineDay: String?, now: Date, calendar: Calendar) -> Bool {
        switch mode {
        case .offline: return true
        case .online: return false
        case .auto:
            guard let lastOnlineDay, !lastOnlineDay.isEmpty else { return false }
            return lastOnlineDay == dateKey(now, calendar: calendar)
        }
    }

    private static func stampOnlineRefresh(now: Date, calendar: Calendar) {
        let url = pricingMarkerURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? dateKey(now, calendar: calendar).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func pricingMarkerURL() -> URL {
        UsageSnapshotStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("usage_pricing_refresh")
    }

    static func snapshot(
        generatedAt: Date,
        calendar: Calendar,
        localReachable: Bool,
        remoteHosts: [String],
        reachableHosts: [String],
        hostRows: [HostRows],
        agentRowsByHostID: [String: [String: [DailyRow]]]
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
                agents: agents.map(\.name)
            ),
            hosts: hosts,
            agents: agents,
            ends: ends
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
        let breakdowns = ["today-models", "week-models", "month-models"].map { suffix in
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

    private static func breakdownTitle(_ suffix: String) -> String {
        switch suffix {
        case "today-models": return "今日模型"
        case "week-models": return "本周模型"
        case "month-models": return "本月模型"
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
                UsageBreakdownSection(id: "\(idPrefix)month-models", title: "本月模型", items: breakdownItems(monthRows))
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
                models[model.modelName, default: UsageSummary()] = models[model.modelName, default: UsageSummary()] + model.summary
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes on background threads while the process runs. ccusage
        // can emit well over the 64KB pipe buffer, so reading only after exit
        // would deadlock the child against a full pipe. readDataToEndOfFile
        // returns once the write ends close, i.e. when the process exits.
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "usage.ccusage.read", attributes: .concurrent)
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        readQueue.async(group: readGroup) { outputBox.value = outputHandle.readDataToEndOfFile() }
        readQueue.async(group: readGroup) { errorBox.value = errorHandle.readDataToEndOfFile() }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + 90) == .timedOut {
            process.terminate()
            _ = readGroup.wait(timeout: .now() + 5)
            throw UsageCollectorError.commandFailed("\(executable) timed out")
        }
        readGroup.wait()

        let output = String(data: outputBox.value, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorBox.value, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
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

    private static func dateKey(_ date: Date, calendar: Calendar) -> String {
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

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
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
                built[model.modelName, default: UsageSummary()] = built[model.modelName, default: UsageSummary()] + model.summary
            }
        } else if let object = try? container.decodeIfPresent([String: AgentModel].self, forKey: .models) {
            for (name, model) in object {
                built[name, default: UsageSummary()] = built[name, default: UsageSummary()] + model.summary
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
