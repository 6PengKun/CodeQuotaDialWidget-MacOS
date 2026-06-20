import CodexQuotaCore
import SwiftUI
import WidgetKit

public struct CodexQuotaEntry: TimelineEntry {
    public let date: Date
    public let snapshot: CodexQuotaSnapshot?

    public init(date: Date, snapshot: CodexQuotaSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct CodexQuotaProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> CodexQuotaEntry {
        CodexQuotaEntry(date: Date(), snapshot: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (CodexQuotaEntry) -> Void) {
        completion(CodexQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview)))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CodexQuotaEntry>) -> Void) {
        let entry = CodexQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview))
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func snapshot(forPreview isPreview: Bool) -> CodexQuotaSnapshot? {
        try? CodexQuotaSnapshotStore().load()
    }
}

public struct CodexQuotaWidgetEntryView: View {
    public var entry: CodexQuotaEntry

    public init(entry: CodexQuotaEntry) {
        self.entry = entry
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            QuotaDialDashboard(snapshot: snapshot)
        } else {
            EmptyQuotaView()
        }
    }
}

public struct CodexQuotaDialWidget: Widget {
    public let kind = "CodexQuotaDialWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexQuotaProvider()) { entry in
            CodexQuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Codex 额度表盘")
        .description("显示 Codex 5h 和本周剩余额度与重置时间。")
        .supportedFamilies([.systemMedium])
    }
}

private struct QuotaDialDashboard: View {
    var snapshot: CodexQuotaSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(snapshot: snapshot)

            if let monthly = snapshot.monthly, snapshot.fiveHour == nil {
                // 免费版：单个 30 天额度表盘。
                QuotaDialTile(title: "30 天", window: monthly, tint: .indigo)
                    .frame(maxWidth: .infinity)
            } else if snapshot.fiveHour != nil || snapshot.weekly != nil {
                HStack(alignment: .top, spacing: 18) {
                    if let window = snapshot.fiveHour {
                        QuotaDialTile(title: "5h", window: window, tint: .cyan)
                    }
                    if let window = snapshot.weekly {
                        QuotaDialTile(title: "本周", window: window, tint: .indigo)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct HeaderView: View {
    var snapshot: CodexQuotaSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Codex 额度")
                .font(.headline)
                .lineLimit(1)

            if let plan = snapshot.planType {
                Text(plan.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(snapshot.isFreePlan ? Color.secondary : .blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((snapshot.isFreePlan ? Color.secondary : Color.blue).opacity(0.14))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(updatedText(snapshot.generatedAt))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(snapshot.error == nil ? "在线" : "异常")
                .font(.caption2.weight(.bold))
                .foregroundStyle(snapshot.error == nil ? .green : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((snapshot.error == nil ? Color.green : Color.orange).opacity(0.14))
                .clipShape(Capsule())
                .lineLimit(1)
        }
    }
}

private struct QuotaDialTile: View {
    var title: String
    var window: CodexQuotaWindow
    var tint: Color

    private var percent: Int? {
        window.remainingPercent
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            DialMeter(percent: percent, tint: tint)
                .frame(width: 88, height: 88)

            Text(resetText(window.resetsAt))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DialMeter: View {
    var percent: Int?
    var tint: Color

    var body: some View {
        ZStack {
            QuotaArc(progress: 1)
                .stroke(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 9, lineCap: .round))

            QuotaArc(progress: progressValue(percent))
                .stroke(
                    AngularGradient(
                        colors: [quotaColor(percent), tint, quotaColor(percent)],
                        center: .center,
                        startAngle: .degrees(135),
                        endAngle: .degrees(405)
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )

            VStack(spacing: 1) {
                Text(percentText(percent))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text("剩余")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyQuotaView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex 额度")
                .font(.headline)
            Text("暂无额度快照")
                .font(.title3.weight(.semibold))
            Text("运行 CodexQuotaSnapshotTool 后刷新组件")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct QuotaArc: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        let progress = max(0, min(1, progress))
        let side = min(rect.width, rect.height)
        let radius = side / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + 270 * progress)

        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private let updateDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
}()

private let resetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
}()

private func progressValue(_ percent: Int?) -> Double {
    Double(percent ?? 0) / 100
}

private func percentText(_ percent: Int?) -> String {
    percent.map { "\($0)%" } ?? "--"
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "重置 --" }
    return "重置 \(resetFormatter.string(from: date))"
}

private func updatedText(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return "更新 \(timeFormatter.string(from: date))"
    }
    return "更新 \(updateDateTimeFormatter.string(from: date))"
}

private func quotaColor(_ percent: Int?) -> Color {
    guard let percent else { return .secondary }
    if percent >= 60 { return .green }
    if percent >= 25 { return .orange }
    return .red
}
