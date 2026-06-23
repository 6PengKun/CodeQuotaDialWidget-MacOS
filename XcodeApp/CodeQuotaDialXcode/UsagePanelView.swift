import Combine
import SwiftUI
import UsageQuotaCore
import WidgetKit

struct UsagePanelView: View {
    @State private var snapshot: UsageSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @State private var selectedScopeID = UsageScopeData.overviewID
    @StateObject private var agent = LaunchAgentController(
        label: LaunchAgentLabels.usage.label,
        plistPath: LaunchAgentLabels.usage.plist
    )

    private let refreshTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let badge = RemoteStatusBadge(sources: snapshot?.sources) {
                    badge.font(.caption2.weight(.bold))
                }

                LaunchAgentToggleRow(controller: agent)

                if scopes.count > 1 {
                    Picker("范围", selection: $selectedScopeID) {
                        ForEach(scopes) { scope in
                            Text(scope.title)
                                .tag(scope.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                }

                HeroTodayCard(
                    summary: selectedScope?.daily,
                    deltaPercent: usageTodayDeltaPercent(selectedScope?.weekDays ?? [])
                )

                PeriodTiles(
                    weekly: selectedScope?.weekly,
                    monthly: selectedScope?.monthly,
                    total: selectedScope?.total
                )

                WeekTrendChart(days: selectedScope?.weekDays ?? [])

                ModelBreakdownCard(breakdowns: selectedScope?.breakdowns ?? [])

                if let message = errorText ?? agent.lastError {
                    InlineBanner(text: message)
                }
            }
            .padding(Theme.contentPadding)
        }
        .navigationTitle("消耗统计")
        .navigationSubtitle(snapshot.map { "更新于 \(quotaPanelTimeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(isRefreshing: isRefreshing) { await refresh() }
            }
        }
        .onAppear {
            loadSnapshot()
            agent.refreshStatus()
            if snapshot == nil {
                Task { await refresh() }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await refresh() }
        }
    }

    private var scopes: [UsageScopeData] {
        guard let snapshot else { return [] }
        let hostScopes = snapshot.hosts.flatMap { host in
            [UsageScopeData(host: host, overview: host.overview)]
                + host.agents.map { UsageScopeData(host: host, agent: $0) }
        }
        if !hostScopes.isEmpty {
            return [UsageScopeData(snapshot: snapshot)] + hostScopes
        }
        return [UsageScopeData(snapshot: snapshot)]
            + snapshot.ends.map(UsageScopeData.init(end:))
            + snapshot.agents.map(UsageScopeData.init(agent:))
    }

    private var selectedScope: UsageScopeData? {
        let scopes = scopes
        if let scope = scopes.first(where: { $0.id == selectedScopeID }) {
            return scope
        }
        return scopes.first
    }

    private func loadSnapshot() {
        do {
            snapshot = try UsageSnapshotStore().load()
            errorText = snapshot?.error
            normalizeSelectedScope()
        } catch {
            errorText = "暂无消耗快照。"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            UsageCollector().collect()
        }.value

        do {
            try UsageSnapshotStore().save(newSnapshot)
            WidgetCenter.shared.reloadAllTimelines()
            snapshot = newSnapshot
            errorText = newSnapshot.error
            normalizeSelectedScope()
        } catch {
            errorText = "保存消耗快照失败：\(error.localizedDescription)"
        }
    }

    private func normalizeSelectedScope() {
        let ids = Set(scopes.map(\.id))
        if !ids.contains(selectedScopeID) {
            selectedScopeID = UsageScopeData.overviewID
        }
    }
}

private struct UsageScopeData: Identifiable {
    static let overviewID = "overview"

    var id: String
    var title: String
    var daily: UsageSummary
    var weekly: UsageSummary
    var monthly: UsageSummary
    var total: UsageSummary
    var weekDays: [UsageDay]
    var breakdowns: [UsageBreakdownSection]

    init(snapshot: UsageSnapshot) {
        id = Self.overviewID
        title = "总览"
        daily = snapshot.daily
        weekly = snapshot.weekly
        monthly = snapshot.monthly
        total = snapshot.total
        weekDays = snapshot.weekDays
        breakdowns = snapshot.breakdowns
    }

    init(agent: UsageAgentSnapshot) {
        id = agent.id
        title = agent.name.capitalized
        daily = agent.daily
        weekly = agent.weekly
        monthly = agent.monthly
        total = agent.total
        weekDays = agent.weekDays
        breakdowns = agent.breakdowns
    }

    init(host: UsageHostSnapshot, overview: UsageAgentSnapshot) {
        id = overview.id
        title = "\(host.name) · 总览"
        daily = overview.daily
        weekly = overview.weekly
        monthly = overview.monthly
        total = overview.total
        weekDays = overview.weekDays
        breakdowns = overview.breakdowns
    }

    init(host: UsageHostSnapshot, agent: UsageAgentSnapshot) {
        id = agent.id
        title = "\(host.name) · \(agent.name.capitalized)"
        daily = agent.daily
        weekly = agent.weekly
        monthly = agent.monthly
        total = agent.total
        weekDays = agent.weekDays
        breakdowns = agent.breakdowns
    }

    init(end: UsageAgentSnapshot) {
        id = end.id
        title = end.name  // already display-ready (本机 / host)
        daily = end.daily
        weekly = end.weekly
        monthly = end.monthly
        total = end.total
        weekDays = end.weekDays
        breakdowns = end.breakdowns
    }
}

private struct RemoteStatusBadge: View {
    private let label: String
    private let warning: Bool

    init?(sources: UsageSources?) {
        guard let sources, let label = sources.statusLabel else { return nil }
        self.label = label
        warning = sources.hasMissingSources
    }

