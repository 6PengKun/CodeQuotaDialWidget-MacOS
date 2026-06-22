import CodexQuotaCore
import QuotaDialWidgetUI
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
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
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
            EmptyQuotaView(
                title: "Codex 额度",
                footnote: "运行 CodexQuotaSnapshotTool 后刷新组件"
            )
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
        QuotaDialWidgetUI.QuotaDialDashboard(
            title: "Codex 额度",
            badge: badge,
            generatedAt: snapshot.generatedAt,
            hasError: snapshot.error != nil,
            items: items
        )
    }

    private var badge: QuotaDialBadge? {
        guard let plan = snapshot.planType else { return nil }
        return QuotaDialBadge(text: plan, tint: snapshot.isFreePlan ? .secondary : .blue)
    }

    private var items: [QuotaDialItem] {
        if let monthly = snapshot.monthly, snapshot.fiveHour == nil {
            return [item(id: "monthly", title: "30 天", window: monthly, tint: .indigo)]
        }
        return [
            snapshot.fiveHour.map { item(id: "five-hour", title: "5h", window: $0, tint: .cyan) },
            snapshot.weekly.map { item(id: "weekly", title: "本周", window: $0, tint: .indigo) }
        ].compactMap { $0 }
    }

    private func item(id: String, title: String, window: CodexQuotaWindow, tint: Color) -> QuotaDialItem {
        QuotaDialItem(
            id: id,
            title: title,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            tint: tint
        )
    }
}
