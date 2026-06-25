import ClaudeQuotaCore
import CodexQuotaCore
import Foundation
import GLMQuotaCore

enum UsageShortcutSource: String, CaseIterable {
    case codex
    case claude
    case glm

    var title: String {
        switch self {
        case .codex: return "Codex 7日区间"
        case .claude: return "Claude 7日区间"
        case .glm: return "GLM 7日区间"
        }
    }
}

struct UsageResetShortcut: Equatable, Identifiable {
    var source: UsageShortcutSource
    var title: String
    var resetAt: Date?

    var id: String { source.rawValue }
}

struct UsageShortcutApplication: Equatable {
    var selectedScopeID: String
    var rangeStart: Date
    var rangeEnd: Date
    var selectionStartPeriod: String
    var selectionEndPeriod: String
}

enum UsageRangeShortcutLogic {
    static func shortcuts(
        codex: CodexQuotaSnapshot?,
        claude: ClaudeQuotaSnapshot?,
        glm: GLMQuotaSnapshot?
    ) -> [UsageResetShortcut] {
        [
            UsageResetShortcut(source: .codex, title: UsageShortcutSource.codex.title, resetAt: codex?.weekly?.resetsAt),
            UsageResetShortcut(source: .claude, title: UsageShortcutSource.claude.title, resetAt: claude?.weekly?.resetsAt),
            UsageResetShortcut(source: .glm, title: UsageShortcutSource.glm.title, resetAt: glm?.tokensLimitWeek?.resetsAt),
        ]
    }

    static func apply(
        shortcut: UsageResetShortcut,
        selectedScopeID: String,
        selectableRange: ClosedRange<Date>,
        now: Date,
        calendar: Calendar
    ) -> UsageShortcutApplication? {
        guard
            let resetAt = shortcut.resetAt,
            let rawStart = calendar.date(byAdding: .day, value: startOffsetDays(for: resetAt, calendar: calendar), to: resetAt)
        else { return nil }

        let start = clamped(
            calendar.startOfDay(for: rawStart),
            to: selectableRange
        )
        let end = clamped(
            calendar.startOfDay(for: now),
            to: selectableRange
        )
        let lower = min(start, end)
        let upper = max(start, end)
        let formatter = dayFormatter(calendar: calendar)

        return UsageShortcutApplication(
            selectedScopeID: selectedScopeID,
            rangeStart: lower,
            rangeEnd: upper,
            selectionStartPeriod: formatter.string(from: lower),
            selectionEndPeriod: formatter.string(from: upper)
        )
    }

    private static func clamped(_ date: Date, to range: ClosedRange<Date>) -> Date {
        min(max(date, range.lowerBound), range.upperBound)
    }

    private static func startOffsetDays(for resetAt: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: resetAt)
        let isAfterEightPM =
            (components.hour ?? 0) > 20
            || ((components.hour ?? 0) == 20 && (
                (components.minute ?? 0) > 0
                || (components.second ?? 0) > 0
                || (components.nanosecond ?? 0) > 0
            ))
        return isAfterEightPM ? -6 : -7
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
