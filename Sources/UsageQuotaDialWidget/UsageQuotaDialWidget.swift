import SwiftUI
import UsageQuotaCore
import WidgetKit

public struct UsageQuotaEntry: TimelineEntry {
    public let date: Date
    public let snapshot: UsageSnapshot?

    public init(date: Date, snapshot: UsageSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct UsageQuotaProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> UsageQuotaEntry {
        UsageQuotaEntry(date: Date(), snapshot: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (UsageQuotaEntry) -> Void) {
        completion(UsageQuotaEntry(date: Date(), snapshot: try? UsageSnapshotStore().load()))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<UsageQuotaEntry>) -> Void) {
        let entry = UsageQuotaEntry(date: Date(), snapshot: try? UsageSnapshotStore().load())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

public struct UsageQuotaWidgetEntryView: View {
    public var entry: UsageQuotaEntry
    @Environment(\.widgetFamily) private var family

    public init(entry: UsageQuotaEntry) {
        self.entry = entry
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            UsageWidgetDashboard(snapshot: snapshot, family: family)
        } else {
            EmptyUsageView()
        }
    }
}

public struct UsageQuotaDialWidget: Widget {
    public let kind = "UsageQuotaDialWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageQuotaProvider()) { entry in
            UsageQuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("消耗统计")
        .description("显示今日、本周和模型调用消耗。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct UsageWidgetDashboard: View {
    var snapshot: UsageSnapshot
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium:
            MediumUsageDashboard(snapshot: snapshot)
        default:
            LargeUsageDashboard(snapshot: snapshot)
        }
    }
}

private struct MediumUsageDashboard: View {
    var snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(snapshot: snapshot)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日消耗")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(costText(snapshot.daily.totalCost))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(compactNumber(snapshot.daily.totalTokens)) tokens")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("本周")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(costText(snapshot.weekly.totalCost))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(compactNumber(snapshot.weekly.totalTokens))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            WidgetWeekTrend(days: snapshot.weekDays, height: 34)

            HStack(alignment: .top, spacing: 12) {
                TopAgentsView(agents: snapshot.agents, limit: 1)
                TopModelsView(items: snapshot.breakdowns.first(where: { $0.id == "today-models" })?.items ?? [], limit: 1)
            }
        }
        .padding(.top, 2)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct LargeUsageDashboard: View {
    var snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            WidgetHeader(snapshot: snapshot)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日消耗")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(costText(snapshot.daily.totalCost))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let delta = widgetTodayDeltaPercent(snapshot.weekDays) {
                            WidgetDelta(percent: delta)
                        }
                    }
                    Text("\(compactNumber(snapshot.daily.totalTokens)) tokens")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    DailyTokenValues(summary: snapshot.daily)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        CompactUsageTile(title: "本周", summary: snapshot.weekly)
                        CompactUsageTile(title: "本月", summary: snapshot.monthly)
                    }
                    CompactUsageTile(title: "总计", summary: snapshot.total)
                }
                .frame(width: 166)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("本周趋势")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                WidgetWeekTrend(days: snapshot.weekDays, height: 48, showsLabels: true)
            }

            HStack(alignment: .top, spacing: 14) {
                TopAgentsView(agents: snapshot.agents, limit: 2)
                TopModelsView(items: snapshot.breakdowns.first(where: { $0.id == "today-models" })?.items ?? [], limit: 2)
            }
        }
        .padding(.top, 2)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct DailyTokenValues: View {
    var summary: UsageSummary

    var body: some View {
        HStack(spacing: 10) {
            TokenMetric(title: "输入", value: summary.inputTokens)
            TokenMetric(title: "输出", value: summary.outputTokens)
            TokenMetric(title: "缓存读", value: summary.cacheReadTokens)
        }
    }
}

private struct TokenMetric: View {
    var title: String
    var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(compactNumber(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WidgetWeekTrend: View {
    var days: [UsageDay]
    var height: CGFloat = 44
    var showsLabels: Bool = false

    private var maxCost: Double { max(days.map(\.totalCost).max() ?? 0, 0.01) }
    private var todayPeriod: String { widgetDayFormatter.string(from: Date()) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(day))
                                .frame(height: max(3, geo.size.height * day.totalCost / maxCost))
                                .overlay {
                                    if day.period == todayPeriod {
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                                    }
                                }
                        }
                    }
                    .frame(height: height)

                    if showsLabels {
                        Text(widgetWeekdayShort(day.period))
                            .font(.system(size: 8, weight: day.period == todayPeriod ? .semibold : .regular))
                            .foregroundStyle(.secondary)
                        Text(costText(day.totalCost))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barColor(_ day: UsageDay) -> Color {
        let intensity = maxCost > 0 ? day.totalCost / maxCost : 0
        return Color.blue.opacity(0.35 + 0.6 * intensity)
    }
}

private struct WidgetDelta: View {
    var percent: Double

    var body: some View {
        let up = percent >= 0
        return Text("\(up ? "↑" : "↓")\(String(format: "%.0f", abs(percent)))%")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(up ? Color.orange : Color.green)
            .lineLimit(1)
    }
}

private struct WidgetHeader: View {
    var snapshot: UsageSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("消耗统计")
                .font(.subheadline.weight(.semibold))
            if let badge = RemoteStatusBadge(sources: snapshot.sources) {
                badge.font(.system(size: 9, weight: .bold))
            }
            Spacer()
            Text("更新 \(widgetTimeFormatter.string(from: snapshot.generatedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background((warning ? Color.orange : Color.blue).opacity(0.15), in: Capsule())
            .foregroundStyle(warning ? Color.orange : Color.blue)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct CompactUsageTile: View {
    var title: String
    var summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(costText(summary.totalCost))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(compactNumber(summary.totalTokens))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TopAgentsView: View {
    var agents: [UsageAgentSnapshot]
    var limit = 3

    private var visibleAgents: [UsageAgentSnapshot] {
        agents
            .filter { $0.weekly.totalCost > 0 || $0.daily.totalCost > 0 }
            .sorted { $0.weekly.totalCost > $1.weekly.totalCost }
            .prefix(limit)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本周 Agent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(visibleAgents) { agent in
                HStack {
                    Text(agent.name.capitalized)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(costText(agent.weekly.totalCost))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TopModelsView: View {
    var items: [UsageBreakdownItem]
    var limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今日模型")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items.prefix(limit)) { item in
                HStack {
                    Text(item.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(costText(item.totalCost))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyUsageView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("消耗统计")
                .font(.headline)
            Text("暂无消耗快照")
                .font(.title3.weight(.semibold))
            Text("在 app 中刷新一次后显示")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private func widgetTodayDeltaPercent(_ days: [UsageDay]) -> Double? {
    let today = widgetDayFormatter.string(from: Date())
    guard
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
        let todayCost = days.first(where: { $0.period == today })?.totalCost
    else { return nil }
    let yesterday = widgetDayFormatter.string(from: yesterdayDate)
    guard let yesterdayCost = days.first(where: { $0.period == yesterday })?.totalCost, yesterdayCost > 0 else {
        return nil
    }
    return (todayCost - yesterdayCost) / yesterdayCost * 100
}

private func costText(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func compactNumber(_ value: Int) -> String {
    let number = Double(value)
    if number >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if number >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return "\(value)"
}

private func widgetWeekdayShort(_ period: String) -> String {
    guard let date = widgetDayFormatter.date(from: period) else { return "" }
    let index = Calendar.current.component(.weekday, from: date)
    let labels = ["日", "一", "二", "三", "四", "五", "六"]
    return labels[max(0, min(6, index - 1))]
}

private let widgetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private let widgetDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
