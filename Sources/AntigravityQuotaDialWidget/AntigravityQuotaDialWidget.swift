import AntigravityQuotaCore
import QuotaDialWidgetUI
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
            EmptyQuotaView(
                title: "Antigravity 5小时限额",
                footnote: "运行 AntigravityQuotaSnapshotTool 后刷新组件"
            )
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
        QuotaDialWidgetUI.QuotaDialDashboard(
            title: "Antigravity 5小时限额",
            badge: snapshot.planType.map { QuotaDialBadge(text: $0) },
            generatedAt: snapshot.generatedAt,
            hasError: snapshot.error != nil,
            items: AntigravityQuotaBucket.allCases.map(item)
        )
    }

    private func item(_ bucket: AntigravityQuotaBucket) -> QuotaDialItem {
        let model = snapshot.model(for: bucket)
        return QuotaDialItem(
            id: bucket.rawValue,
            title: bucket.displayName,
            remainingPercent: model?.remainingPercent,
            resetsAt: model?.resetsAt,
            tint: bucket.tint
        )
    }
}

private extension AntigravityQuotaBucket {
    var tint: Color {
        switch self {
        case .claude: return .cyan
        case .gemini: return .indigo
        }
    }
}
