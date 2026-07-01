import SwiftUI
import UsageQuotaCore
import WidgetKit

struct ModelPricesPanelView: View {
    @State private var snapshot: UsageSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @State private var hoveredID: String?

    private var records: [UsageModelPriceRecord] {
        (snapshot?.modelPrices ?? []).sorted { lhs, rhs in
            if lhs.totalCost == rhs.totalCost {
                if lhs.modelName == rhs.modelName { return lhs.source.rawValue < rhs.source.rawValue }
                return lhs.modelName < rhs.modelName
            }
            return lhs.totalCost > rhs.totalCost
        }
    }

    private var totalCost: Double { records.reduce(0) { $0 + $1.totalCost } }
    private var totalTokens: Int { records.reduce(0) { $0 + $1.totalTokens } }

    /// LiteLLM 价格表的抓取时间：来自任意一条 ccusage 记录的 `unitPriceFetchedAt`
    /// （同一次 collect() 内所有 ccusage 记录共享同一个 LiteLLM 目录抓取时间）。
    private var liteLLMFetchedAt: Date? {
        records.first { $0.source == .ccusageReport }?.unitPriceFetchedAt
    }

    /// Z.AI 价格表的抓取时间：来自任意一条 Z.AI 官方/缓存记录的 `fetchedAt`。
    private var zaiFetchedAt: Date? {
        records.first { $0.source == .zaiOfficial || $0.source == .zaiCache }?.fetchedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if !records.isEmpty {
                summaryHeader
                pricingSourceTimestamps
                InlineBanner(
                    text: "Claude模型的“缓存写”列含两档单价，根据官方 Claude Code 文档，订阅模式下默认写1小时缓存，API模式下默认写5分钟缓存，会根据实际使用情况计费。",
                    systemImage: "info.circle"
                )
                modelPricesTable
            } else {
                emptyState
            }

            if let errorText {
                InlineBanner(text: errorText)
            }
        }
        .padding(Theme.contentPadding)
        .navigationTitle("模型价格")
        .navigationSubtitle(snapshot.map { "更新于 \(quotaPanelTimeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(
                    isRefreshing: isRefreshing,
                    helpText: "强制重新抓取最新模型价格，并刷新当前用量数据"
                ) { await refresh() }
            }
        }
        .onAppear {
            loadSnapshot()
            if snapshot == nil {
                Task { await refresh() }
            }
        }
    }

    // MARK: - 顶部汇总

    private var summaryHeader: some View {
        HStack(spacing: 14) {
            summaryStat(value: "\(records.count)", label: "模型", tint: .blue)
            summaryStat(value: ModelPricesFormat.compactNumber(totalTokens), label: "总 Tokens", tint: .purple)
            summaryStat(value: ModelPricesFormat.cost(totalCost), label: "总花费", tint: .green)
            Spacer(minLength: 0)
        }
    }

    private func summaryStat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var pricingSourceTimestamps: some View {
        HStack(spacing: 16) {
            pricingSourceStamp(label: "LiteLLM", date: liteLLMFetchedAt)
            pricingSourceStamp(label: "Z.AI", date: zaiFetchedAt)
            Spacer(minLength: 0)
        }
    }

    private func pricingSourceStamp(label: String, date: Date?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(date.map { "\(label) 价格更新于 \(quotaPanelTimeFormatter.string(from: $0))" } ?? "\(label) 价格：暂无抓取记录")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - 价格表

    private var modelPricesTable: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    tableHeader
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        tableRow(record, index: index)
                    }
                }
                .frame(minWidth: PriceCol.totalWidth, alignment: .leading)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
        }
        .frame(minHeight: 360)
        .cardSurface(padded: false)
    }

    private var tableHeader: some View {
        HStack(spacing: PriceCol.spacing) {
            headerCell("模型", width: PriceCol.model, align: .leading)
            headerCell("来源", width: PriceCol.source, align: .leading)
            headerCell("输入/1M", width: PriceCol.price, align: .trailing)
            headerCell("缓存写/1M", width: PriceCol.cacheWrite, align: .trailing)
            headerCell("缓存读/1M", width: PriceCol.price, align: .trailing)
            headerCell("输出/1M", width: PriceCol.price, align: .trailing)
            headerCell("有效/1M", width: PriceCol.price, align: .trailing)
            headerCell("Tokens", width: PriceCol.tokens, align: .trailing)
            headerCell("Cost", width: PriceCol.cost, align: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05))
    }

    private func tableRow(_ record: UsageModelPriceRecord, index: Int) -> some View {
        let isHovered = hoveredID == record.id
        return HStack(spacing: PriceCol.spacing) {
            Text(record.modelName)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: PriceCol.model, alignment: .leading)
                .help(record.modelName)

            PriceSourceBadge(text: sourceText(record.source), tint: sourceTint(record.source))
                .frame(width: PriceCol.source, alignment: .leading)

            priceCell(record.inputCostPerMTokUSD)
            cacheWriteCell(record)
            priceCell(record.cacheReadCostPerMTokUSD)
            priceCell(record.outputCostPerMTokUSD)
            priceCell(record.effectiveCostPerMTokUSD, emphasized: true)

            Text(ModelPricesFormat.compactNumber(record.totalTokens))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: PriceCol.tokens, alignment: .trailing)

            Text(ModelPricesFormat.cost(record.totalCost))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: PriceCol.cost, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(rowBackground(index: index, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? record.id : (hoveredID == record.id ? nil : hoveredID) }
    }

    private func rowBackground(index: Int, isHovered: Bool) -> Color {
        if isHovered { return Color.accentColor.opacity(0.10) }
        return index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.035)
    }

    /// 缓存写一列同时展示两档 TTL 单价：$6.25(5m) / $10(1h)。只有 5 分钟价时退回单值。
    private func cacheWriteCell(_ record: UsageModelPriceRecord) -> some View {
        let text: String
        if let m5 = record.cacheCreationCostPerMTokUSD, let h1 = record.cacheCreation1hCostPerMTokUSD {
            text = "\(ModelPricesFormat.price(m5))(5m) / \(ModelPricesFormat.price(h1))(1h)"
        } else {
            text = ModelPricesFormat.price(record.cacheCreationCostPerMTokUSD)
        }
        return Text(text)
            .font(.callout)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: PriceCol.cacheWrite, alignment: .trailing)
    }

    private func priceCell(_ value: Double?, emphasized: Bool = false) -> some View {
        Text(ModelPricesFormat.price(value))
            .font(.callout)
            .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .fontWeight(emphasized ? .semibold : .regular)
            .monospacedDigit()
            .frame(width: PriceCol.price, alignment: .trailing)
    }

    private func headerCell(_ text: String, width: CGFloat, align: Alignment) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: align)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("暂无模型价格")
                .font(.callout.weight(.semibold))
            Text("刷新“消耗统计”或本页后，会根据已用过模型生成价格记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    // MARK: - 数据

    private func loadSnapshot() {
        do {
            snapshot = try UsageSnapshotStore().load()
            errorText = snapshot?.error
        } catch {
            errorText = "暂无消耗快照。"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            UsageCollector().collect(mode: .online)
        }.value

        do {
            try UsageSnapshotStore().save(newSnapshot)
            WidgetCenter.shared.reloadAllTimelines()
            snapshot = newSnapshot
            errorText = newSnapshot.error
        } catch {
            errorText = "保存消耗快照失败：\(error.localizedDescription)"
        }
    }

    private func sourceText(_ source: UsageModelPriceSource) -> String {
        switch source {
        case .zaiOfficial: return "Z.AI 官方"
        case .zaiCache: return "Z.AI 缓存"
        case .builtinFallback: return "内置"
        case .ccusageReport: return "ccusage"
        }
    }

    private func sourceTint(_ source: UsageModelPriceSource) -> Color {
        switch source {
        case .zaiOfficial: return .green
        case .zaiCache: return .teal
        case .builtinFallback: return .orange
        case .ccusageReport: return .blue
        }
    }

}

// MARK: - 列宽

private enum PriceCol {
    static let model: CGFloat = 132
    static let source: CGFloat = 60
    static let price: CGFloat = 84
    static let cacheWrite: CGFloat = 158 // 同列展示 5m / 1h 两档单价，比普通价格列宽
    static let tokens: CGFloat = 72
    static let cost: CGFloat = 82
    static let spacing: CGFloat = 14

    static var totalWidth: CGFloat {
        model + source + price * 4 + cacheWrite + tokens + cost
            + spacing * 8 + 28 // 8 个间隔 + 左右内边距
    }
}

// MARK: - 来源徽标

private struct PriceSourceBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - 格式化

private enum ModelPricesFormat {
    static func price(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "$%.4g", value)
    }

    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func compactNumber(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }
}
