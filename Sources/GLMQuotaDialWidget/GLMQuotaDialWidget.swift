import GLMQuotaCore
import QuotaDialWidgetUI
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
            EmptyQuotaView(
                title: "GLM 额度",
                footnote: "运行 GLMQuotaSnapshotTool 后刷新组件"
            )
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
        QuotaDialWidgetUI.QuotaDialDashboard(
            title: "GLM 额度",
            badge: snapshot.level.map { QuotaDialBadge(text: $0) },
            generatedAt: snapshot.generatedAt,
            hasError: snapshot.error != nil,
            items: items,
            horizontalSpacing: 12,
            tileStyle: .compact
        )
    }

    private var items: [QuotaDialItem] {
        [
            snapshot.timeLimit.map { item(id: "time", title: "工具类额度", window: $0, tint: .cyan) },
            snapshot.tokensLimit5.map { item(id: "five-hour", title: "5h", window: $0, tint: .indigo) },
            snapshot.tokensLimitWeek.map { item(id: "weekly", title: "本周", window: $0, tint: .purple) }
        ].compactMap { $0 }
    }

    private func item(id: String, title: String, window: GLMQuotaWindow, tint: Color) -> QuotaDialItem {
        QuotaDialItem(
            id: id,
            title: title,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            tint: tint,
            detailText: detailText(window)
        )
    }

    private func detailText(_ window: GLMQuotaWindow) -> String? {
        guard let usage = window.usage, let remaining = window.remaining else { return nil }
        return "\(remaining)/\(usage)"
    }
}
