import ClaudeQuotaCore
import CodexQuotaCore
import Foundation
import GLMQuotaCore
import Testing

@testable import UsagePanelSupport

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Test func shortcutRangeStartsSevenDaysBeforeResetAtStartOfDay() throws {
    let calendar = utcCalendar()
    let resetAt = ISO8601DateFormatter().date(from: "2026-07-01T13:52:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-07-03T09:00:00Z")!
    let selectableStart = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    let selectableEnd = ISO8601DateFormatter().date(from: "2026-07-10T00:00:00Z")!
    let shortcut = UsageResetShortcut(source: .codex, title: "Codex 7日区间", resetAt: resetAt)

    let application = try #require(
        UsageRangeShortcutLogic.apply(
            shortcut: shortcut,
            selectedScopeID: "overview",
            selectableRange: selectableStart...selectableEnd,
            now: now,
            calendar: calendar
        )
    )

    #expect(application.selectedScopeID == "overview")
    #expect(application.selectionStartPeriod == "2026-06-24")
    #expect(application.selectionEndPeriod == "2026-07-03")
    #expect(application.rangeStart == ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z"))
    #expect(application.rangeEnd == ISO8601DateFormatter().date(from: "2026-07-03T00:00:00Z"))
}

@Test func shortcutRangeShiftsForwardOneDayWhenResetIsAfterEightPM() throws {
    let calendar = utcCalendar()
    let resetAt = ISO8601DateFormatter().date(from: "2026-06-26T21:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-06-27T09:00:00Z")!
    let selectableStart = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    let selectableEnd = ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!
    let shortcut = UsageResetShortcut(source: .claude, title: "Claude 7日区间", resetAt: resetAt)

    let application = try #require(
        UsageRangeShortcutLogic.apply(
            shortcut: shortcut,
            selectedScopeID: "claude",
            selectableRange: selectableStart...selectableEnd,
            now: now,
            calendar: calendar
        )
    )

    #expect(application.selectionStartPeriod == "2026-06-20")
    #expect(application.selectionEndPeriod == "2026-06-27")
    #expect(application.rangeStart == ISO8601DateFormatter().date(from: "2026-06-20T00:00:00Z"))
}

@Test func shortcutRangeReturnsNilWhenResetTimeMissing() {
    let calendar = utcCalendar()
    let start = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    let end = ISO8601DateFormatter().date(from: "2026-06-30T00:00:00Z")!
    let shortcut = UsageResetShortcut(source: .claude, title: "Claude 7日区间", resetAt: nil)

    let application = UsageRangeShortcutLogic.apply(
        shortcut: shortcut,
        selectedScopeID: "host:local:overview",
        selectableRange: start...end,
        now: end,
        calendar: calendar
    )

    #expect(application == nil)
}

@Test func shortcutRangeClampsToSelectableBounds() throws {
    let calendar = utcCalendar()
    let resetAt = ISO8601DateFormatter().date(from: "2026-07-01T13:52:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-07-03T09:00:00Z")!
    let selectableStart = ISO8601DateFormatter().date(from: "2026-06-28T00:00:00Z")!
    let selectableEnd = ISO8601DateFormatter().date(from: "2026-07-02T00:00:00Z")!
    let shortcut = UsageResetShortcut(source: .glm, title: "GLM 7日区间", resetAt: resetAt)

    let application = try #require(
        UsageRangeShortcutLogic.apply(
            shortcut: shortcut,
            selectedScopeID: "glm",
            selectableRange: selectableStart...selectableEnd,
            now: now,
            calendar: calendar
        )
    )

    #expect(application.selectionStartPeriod == "2026-06-28")
    #expect(application.selectionEndPeriod == "2026-07-02")
    #expect(application.rangeStart == selectableStart)
    #expect(application.rangeEnd == selectableEnd)
    #expect(application.selectedScopeID == "glm")
}

@Test func shortcutDefinitionsUseWeeklyResetTimesOnly() {
    let codexReset = ISO8601DateFormatter().date(from: "2026-07-01T13:52:00Z")!
    let claudeReset = ISO8601DateFormatter().date(from: "2026-07-02T08:00:00Z")!
    let glmReset = ISO8601DateFormatter().date(from: "2026-07-03T20:15:00Z")!

    let shortcuts = UsageRangeShortcutLogic.shortcuts(
        codex: CodexQuotaSnapshot(
            generatedAt: .now,
            fiveHour: CodexQuotaWindow(resetsAt: .now),
            weekly: CodexQuotaWindow(resetsAt: codexReset)
        ),
        claude: ClaudeQuotaSnapshot(
            generatedAt: .now,
            fiveHour: ClaudeQuotaWindow(resetsAt: .now),
            weekly: ClaudeQuotaWindow(resetsAt: claudeReset)
        ),
        glm: GLMQuotaSnapshot(
            generatedAt: .now,
            timeLimit: GLMQuotaWindow(resetsAt: .now),
            tokensLimit5: GLMQuotaWindow(resetsAt: .now),
            tokensLimitWeek: GLMQuotaWindow(resetsAt: glmReset)
        )
    )

    #expect(shortcuts.map(\.source) == [.codex, .claude, .glm])
    #expect(shortcuts.map(\.title) == ["Codex 7日区间", "Claude 7日区间", "GLM 7日区间"])
    #expect(shortcuts[0].resetAt == codexReset)
    #expect(shortcuts[1].resetAt == claudeReset)
    #expect(shortcuts[2].resetAt == glmReset)
}
