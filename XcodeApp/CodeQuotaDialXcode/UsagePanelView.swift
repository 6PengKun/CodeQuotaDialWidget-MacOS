import ClaudeQuotaCore
import Combine
import CodexQuotaCore
import GLMQuotaCore
import SwiftUI
import UsageQuotaCore
import WidgetKit

struct UsagePanelView: View {
    @State private var snapshot: UsageSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @State private var selectedScopeID = UsageScopeData.overviewID
    /// Calendar heatmap: the month currently displayed.
    @State private var displayedMonth: Date = .now
    /// What the inline detail card beside or below the calendar shows.
    @State private var detailSelection: CalendarDetailSelection = .today
    /// Custom date-range picker state.
    @State private var rangeStart: Date = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .now
    @State private var rangeEnd: Date = .now
    @State private var rangeShortcuts: [UsageResetShortcut] = []
    @StateObject private var agent = LaunchAgentController(
        label: LaunchAgentLabels.usage.label,
        plistPath: LaunchAgentLabels.usage.plist
    )

    private let refreshTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let badge = RemoteStatusBadge(sources: snapshot?.sources) {
                    badge.font(.caption2.weight(.bold))
                }

                LaunchAgentToggleRow(controller: agent)

                if scopes.count > 1 {
                    Picker("范围", selection: $selectedScopeID) {
                        ForEach(scopes) { scope in
                            Text(scope.title)
                                .tag(scope.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                }

                let calendarDays = selectedScope?.calendarDays ?? []
                calendarDetailSection(days: calendarDays)

                PeriodTiles(
                    weekly: selectedScope?.weekly,
                    monthly: selectedScope?.monthly,
                    total: selectedScope?.total
                )

                WeekTrendChart(days: selectedScope?.weekDays ?? [])

                ModelBreakdownCard(breakdowns: selectedScope?.breakdowns ?? [])

                if let message = errorText ?? agent.lastError {
                    InlineBanner(text: message)
                }
            }
            .padding(Theme.contentPadding)
        }
        .navigationTitle("消耗统计")
        .navigationSubtitle(snapshot.map { "更新于 \(quotaPanelTimeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(isRefreshing: isRefreshing) { await refresh() }
            }
        }
        .onAppear {
            loadSnapshot()
            agent.refreshStatus()
            syncRangeDates(to: detailSelection)
            if snapshot == nil {
                Task { await refresh() }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await refresh() }
        }
        .onChange(of: selectedScopeID) { _, _ in
            detailSelection = .today
            displayedMonth = .now
            syncRangeDates(to: .today)
        }
        .onChange(of: detailSelection) { _, newSelection in
            syncRangeDates(to: newSelection)
        }
    }

