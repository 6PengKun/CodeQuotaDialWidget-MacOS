import Foundation
import Testing

@testable import UsageQuotaCore

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Test func parsesCombinedDailyReport() throws {
    let json = """
    {
      "daily": [
        {
          "period": "2026-06-21",
          "metadata": { "agents": ["codex", "claude"] },
          "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0,
          "cacheReadTokens": 350, "totalTokens": 500, "totalCost": 10.0,
          "modelBreakdowns": [
            { "modelName": "gpt-5.4", "inputTokens": 80, "outputTokens": 40, "cacheCreationTokens": 0, "cacheReadTokens": 280, "cost": 8.0 },
            { "modelName": "claude-opus", "inputTokens": 20, "outputTokens": 10, "cacheCreationTokens": 0, "cacheReadTokens": 70, "cost": 2.0 }
          ]
        }
      ]
    }
    """

    let rows = try UsageCollector.parseCombined(json)
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.period == "2026-06-21")
    #expect(row.summary.totalTokens == 500)
    #expect(row.summary.totalCost == 10.0)
    #expect(Set(row.agents) == ["codex", "claude"])
    #expect(row.models["gpt-5.4"]?.totalCost == 8.0)
    #expect(row.models["gpt-5.4"]?.totalTokens == 400) // 80 + 40 + 0 + 280
}

@Test func parsesPerAgentReportWithObjectModelsAndCostUSD() throws {
    let json = """
    {
      "daily": [
        {
          "date": "2026-06-21",
          "inputTokens": 80, "outputTokens": 40, "cacheCreationTokens": 0,
          "cacheReadTokens": 280, "totalTokens": 400, "costUSD": 8.0,
          "models": {
            "gpt-5.4": { "inputTokens": 80, "outputTokens": 40, "cacheReadTokens": 280, "cost": 8.0 }
          }
        }
      ]
    }
    """

    let rows = try UsageCollector.parseAgent(json, agent: "codex")
    #expect(rows.count == 1)
    #expect(rows[0].period == "2026-06-21")
    #expect(rows[0].agents == ["codex"])
    #expect(rows[0].summary.totalCost == 8.0)       // costUSD honoured
    #expect(rows[0].summary.totalTokens == 400)
    #expect(rows[0].models["gpt-5.4"]?.totalCost == 8.0)
}

@Test func parsesPerAgentReportWithModelBreakdownsArray() throws {
    // Some agents (e.g. claude) emit `modelBreakdowns` + `totalCost` instead of
    // `models` + `costUSD`.
    let json = """
    {
      "daily": [
        {
          "date": "2026-06-21", "inputTokens": 16, "outputTokens": 140, "cacheCreationTokens": 484,
          "cacheReadTokens": 24545, "totalTokens": 25185, "totalCost": 20.7,
          "modelBreakdowns": [
            { "modelName": "claude-opus-4-8", "inputTokens": 16, "outputTokens": 140, "cacheCreationTokens": 484, "cacheReadTokens": 24545, "cost": 20.7 }
          ]
        }
      ]
    }
    """

    let rows = try UsageCollector.parseAgent(json, agent: "claude")
    #expect(rows.count == 1)
    #expect(rows[0].summary.totalCost == 20.7)
    #expect(rows[0].models["claude-opus-4-8"]?.totalCost == 20.7)
    #expect(rows[0].models["claude-opus-4-8"]?.totalTokens == 25185) // 16+140+484+24545
}

@Test func borrowsRealModelCostFromOverviewWhenMissing() {
    // codex per-agent models carry tokens but no cost; the overview (combined)
    // report has the real per-model cost — borrow it.
    let agentRows = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 400, totalCost: 10.0),
            agents: ["codex"],
            models: [
                "gpt-5.5": UsageSummary(totalTokens: 300, totalCost: 0),
                "gpt-5.4-mini": UsageSummary(totalTokens: 100, totalCost: 0)
            ]
        )
    ]
    let combined = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(),
            agents: ["codex"],
            models: [
                "gpt-5.5": UsageSummary(totalTokens: 300, totalCost: 9.0),
                "gpt-5.4-mini": UsageSummary(totalTokens: 100, totalCost: 1.0)
            ]
        )
    ]

    let enriched = UsageCollector.borrowModelCosts(into: agentRows, from: combined)
    #expect(enriched[0].models["gpt-5.5"]?.totalCost == 9.0)       // 9.0 × 300/300
    #expect(enriched[0].models["gpt-5.4-mini"]?.totalCost == 1.0)  // 1.0 × 100/100
}

