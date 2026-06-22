import AntigravityQuotaCore
import SwiftUI
import WidgetKit

public struct AntigravityQuotaEntry: TimelineEntry {
    public let date: Date
    public let snapshot: AntigravityQuotaSnapshot?

    public init(date: Date, snapshot: AntigravityQuotaSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct AntigravityQuotaProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> AntigravityQuotaEntry {
        AntigravityQuotaEntry(date: Date(), snapshot: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (AntigravityQuotaEntry) -> Void) {
        completion(AntigravityQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview)))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<AntigravityQuotaEntry>) -> Void) {
        let entry = AntigravityQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview))
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func snapshot(forPreview isPreview: Bool) -> AntigravityQuotaSnapshot? {
        try? AntigravityQuotaSnapshotStore().load()
    }
}

public struct AntigravityQuotaWidgetEntryView: View {
    public var entry: AntigravityQuotaEntry

    public init(entry: AntigravityQuotaEntry) {
        self.entry = entry
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            QuotaDashboard(snapshot: snapshot)
        } else {
            EmptyQuotaView()
        }
    }
}

public struct AntigravityQuotaDialWidget: Widget {
    public let kind = "AntigravityQuotaDialWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AntigravityQuotaProvider()) { entry in
            AntigravityQuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Antigravity 5小时限额")
        .description("显示 Antigravity 中 Claude、Gemini 共享限额。")
        .supportedFamilies([.systemMedium])
    }
}

private struct QuotaDashboard: View {
    var snapshot: AntigravityQuotaSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(snapshot: snapshot)

            HStack(alignment: .top, spacing: 18) {
                ForEach(AntigravityQuotaBucket.allCases, id: \.self) { bucket in
                    ModelTile(bucket: bucket, model: snapshot.model(for: bucket))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct HeaderView: View {
    var snapshot: AntigravityQuotaSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Antigravity 5小时限额")
                .font(.headline)
                .lineLimit(1)

            if let planType = snapshot.planType {
                Text(planType.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.14))
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

private struct ModelTile: View {
    var bucket: AntigravityQuotaBucket
    var model: AntigravityModelQuota?

    var body: some View {
        VStack(spacing: 7) {
            Text(bucket.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            DialMeter(percent: model?.remainingPercent, tint: bucket.tint)
                .frame(width: 88, height: 88)

            Text(resetText(model?.resetsAt))
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
            Text("Antigravity 5小时限额")
                .font(.headline)
            Text("暂无额度快照")
                .font(.title3.weight(.semibold))
            Text("运行 AntigravityQuotaSnapshotTool 后刷新组件")
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

private extension AntigravityQuotaBucket {
    var tint: Color {
        switch self {
        case .claude: return .cyan
        case .gemini: return .indigo
        }
    }
}