    private func calendarDetailSection(days: [UsageCalendarDay]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.cardSpacing) {
                usageHeatmap(days: days)
                usageDetailCard(days: days)
                    .frame(minWidth: 390, maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                usageHeatmap(days: days)
                usageDetailCard(days: days)
            }
        }
    }

    private func usageHeatmap(days: [UsageCalendarDay]) -> some View {
        UsageHeatmap(
            days: days,
            displayedMonth: $displayedMonth,
            selection: detailSelection,
            onSelectDay: { period in detailSelection = .single(period: period) }
        )
    }

    private func usageDetailCard(days: [UsageCalendarDay]) -> some View {
        UsageDetailCard(
            days: days,
            selection: $detailSelection,
            rangeStart: $rangeStart,
            rangeEnd: $rangeEnd,
            shortcuts: rangeShortcuts,
            selectedScopeID: selectedScopeID,
            todayDeltaPercent: usageTodayDeltaPercent(selectedScope?.weekDays ?? [])
        )
    }

    private func syncRangeDates(to selection: CalendarDetailSelection) {
        let start: Date
        let end: Date
        switch selection {
        case .today:
            start = Calendar.current.startOfDay(for: Date())
            end = start
        case .single(let period):
            guard let date = usageDayFormatter.date(from: period) else { return }
            start = date
            end = date
        case .range(let startPeriod, let endPeriod):
            guard
                let startDate = usageDayFormatter.date(from: startPeriod),
                let endDate = usageDayFormatter.date(from: endPeriod)
            else { return }
            start = min(startDate, endDate)
            end = max(startDate, endDate)
        }
        rangeStart = start
        rangeEnd = end
    }

    private var scopes: [UsageScopeData] {
        guard let snapshot else { return [] }
        let hostScopes = snapshot.hosts.flatMap { host in
            [UsageScopeData(host: host, overview: host.overview)]
                + host.agents.map { UsageScopeData(host: host, agent: $0) }
        }
        if !hostScopes.isEmpty {
            return [UsageScopeData(snapshot: snapshot)] + hostScopes
        }
        return [UsageScopeData(snapshot: snapshot)]
            + snapshot.ends.map(UsageScopeData.init(end:))
            + snapshot.agents.map(UsageScopeData.init(agent:))
    }

    private var selectedScope: UsageScopeData? {
        let scopes = scopes
        if let scope = scopes.first(where: { $0.id == selectedScopeID }) {
            return scope
        }
        return scopes.first
    }

    private func loadSnapshot() {
        do {
            snapshot = try UsageSnapshotStore().load()
            errorText = snapshot?.error
            normalizeSelectedScope()
        } catch {
            errorText = "暂无消耗快照。"
        }
        loadRangeShortcuts()
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            UsageCollector().collect()
        }.value

        do {
            try UsageSnapshotStore().save(newSnapshot)
            WidgetCenter.shared.reloadAllTimelines()
            snapshot = newSnapshot
            errorText = newSnapshot.error
            normalizeSelectedScope()
            loadRangeShortcuts()
        } catch {
            errorText = "保存消耗快照失败：\(error.localizedDescription)"
        }
    }

    private func normalizeSelectedScope() {
        let ids = Set(scopes.map(\.id))
        if !ids.contains(selectedScopeID) {
            selectedScopeID = UsageScopeData.overviewID
        }
    }

    private func loadRangeShortcuts() {
        rangeShortcuts = UsageRangeShortcutLogic.shortcuts(
            codex: try? CodexQuotaSnapshotStore().load(),
            claude: try? ClaudeQuotaSnapshotStore().load(),
            glm: try? GLMQuotaSnapshotStore().load()
        )
    }
}

private struct UsageScopeData: Identifiable {
    static let overviewID = "overview"

    var id: String
    var title: String
    var daily: UsageSummary
    var weekly: UsageSummary
    var monthly: UsageSummary
    var total: UsageSummary
    var weekDays: [UsageDay]
    var breakdowns: [UsageBreakdownSection]
    var calendarDays: [UsageCalendarDay]

    init(snapshot: UsageSnapshot) {
        id = Self.overviewID
        title = "总览"
        daily = snapshot.daily
        weekly = snapshot.weekly
        monthly = snapshot.monthly
        total = snapshot.total
        weekDays = snapshot.weekDays
        breakdowns = snapshot.breakdowns
        calendarDays = snapshot.calendarDays
    }

    init(agent: UsageAgentSnapshot) {
        id = agent.id
        title = agent.name.capitalized
        daily = agent.daily
        weekly = agent.weekly
        monthly = agent.monthly
        total = agent.total
        weekDays = agent.weekDays
        breakdowns = agent.breakdowns
        calendarDays = agent.calendarDays
    }

    init(host: UsageHostSnapshot, overview: UsageAgentSnapshot) {
        id = overview.id
        title = "\(host.name) · 总览"
        daily = overview.daily
        weekly = overview.weekly
        monthly = overview.monthly
        total = overview.total
        weekDays = overview.weekDays
        breakdowns = overview.breakdowns
        calendarDays = overview.calendarDays
    }