    var body: some View {
        Text(label)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((warning ? Color.orange : Color.blue).opacity(0.15), in: Capsule())
            .foregroundStyle(warning ? Color.orange : Color.blue)
            .lineLimit(1)
    }
}

private struct HeroTodayCard: View {
    var summary: UsageSummary?
    var deltaPercent: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(costText(summary?.totalCost))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Spacer()
                    if let deltaPercent {
                        DeltaBadge(percent: deltaPercent)
                    }
                }
                Text("\(compactNumber(summary?.totalTokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            TokenValueRow(summary: summary)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

private struct DeltaBadge: View {
    var percent: Double

    var body: some View {
        let up = percent >= 0
        return Text("\(up ? "↑" : "↓") \(String(format: "%.0f", abs(percent)))% · 昨日")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(up ? Color.orange : Color.green)
            .lineLimit(1)
    }
}

private struct TokenValueRow: View {
    var summary: UsageSummary?

    var body: some View {
        HStack(spacing: Theme.cardSpacing) {
            TokenValue(label: "输入", value: summary?.inputTokens)
            TokenValue(label: "输出", value: summary?.outputTokens)
            TokenValue(label: "缓存读", value: summary?.cacheReadTokens)
        }
    }
}

private struct TokenValue: View {
    var label: String
    var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(compactNumber(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PeriodTiles: View {
    var weekly: UsageSummary?
    var monthly: UsageSummary?
    var total: UsageSummary?

    var body: some View {
        HStack(spacing: Theme.cardSpacing) {
            PeriodTile(title: "本周", summary: weekly)
            PeriodTile(title: "本月", summary: monthly)
            PeriodTile(title: "总计", summary: total)
        }
    }
}

private struct PeriodTile: View {
    var title: String
    var summary: UsageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(costText(summary?.totalCost))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(compactNumber(summary?.totalTokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

private struct WeekTrendChart: View {
    var days: [UsageDay]

    private var maxCost: Double { max(days.map(\.totalCost).max() ?? 0, 0.01) }
    /// Average over elapsed days only (through today). Future days in the current
    /// week are still zero, so including them would understate the daily average.
    private var average: Double {
        let elapsed = days.filter { $0.period <= todayPeriod }
        return elapsed.isEmpty ? 0 : elapsed.map(\.totalCost).reduce(0, +) / Double(elapsed.count)
    }
    private var todayPeriod: String { usageDayFormatter.string(from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本周趋势")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("均值 \(costText(average))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 5) {
                ZStack(alignment: .bottom) {
                    GeometryReader { geo in
                        let y = geo.size.height * (1 - CGFloat(average / maxCost))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(days) { day in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(day))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(4, 88 * day.totalCost / maxCost))
                                .overlay {
                                    if day.period == todayPeriod {
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                    }
                                }
                        }
                    }
                }
                .frame(height: 88)

                HStack(spacing: 8) {
                    ForEach(days) { day in
                        VStack(spacing: 1) {
                            Text(weekdayShort(day.period))
                                .font(.system(size: 10, weight: day.period == todayPeriod ? .semibold : .regular))
                                .foregroundStyle(day.period == todayPeriod ? Color.primary : Color.secondary)
                            Text(costText(day.totalCost))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func barColor(_ day: UsageDay) -> Color {
        let intensity = maxCost > 0 ? day.totalCost / maxCost : 0
        return Color.blue.opacity(0.35 + 0.6 * intensity)
    }
}

private struct ModelBreakdownCard: View {
    var breakdowns: [UsageBreakdownSection]
    @State private var period: ModelPeriod = .today

    enum ModelPeriod: String, CaseIterable, Identifiable {
        case today = "今日"
        case week = "本周"
        case month = "本月"
        case total = "总计"

        var id: String { rawValue }

        var suffix: String {
            switch self {
            case .today: return "today-models"
            case .week: return "week-models"
            case .month: return "month-models"
            case .total: return "total-models"
            }
        }
    }

    private var section: UsageBreakdownSection? {
        breakdowns.first { $0.id.hasSuffix(period.suffix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型分布")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $period) {
                    ForEach(ModelPeriod.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let items = section?.items, !items.isEmpty {
                ForEach(items.prefix(6)) { item in
                    ModelRow(item: item)
                }
            } else {
                Text("暂无模型数据")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

private struct ModelRow: View {
    var item: UsageBreakdownItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(costText(item.totalCost)) · \(String(format: "%.1f", item.percent))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: geo.size.width * min(1, max(0, item.percent / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

private func usageTodayDeltaPercent(_ days: [UsageDay]) -> Double? {
    let today = usageDayFormatter.string(from: Date())
    guard
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
        let todayCost = days.first(where: { $0.period == today })?.totalCost
    else { return nil }
    let yesterday = usageDayFormatter.string(from: yesterdayDate)
    guard let yesterdayCost = days.first(where: { $0.period == yesterday })?.totalCost, yesterdayCost > 0 else {
        return nil
    }
    return (todayCost - yesterdayCost) / yesterdayCost * 100
}

private func costText(_ value: Double?) -> String {
    guard let value else { return "$--" }
    return String(format: "$%.2f", value)
}

private func compactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    let number = Double(value)
    if number >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if number >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return "\(value)"
}

private func weekdayShort(_ period: String) -> String {
    guard let date = usageDayFormatter.date(from: period) else { return "" }
    let index = Calendar.current.component(.weekday, from: date)
    let labels = ["日", "一", "二", "三", "四", "五", "六"]
    return labels[max(0, min(6, index - 1))]
}

private let usageDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
