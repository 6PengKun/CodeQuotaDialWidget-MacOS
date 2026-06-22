import SwiftUI
import WidgetKit

public struct QuotaDialItem: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var remainingPercent: Int?
    public var resetsAt: Date?
    public var tint: Color
    public var detailText: String?

    public init(
        id: String,
        title: String,
        remainingPercent: Int?,
        resetsAt: Date?,
        tint: Color,
        detailText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.tint = tint
        self.detailText = detailText
    }
}

public struct QuotaDialBadge: Sendable {
    public var text: String
    public var tint: Color

    public init(text: String, tint: Color = .blue) {
        self.text = text
        self.tint = tint
    }
}

public struct QuotaDialTileStyle: Sendable {
    public var spacing: CGFloat
    public var meterSize: CGFloat
    public var percentFontSize: CGFloat
    public var resetFontSize: CGFloat
    public var detailFontSize: CGFloat

    public init(
        spacing: CGFloat,
        meterSize: CGFloat,
        percentFontSize: CGFloat,
        resetFontSize: CGFloat,
        detailFontSize: CGFloat = 11
    ) {
        self.spacing = spacing
        self.meterSize = meterSize
        self.percentFontSize = percentFontSize
        self.resetFontSize = resetFontSize
        self.detailFontSize = detailFontSize
    }

    public static let standard = QuotaDialTileStyle(
        spacing: 7,
        meterSize: 88,
        percentFontSize: 24,
        resetFontSize: 14
    )

    public static let compact = QuotaDialTileStyle(
        spacing: 5,
        meterSize: 80,
        percentFontSize: 22,
        resetFontSize: 12
    )
}

public struct QuotaDialDashboard: View {
    private var title: String
    private var badge: QuotaDialBadge?
    private var generatedAt: Date
    private var hasError: Bool
    private var items: [QuotaDialItem]
    private var horizontalSpacing: CGFloat
    private var tileStyle: QuotaDialTileStyle

    public init(
        title: String,
        badge: QuotaDialBadge?,
        generatedAt: Date,
        hasError: Bool,
        items: [QuotaDialItem],
        horizontalSpacing: CGFloat = 18,
        tileStyle: QuotaDialTileStyle = .standard
    ) {
        self.title = title
        self.badge = badge
        self.generatedAt = generatedAt
        self.hasError = hasError
        self.items = items
        self.horizontalSpacing = horizontalSpacing
        self.tileStyle = tileStyle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuotaDialHeader(
                title: title,
                badge: badge,
                generatedAt: generatedAt,
                hasError: hasError
            )

            if items.count == 1, let item = items.first {
                QuotaDialTile(item: item, style: tileStyle)
                    .frame(maxWidth: .infinity)
            } else if !items.isEmpty {
                HStack(alignment: .top, spacing: horizontalSpacing) {
                    ForEach(items) { item in
                        QuotaDialTile(item: item, style: tileStyle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

public struct EmptyQuotaView: View {
    private var title: String
    private var message: String
    private var footnote: String

    public init(title: String, message: String = "暂无额度快照", footnote: String) {
        self.title = title
        self.message = message
        self.footnote = footnote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.title3.weight(.semibold))
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct QuotaDialHeader: View {
    var title: String
    var badge: QuotaDialBadge?
    var generatedAt: Date
    var hasError: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            if let badge {
                Text(badge.text.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badge.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(badge.tint.opacity(0.14))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(updatedText(generatedAt))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(hasError ? "异常" : "在线")
                .font(.caption2.weight(.bold))
                .foregroundStyle(hasError ? .orange : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((hasError ? Color.orange : Color.green).opacity(0.14))
                .clipShape(Capsule())
                .lineLimit(1)
        }
    }
}

private struct QuotaDialTile: View {
    var item: QuotaDialItem
    var style: QuotaDialTileStyle

    var body: some View {
        VStack(spacing: style.spacing) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            DialMeter(percent: item.remainingPercent, tint: item.tint, percentFontSize: style.percentFontSize)
                .frame(width: style.meterSize, height: style.meterSize)

            if let detailText = item.detailText {
                Text(detailText)
                    .font(.system(size: style.detailFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(resetText(item.resetsAt))
                .font(.system(size: style.resetFontSize, weight: .semibold))
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
    var percentFontSize: CGFloat

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
                    .font(.system(size: percentFontSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Text("剩余")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
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