    init(host: UsageHostSnapshot, agent: UsageAgentSnapshot) {
        id = agent.id
        title = "\(host.name) · \(agent.name.capitalized)"
        daily = agent.daily
        weekly = agent.weekly
        monthly = agent.monthly
        total = agent.total
        weekDays = agent.weekDays
        breakdowns = agent.breakdowns
        calendarDays = agent.calendarDays
    }

    init(end: UsageAgentSnapshot) {
        id = end.id
        title = end.name  // already display-ready (本机 / host)
        daily = end.daily
        weekly = end.weekly
        monthly = end.monthly
        total = end.total
        weekDays = end.weekDays
        breakdowns = end.breakdowns
        calendarDays = end.calendarDays
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
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((warning ? Color.orange : Color.blue).opacity(0.15), in: Capsule())
            .foregroundStyle(warning ? Color.orange : Color.blue)
            .lineLimit(1)
    }
}

/// What the inline detail card beside or below the calendar renders.
enum CalendarDetailSelection: Equatable {
    case today
    case single(period: String)
    case range(start: String, end: String)
}

// MARK: - Calendar heatmap

/// Month-grid heatmap: color intensity encodes each day's total cost. Hover for
/// a cost+tokens tooltip; click a day to drive the adjacent detail card.
private struct UsageHeatmap: View {
    var days: [UsageCalendarDay]
    @Binding var displayedMonth: Date
    var selection: CalendarDetailSelection
    var onSelectDay: (String) -> Void
    @State private var hoveredPeriod: String?

    private let cellSize: CGFloat = 26
    private let cellSpacing: CGFloat = 5
    private var cardWidth: CGFloat {
        cellSize * 7 + cellSpacing * 6 + Theme.cardPadding * 2
    }

    private var dayByPeriod: [String: UsageCalendarDay] {
        Dictionary(days.map { ($0.period, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private var monthStart: Date {
        Calendar.current.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
    }
    private var currentMonthStart: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }
    private var earliestMonthStart: Date {
        guard
            let first = days.map(\.period).min(),
            let date = usageDayFormatter.date(from: first)
        else { return currentMonthStart }
        return Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }
    private var monthTitle: String { calendarMonthFormatter.string(from: monthStart) }
    /// Highest cost among the days visible in the displayed month — used to scale
    /// color intensity locally so a quiet month still shows relative contrast.
    private var monthMaxCost: Double {
        let periods = Set(periodsInMonth())
        let costs = days.filter { periods.contains($0.period) }.map(\.summary.totalCost)
        return max(costs.max() ?? 0, 0.01)
    }
    private var todayPeriod: String { usageDayFormatter.string(from: Date()) }

    private var canGoBackward: Bool { monthStart > earliestMonthStart }
    private var canGoForward: Bool { monthStart < currentMonthStart }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(monthTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(!canGoBackward)
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(!canGoForward)
            }

            // Weekday header, Monday-first to match the week chart.
            HStack(spacing: cellSpacing) {
                ForEach(weekdayHeaderLabels(), id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: cellSize)
                }
            }

            let cells = monthCells()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7), spacing: cellSpacing) {
                ForEach(cells, id: \.id) { cell in
                    if let period = cell.period {
                        dayCell(period: period)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.clear)
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(width: cardWidth, height: usageCalendarCardHeight, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onAppear(perform: clampDisplayedMonth)
        .onChange(of: days.map(\.period)) { _, _ in
            clampDisplayedMonth()
        }
    }

    @ViewBuilder
    private func dayCell(period: String) -> some View {
        let day = dayByPeriod[period]
        let intensity = day.map { min(1, $0.summary.totalCost / monthMaxCost) } ?? 0
        let isToday = period == todayPeriod
        let isSelected = isSingleSelected(period) || isInSelectedRange(period)
        let isHovered = hoveredPeriod == period
        RoundedRectangle(cornerRadius: 4)
            .fill(heatmapFill(intensity: intensity, hasData: day != nil))
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if isToday || isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isSelected ? Color.blue.opacity(0.9) : Color.primary.opacity(isHovered ? 0.8 : 0.55),
                            lineWidth: isSelected ? 2 : 1.5
                        )
                }
            }
            .overlay {
                Text(dayNumber(period))
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(day == nil ? .tertiary : .primary)
            }
            .overlay(alignment: .top) {
                if isHovered {
                    UsageDayHoverTip(period: period, summary: day?.summary)
                        .offset(y: -42)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if period <= todayPeriod {
                    onSelectDay(period)
                }
            }
            .onHover { isHovering in
                hoveredPeriod = isHovering ? period : (hoveredPeriod == period ? nil : hoveredPeriod)
            }
            .zIndex(isHovered ? 1 : 0)
    }

