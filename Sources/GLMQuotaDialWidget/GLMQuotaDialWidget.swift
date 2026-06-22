import GLMQuotaCore
import SwiftUI
import WidgetKit

public struct GLMQuotaEntry: TimelineEntry {
    public let date: Date
    public let snapshot: GLMQuotaSnapshot?

    public init(date: Date, snapshot: GLMQuotaSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct GLMQuotaProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> GLMQuotaEntry {
        GLMQuotaEntry(date: Date(), snapshot: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (GLMQuotaEntry) -> Void) {
        completion(GLMQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview)))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<GLMQuotaEntry>) -> Void) {
        let entry = GLMQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview))
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func snapshot(forPreview isPreview: Bool) -> GLMQuotaSnapshot? {
        try? GLMQuotaSnapshotStore().load()
    }
}

public struct GLMQuotaWidgetEntryView: View {
    public var entry: GLMQuotaEntry

    public init(entry: GLMQuotaEntry) {
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

public struct GLMQuotaDialWidget: Widget {
    public let kind = "GLMQuotaDialWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GLMQuotaProvider()) { entry in
            GLMQuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("GLM 额度表盘")
        .description("显示 GLM 次数和 Token 额度剩余与重置时间。")
        .supportedFamilies([.systemMedium])
    }
}

private struct QuotaDialDashboard: View {
    var snapshot: GLMQuotaSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(snapshot: snapshot)

            HStack(alignment: .top, spacing: 12) {
                if let window = snapshot.timeLimit {
                    QuotaDialTile(title: "工具类额度", window: window, tint: .cyan)
                }
                if let window = snapshot.tokensLimit5 {
                    QuotaDialTile(title: "5h", window: window, tint: .indigo)
                }
                if let window = snapshot.tokensLimitMonth {
                    QuotaDialTile(title: "本周", window: window, tint: .purple)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct HeaderView: View {
    var snapshot: GLMQuotaSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("GLM 额度")
                .font(.headline)
                .lineLimit(1)

            if let level = snapshot.level {
                Text(level.uppercased())
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

private struct QuotaDialTile: View {
    var title: String
    var window: GLMQuotaWindow
    var tint: Color

    private var percent: Int {
        window.remainingPercent
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            DialMeter(percent: percent, tint: tint)
                .frame(width: 80, height: 80)

            if let usage = window.usage, let remaining = window.remaining {
                Text("\(remaining)/\(usage)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(resetText(window.resetsAt))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DialMeter: View {
    var percent: Int
    var tint: Color

    var body: some View {
        ZStack {
            QuotaArc(progress: 1)
                .stroke(Color.secondary.opacity(0.16), style: StrokeStyle(lineWidth: 9, lineCap: .round))

            QuotaArc(progress: Double(percent) / 100.0)
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
                Text("\(percent)%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
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
            Text("GLM 额度")
                .font(.headline)
            Text("暂无额度快照")
                .font(.title3.weight(.semibold))
            Text("运行 GLMQuotaSnapshotTool 后刷新组件")
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

private func quotaColor(_ percent: Int) -> Color {
    if percent >= 60 { return .green }
    if percent >= 25 { return .orange }
    return .red
}
