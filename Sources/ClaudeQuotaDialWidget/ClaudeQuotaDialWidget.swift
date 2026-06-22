import ClaudeQuotaCore
import QuotaDialWidgetUI
import SwiftUI
import WidgetKit

public struct ClaudeQuotaEntry: TimelineEntry {
    public let date: Date
    public let snapshot: ClaudeQuotaSnapshot?

    public init(date: Date, snapshot: ClaudeQuotaSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct ClaudeQuotaProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> ClaudeQuotaEntry {
        ClaudeQuotaEntry(date: Date(), snapshot: nil)
    }

    public func getSnapshot(in context: Context, completion: @escaping (ClaudeQuotaEntry) -> Void) {
        completion(ClaudeQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview)))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeQuotaEntry>) -> Void) {
        let entry = ClaudeQuotaEntry(date: Date(), snapshot: snapshot(forPreview: context.isPreview))
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func snapshot(forPreview isPreview: Bool) -> ClaudeQuotaSnapshot? {
        try? ClaudeQuotaSnapshotStore().load()
    }
}

public struct ClaudeQuotaWidgetEntryView: View {
    public var entry: ClaudeQuotaEntry

    public init(entry: ClaudeQuotaEntry) {
        self.entry = entry
    }

    public var body: some View {
        if let snapshot = entry.snapshot {
            QuotaDialDashboard(snapshot: snapshot)
        } else {
            EmptyQuotaView(
                title: "Claude 额度",
                footnote: "运行 ClaudeQuotaSnapshotTool 后刷新组件"
            )
        }
    }
}

public struct ClaudeQuotaDialWidget: Widget {
    public let kind = "ClaudeQuotaDialWidget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeQuotaProvider()) { entry in
            ClaudeQuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude 额度表盘")
        .description("显示 Claude Code 5h 和本周剩余额度与重置时间。")
        .supportedFamilies([.systemMedium])
    }
}

private struct QuotaDialDashboard: View {
    var snapshot: ClaudeQuotaSnapshot

    var body: some View {
        QuotaDialWidgetUI.QuotaDialDashboard(
            title: "Claude 额度",
            badge: snapshot.planType.map { QuotaDialBadge(text: $0) },
            generatedAt: snapshot.generatedAt,
            hasError: snapshot.error != nil,
            items: items
        )
    }

    private var items: [QuotaDialItem] {
        [
            snapshot.fiveHour.map { item(id: "five-hour", title: "5h", window: $0, tint: .cyan) },
            snapshot.weekly.map { item(id: "weekly", title: "本周", window: $0, tint: .indigo) }
        ].compactMap { $0 }
    }

    private func item(id: String, title: String, window: ClaudeQuotaWindow, tint: Color) -> QuotaDialItem {
        QuotaDialItem(
            id: id,
            title: title,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            tint: tint
        )
    }
}