    private func isSingleSelected(_ period: String) -> Bool {
        if case .single(let p) = selection { return p == period }
        return false
    }
    private func isInSelectedRange(_ period: String) -> Bool {
        if case .range(let start, let end) = selection {
            return period >= start && period <= end
        }
        return false
    }

    private func heatmapFill(intensity: Double, hasData: Bool) -> Color {
        guard hasData else { return Color.secondary.opacity(0.06) }
        return Color.blue.opacity(0.25 + 0.6 * intensity)
    }

    // MARK: Month layout

    private struct MonthCell: Identifiable {
        let id: Int          // stable across recomputation (grid index)
        let period: String?  // nil = leading empty cell
    }

    /// All the day-period keys that fall within the displayed month.
    private func periodsInMonth() -> [String] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: monthStart) else { return [] }
        var date = interval.start
        var keys: [String] = []
        while date < interval.end {
            keys.append(usageDayFormatter.string(from: date))
            date = cal.date(byAdding: .day, value: 1, to: date) ?? interval.end
        }
        return keys
    }

    /// A stable six-week grid: leading empties, every day in the month, then
    /// trailing empties up to 42 cells.
    private func monthCells() -> [MonthCell] {
        let cal = Calendar.current
        guard let firstOfMonth = cal.dateInterval(of: .month, for: monthStart)?.start else { return [] }
        // weekday: 1=Sunday … 7=Saturday → Monday-first column index.
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let leading = (weekday + 5) % 7
        let monthDays = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        var cells: [MonthCell] = []
        var index = 0
        for _ in 0..<leading {
            cells.append(MonthCell(id: index, period: nil)); index += 1
        }
        for day in 1...monthDays {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { continue }
            cells.append(MonthCell(id: index, period: usageDayFormatter.string(from: date))); index += 1
        }
        while cells.count < 42 {
            cells.append(MonthCell(id: index, period: nil)); index += 1
        }
        return cells
    }

    private func weekdayHeaderLabels() -> [String] { ["一", "二", "三", "四", "五", "六", "日"] }

    private func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: monthStart) {
            displayedMonth = clampedMonth(next)
        }
    }

    private func clampDisplayedMonth() {
        let clamped = clampedMonth(displayedMonth)
        if clamped != displayedMonth {
            displayedMonth = clamped
        }
    }

    private func clampedMonth(_ date: Date) -> Date {
        let start = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
        if start < earliestMonthStart { return earliestMonthStart }
        if start > currentMonthStart { return currentMonthStart }
        return start
    }

    private func dayNumber(_ period: String) -> String {
        guard let date = usageDayFormatter.date(from: period) else { return "" }
        return String(Calendar.current.component(.day, from: date))
    }
}