@Test func borrowedModelCostSplitsByTokenShareForSharedModel() {
    // Same model used by another agent too: combined has the total; the agent
    // gets its token-proportional slice.
    let agentRows = [
        DailyRow(period: "p", summary: UsageSummary(), agents: ["codex"],
                 models: ["m": UsageSummary(totalTokens: 300, totalCost: 0)])
    ]
    let combined = [
        DailyRow(period: "p", summary: UsageSummary(), agents: [],
                 models: ["m": UsageSummary(totalTokens: 400, totalCost: 8.0)])
    ]

    let enriched = UsageCollector.borrowModelCosts(into: agentRows, from: combined)
    #expect(enriched[0].models["m"]?.totalCost == 6.0) // 8.0 × 300/400
}

@Test func borrowModelCostsLeavesExistingCostUntouched() {
    // claude already reports per-model cost — don't overwrite it.
    let agentRows = [
        DailyRow(period: "p", summary: UsageSummary(), agents: ["claude"],
                 models: ["claude-opus": UsageSummary(totalTokens: 100, totalCost: 5.0)])
    ]
    let combined = [
        DailyRow(period: "p", summary: UsageSummary(), agents: [],
                 models: ["claude-opus": UsageSummary(totalTokens: 100, totalCost: 99.0)])
    ]

    let enriched = UsageCollector.borrowModelCosts(into: agentRows, from: combined)
    #expect(enriched[0].models["claude-opus"]?.totalCost == 5.0)
}

@Test func toleratesEmptyModelsArrayInPerAgentReport() throws {
    let json = """
    { "daily": [ { "date": "2026-06-20", "inputTokens": 5, "outputTokens": 5, "totalTokens": 10, "costUSD": 1.0, "models": [] } ] }
    """

    let rows = try UsageCollector.parseAgent(json, agent: "codex")
    #expect(rows.count == 1)
    #expect(rows[0].models.isEmpty)
    #expect(rows[0].summary.totalCost == 1.0)
}

@Test func mergesRowsAcrossEndsByPeriod() {
    let local = [
        DailyRow(period: "2026-06-21", summary: UsageSummary(totalTokens: 100, totalCost: 1.0),
                 agents: ["codex"], models: ["m": UsageSummary(totalTokens: 100, totalCost: 1.0)])
    ]
    let remote = [
        DailyRow(period: "2026-06-21", summary: UsageSummary(totalTokens: 50, totalCost: 0.5),
                 agents: ["claude"], models: ["m": UsageSummary(totalTokens: 50, totalCost: 0.5)]),
        DailyRow(period: "2026-06-20", summary: UsageSummary(totalTokens: 7, totalCost: 0.2),
                 agents: ["claude"], models: [:])
    ]

    let merged = UsageCollector.mergeRows([local, remote])
    #expect(merged.map(\.period) == ["2026-06-20", "2026-06-21"])
    let day = merged.first { $0.period == "2026-06-21" }
    #expect(day?.summary.totalTokens == 150)        // local + remote
    #expect(day?.summary.totalCost == 1.5)
    #expect(Set(day?.agents ?? []) == ["codex", "claude"])
    #expect(day?.models["m"]?.totalTokens == 150)
}

@Test func scopeBucketsDailyWeeklyMonthlyTotal() {
    let calendar = utcCalendar()
    let now = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")! // Sunday
    let rows = [
        DailyRow(period: "2026-06-15", summary: UsageSummary(totalTokens: 35, totalCost: 1.2),
                 agents: ["codex"], models: ["gpt-5.4": UsageSummary(totalTokens: 35, totalCost: 1.2)]),
        DailyRow(period: "2026-06-21", summary: UsageSummary(totalTokens: 20, totalCost: 2.0),
                 agents: ["claude"], models: ["claude-opus": UsageSummary(totalTokens: 20, totalCost: 2.0)]),
        DailyRow(period: "2026-05-31", summary: UsageSummary(totalTokens: 100, totalCost: 9.9),
                 agents: ["codex"], models: [:])
    ]

    let scope = UsageCollector.scope(rows: rows, now: now, calendar: calendar, idPrefix: "")
    #expect(scope.daily.totalTokens == 20)   // today (06-21)
    #expect(scope.weekly.totalTokens == 55)  // 06-15 + 06-21
    #expect(scope.monthly.totalTokens == 55) // June
    #expect(scope.total.totalTokens == 155)  // all rows
    #expect(scope.weekDays.map(\.period) == [
        "2026-06-15", "2026-06-16", "2026-06-17", "2026-06-18", "2026-06-19", "2026-06-20", "2026-06-21"
    ])
    #expect(scope.weekDays.last?.totalCost == 2.0)
    #expect(scope.breakdowns.first?.id == "today-models")
    #expect(scope.breakdowns.first?.items.first?.name == "claude-opus")
    #expect(scope.breakdowns.first?.items.first?.percent == 100.0)
}

@Test func snapshotKeepsAgentsUnderTheirHosts() {
    let calendar = utcCalendar()
    let now = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
    let localCombined = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 100, totalCost: 10),
            agents: ["codex"],
            models: ["same-model": UsageSummary(totalTokens: 100, totalCost: 10)]
        )
    ]
    let remoteCombined = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 100, totalCost: 100),
            agents: ["codex"],
            models: ["same-model": UsageSummary(totalTokens: 100, totalCost: 100)]
        )
    ]
    let localAgent = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 100, totalCost: 10),
            agents: ["codex"],
            models: ["same-model": UsageSummary(totalTokens: 100, totalCost: 0)]
        )
    ]
    let remoteAgent = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 100, totalCost: 100),
            agents: ["codex"],
            models: ["same-model": UsageSummary(totalTokens: 100, totalCost: 0)]
        )
    ]

    let snapshot = UsageCollector.snapshot(
        generatedAt: now,
        calendar: calendar,
        localReachable: true,
        remoteHosts: ["remote"],
        reachableHosts: ["remote"],
        hostRows: [
            UsageCollector.HostRows(id: "host:local", name: "本机", rows: localCombined),
            UsageCollector.HostRows(id: "host:remote", name: "remote", rows: remoteCombined)
        ],
        agentRowsByHostID: [
            "host:local": ["codex": localAgent],
            "host:remote": ["codex": remoteAgent]
        ]
    )

    #expect(snapshot.total.totalTokens == 200)
    #expect(snapshot.hosts.map(\.name) == ["本机", "remote"])
    #expect(snapshot.hosts[0].overview.total.totalCost == 10)
    #expect(snapshot.hosts[1].overview.total.totalCost == 100)
    #expect(snapshot.hosts[0].agents.map(\.name) == ["codex"])
    #expect(snapshot.hosts[1].agents.map(\.name) == ["codex"])
    #expect(snapshot.hosts[0].agents[0].total.totalCost == 10)
    #expect(snapshot.hosts[1].agents[0].total.totalCost == 100)
    #expect(snapshot.hosts[0].agents[0].breakdowns[0].items[0].totalCost == 10)
    #expect(snapshot.hosts[1].agents[0].breakdowns[0].items[0].totalCost == 100)
    #expect(snapshot.agents.first?.name == "codex")
    #expect(snapshot.agents.first?.total.totalCost == 110)
}

@Test func snapshotCanUseReachableRemoteWhenLocalFails() {
    let calendar = utcCalendar()
    let now = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
    let remoteCombined = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 120, totalCost: 12),
            agents: ["codex"],
            models: ["remote-model": UsageSummary(totalTokens: 120, totalCost: 12)]
        )
    ]
    let remoteAgent = [
        DailyRow(
            period: "2026-06-21",
            summary: UsageSummary(totalTokens: 120, totalCost: 12),
            agents: ["codex"],
            models: ["remote-model": UsageSummary(totalTokens: 120, totalCost: 0)]
        )
    ]

    let snapshot = UsageCollector.snapshot(
        generatedAt: now,
        calendar: calendar,
        localReachable: false,
        remoteHosts: ["remote-a", "remote-b"],
        reachableHosts: ["remote-a"],
        hostRows: [
            UsageCollector.HostRows(id: "host:remote-a", name: "remote-a", rows: remoteCombined)
        ],
        agentRowsByHostID: [
            "host:remote-a": ["codex": remoteAgent]
        ]
    )

    #expect(snapshot.sources?.localReachable == false)
    #expect(snapshot.sources?.statusLabel == "多端(1/2)")
    #expect(snapshot.sources?.hasMissingSources == true)
    #expect(snapshot.hosts.map(\.name) == ["remote-a"])
    #expect(snapshot.total.totalCost == 12)
    #expect(snapshot.hosts[0].agents[0].breakdowns[0].items[0].totalCost == 12)
}