private struct UsageDayHoverTip: View {
    var period: String
    var summary: UsageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(period)
                .font(.caption2.weight(.semibold))
            if let summary {
                Text("\(costText(summary.totalCost)) · \(compactNumber(summary.totalTokens)) tokens")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("无用量")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

// MARK: - Inline detail card (replaces the old "today" hero card)

/// Shows the selected day / date-range totals plus per-model breakdown. Defaults
/// to today; the calendar above drives single-day selection, and the inline date
/// pickers drive a custom range.
private struct UsageDetailCard: View {
    var days: [UsageCalendarDay]
    @Binding var selection: CalendarDetailSelection
    @Binding var rangeStart: Date
    @Binding var rangeEnd: Date
    var shortcuts: [UsageResetShortcut]
    var selectedScopeID: String
    var todayDeltaPercent: Double?

    private var dayByPeriod: [String: UsageCalendarDay] {
        Dictionary(days.map { ($0.period, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var resolvedRange: (start: String, end: String) {
        let start = min(rangeStart, rangeEnd)
        let end = max(rangeStart, rangeEnd)
        return (usageDayFormatter.string(from: start), usageDayFormatter.string(from: end))
    }

    private var datePickerRange: ClosedRange<Date> {
        selectableStartDate...selectableEndDate
    }

    private var selectableStartDate: Date {
        guard
            let firstPeriod = days.map(\.period).min(),
            let firstDate = usageDayFormatter.date(from: firstPeriod)
        else { return selectableEndDate }
        return min(firstDate, selectableEndDate)
    }

    private var selectableEndDate: Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// Days that fall within the current selection (today / single / range).
    private var selectedDays: [UsageCalendarDay] {
        switch selection {
        case .today:
            let today = usageDayFormatter.string(from: Date())
            return dayByPeriod[today].map { [$0] } ?? []
        case .single(let period):
            return dayByPeriod[period].map { [$0] } ?? []
        case .range(let start, let end):
            return days.filter { $0.period >= start && $0.period <= end }
        }
    }

    private var aggregated: UsageSummary {
        selectedDays.reduce(UsageSummary()) { $0 + $1.summary }
    }

    /// Aggregated per-model usage across the selected days, sorted by cost.
    private var aggregatedModels: [(name: String, summary: UsageSummary)] {
        var grouped: [String: UsageSummary] = [:]
        for day in selectedDays {
            for model in day.models {
                grouped[model.name, default: UsageSummary()] = grouped[model.name, default: UsageSummary()] + model.summary
            }
        }
        return grouped
            .filter { $0.value.totalTokens > 0 || $0.value.totalCost > 0 }
            .map { (name: $0.key, summary: $0.value) }
            .sorted { lhs, rhs in
                if lhs.summary.totalCost == rhs.summary.totalCost { return lhs.name < rhs.name }
                return lhs.summary.totalCost > rhs.summary.totalCost
            }
    }

    private var titleText: String {
        switch selection {
        case .today: return "今日"
        case .single(let period):
            guard let date = usageDayFormatter.date(from: period) else { return period }
            return singleDayFormatter.string(from: date)
        case .range(let start, let end):
            guard let s = usageDayFormatter.date(from: start), let e = usageDayFormatter.date(from: end) else {
                return "区间"
            }
            if start == end { return singleDayFormatter.string(from: s) }
            return "\(singleDayFormatter.string(from: s)) – \(singleDayFormatter.string(from: e))"
        }
    }

    private var selectionID: String {
        switch selection {
        case .today:
            return "today"
        case .single(let period):
            return "single-\(period)"
        case .range(let start, let end):
            return "range-\(start)-\(end)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if case .today = selection, let delta = todayDeltaPercent {
                        DeltaBadge(percent: delta)
                    }
                    Spacer()
                    Button("今日") {
                        selection = .today
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .disabled(isTodaySelected)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(costText(aggregated.totalCost))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("\(compactNumber(aggregated.totalTokens)) tokens")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            TokenValueRow(summary: aggregated)

            Divider()

            HStack(alignment: .center, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("区间")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        CompactDatePickerButton(
                            date: $rangeStart,
                            range: datePickerRange
                        )
                        Text("至")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        CompactDatePickerButton(
                            date: $rangeEnd,
                            range: datePickerRange
                        )
                        ForEach(shortcuts) { shortcut in
                            Button(shortcut.title) {
                                applyShortcut(shortcut)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .font(.system(size: 11, weight: .medium))
                            .disabled(shortcut.resetAt == nil)
                        }
                    }
                    .padding(.vertical, 1)
                }

                Button("应用") {
                    normalizeRangeDates()
                    let range = resolvedRange
                    selection = .range(start: range.start, end: range.end)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("模型明细")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if aggregatedModels.isEmpty {
                    Text("所选范围暂无模型数据")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    let totalCost = aggregatedModels.reduce(0) { $0 + $1.summary.totalCost }
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(aggregatedModels, id: \.name) { model in
                                ModelUsageRow(
                                    name: model.name,
                                    summary: model.summary,
                                    percent: totalCost > 0 ? model.summary.totalCost / totalCost * 100 : 0
                                )
                            }
                        }
                    }
                    .id(selectionID)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: usageCalendarCardHeight, alignment: .topLeading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .onAppear(perform: normalizeRangeDates)
        .onChange(of: days.map(\.period)) { _, _ in
            normalizeRangeDates()
        }
    }

    private var isTodaySelected: Bool {
        if case .today = selection { return true }
        return false
    }

    private func normalizeRangeDates() {
        let start = min(max(rangeStart, selectableStartDate), selectableEndDate)
        let end = min(max(rangeEnd, selectableStartDate), selectableEndDate)
        if start <= end {
            rangeStart = start
            rangeEnd = end
        } else {
            rangeStart = end
            rangeEnd = start
        }
    }

    private func applyShortcut(_ shortcut: UsageResetShortcut) {
        guard let application = UsageRangeShortcutLogic.apply(
            shortcut: shortcut,
            selectedScopeID: selectedScopeID,
            selectableRange: datePickerRange,
            now: Date(),
            calendar: .current
        ) else { return }

        rangeStart = application.rangeStart
        rangeEnd = application.rangeEnd
        selection = .range(start: application.selectionStartPeriod, end: application.selectionEndPeriod)
    }
}

private let usageCalendarCardHeight: CGFloat = 270

private struct CompactDatePickerButton: View {
    @Binding var date: Date
    var range: ClosedRange<Date>
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(compactDateFormatter.string(from: date), systemImage: "calendar")
                .font(.caption2)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusable(false)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DatePicker(
                "",
                selection: $date,
                in: range,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .padding(10)
            .fixedSize()
        }
    }
}

private struct ModelUsageRow: View {
    var name: String
    var summary: UsageSummary
    var percent: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(costText(summary.totalCost)) · \(String(format: "%.1f", percent))% · \(compactNumber(summary.totalTokens)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: geo.size.width * min(1, max(0, percent / 100)))
                }
            }
            .frame(height: 3)
        }
    }
}

private struct DeltaBadge: View {
    var percent: Double

    var body: some View {
        let up = percent >= 0
        return Text("\(up ? "↑" : "↓") \(String(format: "%.0f", abs(percent)))% · 昨日")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(up ? Color.orange : Color.green)
            .lineLimit(1)
    }
}

private struct TokenValueRow: View {
    var summary: UsageSummary?

    var body: some View {
        HStack(spacing: Theme.cardSpacing) {
            TokenValue(label: "输入", value: summary?.inputTokens)
            TokenValue(label: "输出", value: summary?.outputTokens)
            TokenValue(label: "缓存写", value: summary?.cacheCreationTokens)
            TokenValue(label: "缓存读", value: summary?.cacheReadTokens)
        }
    }
}

private struct TokenValue: View {
    var label: String
    var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(compactNumber(value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PeriodTiles: View {
    var weekly: UsageSummary?
    var monthly: UsageSummary?
    var total: UsageSummary?

    var body: some View {
        HStack(spacing: Theme.cardSpacing) {
            PeriodTile(title: "本周", summary: weekly)
            PeriodTile(title: "本月", summary: monthly)
            PeriodTile(title: "总计", summary: total)
        }
    }
}

private struct PeriodTile: View {
    var title: String
    var summary: UsageSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(costText(summary?.totalCost))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(compactNumber(summary?.totalTokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

private struct WeekTrendChart: View {
    var days: [UsageDay]

    private var maxCost: Double { max(days.map(\.totalCost).max() ?? 0, 0.01) }
    /// Average over elapsed days only (through today). Future days in the current
    /// week are still zero, so including them would understate the daily average.
    private var average: Double {
        let elapsed = days.filter { $0.period <= todayPeriod }
        return elapsed.isEmpty ? 0 : elapsed.map(\.totalCost).reduce(0, +) / Double(elapsed.count)
    }
    private var todayPeriod: String { usageDayFormatter.string(from: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本周趋势")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("均值 \(costText(average))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 5) {
                ZStack(alignment: .bottom) {
                    GeometryReader { geo in
                        let y = geo.size.height * (1 - CGFloat(average / maxCost))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }

                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(days) { day in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(day))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(4, 88 * day.totalCost / maxCost))
                                .overlay {
                                    if day.period == todayPeriod {
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                    }
                                }
                        }
                    }
                }
                .frame(height: 88)

                HStack(spacing: 8) {
                    ForEach(days) { day in
                        VStack(spacing: 1) {
                            Text(weekdayShort(day.period))
                                .font(.system(size: 10, weight: day.period == todayPeriod ? .semibold : .regular))
                                .foregroundStyle(day.period == todayPeriod ? Color.primary : Color.secondary)
                            Text(costText(day.totalCost))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(Theme.cardPadding)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }

    private func barColor(_ day: UsageDay) -> Color {
        let intensity = maxCost > 0 ? day.totalCost / maxCost : 0
        return Color.blue.opacity(0.35 + 0.6 * intensity)
    }
}

private struct ModelBreakdownCard: View {
    var breakdowns: [UsageBreakdownSection]
    @State private var period: ModelPeriod = .today

    enum ModelPeriod: String, CaseIterable, Identifiable {
        case today = "今日"
        case week = "本周"
        case month = "本月"
        case total = "总计"

        var id: String { rawValue }

        var suffix: String {
            switch self {
            case .today: return "today-models"
            case .week: return "week-models"
            case .month: return "month-models"
            case .total: return "total-models"
            }
        }
    }

    private var section: UsageBreakdownSection? {
        breakdowns.first { $0.id.hasSuffix(period.suffix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型分布")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $period) {
                    ForEach(ModelPeriod.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let items = section?.items, !items.isEmpty {
                ForEach(items.prefix(6)) { item in
                    ModelRow(item: item)
                }
            } else {
                Text("暂无模型数据")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
    }
}

private struct ModelRow: View {
    var item: UsageBreakdownItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(costText(item.totalCost)) · \(String(format: "%.1f", item.percent))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: geo.size.width * min(1, max(0, item.percent / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

private func usageTodayDeltaPercent(_ days: [UsageDay]) -> Double? {
    let today = usageDayFormatter.string(from: Date())
    guard
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()),
        let todayCost = days.first(where: { $0.period == today })?.totalCost
    else { return nil }
    let yesterday = usageDayFormatter.string(from: yesterdayDate)
    guard let yesterdayCost = days.first(where: { $0.period == yesterday })?.totalCost, yesterdayCost > 0 else {
        return nil
    }
    return (todayCost - yesterdayCost) / yesterdayCost * 100
}

private func costText(_ value: Double?) -> String {
    guard let value else { return "$--" }
    return String(format: "$%.2f", value)
}

private func compactNumber(_ value: Int?) -> String {
    guard let value else { return "--" }
    let number = Double(value)
    if number >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if number >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return "\(value)"
}

private func weekdayShort(_ period: String) -> String {
    guard let date = usageDayFormatter.date(from: period) else { return "" }
    let index = Calendar.current.component(.weekday, from: date)
    let labels = ["日", "一", "二", "三", "四", "五", "六"]
    return labels[max(0, min(6, index - 1))]
}

private let usageDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let calendarMonthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月"
    return formatter
}()

private let singleDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return formatter
}()

private let compactDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy/M/d"
    return formatter
}()