@Test func remoteStatusReflectsConfigAndReachability() {
    #expect(UsageSources().remoteStatus == .localOnly)
    #expect(UsageSources(remoteHosts: ["h"], reachableHosts: ["h"]).remoteStatus == .joint)
    #expect(UsageSources(remoteHosts: ["h"], reachableHosts: []).remoteStatus == .degraded)
    #expect(UsageSources(remoteHosts: ["h1", "h2"], reachableHosts: ["h1"]).remoteStatus == .partial)
    #expect(UsageSources(remoteHosts: ["h1", "h2"], reachableHosts: ["h1", "h2"]).remoteStatus == .joint)
}

@Test func sourceStatusLabelsDescribeLocalAndRemoteSources() {
    #expect(UsageSources().statusLabel == "本地")
    #expect(UsageSources(remoteHosts: ["h1", "h2"], reachableHosts: ["h1", "h2"]).statusLabel == "本地+多端(2/2)")
    #expect(UsageSources(remoteHosts: ["h1", "h2"], reachableHosts: ["h1"]).statusLabel == "本地+多端(1/2)")
    #expect(UsageSources(localReachable: false, remoteHosts: ["h1", "h2"], reachableHosts: ["h1"]).statusLabel == "多端(1/2)")
    #expect(UsageSources(localReachable: false).statusLabel == "无来源")
    #expect(UsageSources(remoteHosts: ["h1"], reachableHosts: ["h1"]).hasMissingSources == false)
    #expect(UsageSources(remoteHosts: ["h1"], reachableHosts: []).hasMissingSources == true)
    #expect(UsageSources(localReachable: false, remoteHosts: ["h1"], reachableHosts: ["h1"]).hasMissingSources == true)
}

@Test func migratesLegacySingleHostSnapshot() throws {
    // Older snapshots used remoteHost/remoteReachable — must migrate to lists.
    let json = """
    { "generatedAt": "2026-06-21T07:26:37Z", "sources": { "remoteHost": "h", "remoteReachable": true, "agents": ["codex"] } }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.sources?.remoteHosts == ["h"])
    #expect(snapshot.sources?.reachableHosts == ["h"])
    #expect(snapshot.sources?.remoteStatus == .joint)
}

@Test func decodesLocalOnlySnapshot() throws {
    let json = """
    { "generatedAt": "2026-06-21T07:26:37Z", "sources": { "agents": ["codex"] } }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.sources?.remoteHosts.isEmpty == true)
    #expect(snapshot.sources?.remoteStatus == .localOnly)
}

private func dayStart(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

@Test func pricingModeOnlineAndOfflineIgnoreMarker() {
    let cal = utcCalendar()
    let now = dayStart(2026, 6, 15, calendar: cal)
    #expect(UsageCollector.shouldRunOffline(mode: .offline, lastOnlineDay: nil, now: now, calendar: cal) == true)
    #expect(UsageCollector.shouldRunOffline(mode: .offline, lastOnlineDay: "2026-06-15", now: now, calendar: cal) == true)
    #expect(UsageCollector.shouldRunOffline(mode: .online, lastOnlineDay: nil, now: now, calendar: cal) == false)
    #expect(UsageCollector.shouldRunOffline(mode: .online, lastOnlineDay: "2026-06-15", now: now, calendar: cal) == false)
}

@Test func autoPricingRunsOnlineUntilRefreshedToday() {
    let cal = utcCalendar()
    let now = dayStart(2026, 6, 15, calendar: cal)
    // No marker yet → go online to populate pricing.
    #expect(UsageCollector.shouldRunOffline(mode: .auto, lastOnlineDay: nil, now: now, calendar: cal) == false)
    #expect(UsageCollector.shouldRunOffline(mode: .auto, lastOnlineDay: "", now: now, calendar: cal) == false)
    // Already refreshed today → stay offline (fast path).
    #expect(UsageCollector.shouldRunOffline(mode: .auto, lastOnlineDay: "2026-06-15", now: now, calendar: cal) == true)
    // Marker is from an earlier day → online again to refresh pricing.
    #expect(UsageCollector.shouldRunOffline(mode: .auto, lastOnlineDay: "2026-06-14", now: now, calendar: cal) == false)
}
