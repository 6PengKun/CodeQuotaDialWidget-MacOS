import Foundation
import Testing

@testable import ClaudeQuotaCore

@Test func parsesFiveHourAndWeeklyLimits() throws {
    let body = """
    {
      "five_hour": {
        "utilization": 20.0,
        "resets_at": "2026-06-15T16:49:59.980473+00:00"
      },
      "seven_day": {
        "utilization": 2.0,
        "resets_at": "2026-06-19T12:59:59.980493+00:00"
      },
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "extra_usage": {
        "is_enabled": false
      }
    }
    """

    let snapshot = try ClaudeQuotaCollector.parseResponse(body)

    #expect(snapshot.fiveHour?.usedPercent == 20)
    #expect(snapshot.fiveHour?.remainingPercent == 80)
    #expect(snapshot.weekly?.usedPercent == 2)
    #expect(snapshot.weekly?.remainingPercent == 98)
    #expect(snapshot.fiveHour?.resetsAt != nil)
    #expect(snapshot.weekly?.resetsAt != nil)
}

@Test func clampsUtilization() throws {
    let body = """
    {
      "five_hour": {
        "utilization": 115.0
      },
      "seven_day": {
        "utilization": -8.0
      }
    }
    """

    let snapshot = try ClaudeQuotaCollector.parseResponse(body)

    #expect(snapshot.fiveHour?.usedPercent == 100)
    #expect(snapshot.fiveHour?.remainingPercent == 0)
    #expect(snapshot.weekly?.usedPercent == 0)
    #expect(snapshot.weekly?.remainingPercent == 100)
}

@Test func marksMissingWindowsAsError() throws {
    let snapshot = try ClaudeQuotaCollector.parseResponse(#"{"extra_usage":{"is_enabled":false}}"#)

    #expect(snapshot.error == "quota windows not found")
    #expect(snapshot.isRefreshFailure)
}

@Test func parsesClaudeAiOauthCredentials() throws {
    let credentials = """
    {
      "claudeAiOauth": {
        "accessToken": "token-a",
        "expiresAt": 4102444800000
      }
    }
    """

    let token = try ClaudeQuotaCollector.parseCredentialsData(Data(credentials.utf8))

    #expect(token == "token-a")
}

@Test func parsesDotKeyCredentials() throws {
    let credentials = """
    {
      "claude.ai_oauth": {
        "accessToken": "token-b",
        "expiresAt": "2036-06-15T16:49:59.980473+00:00"
      }
    }
    """

    let token = try ClaudeQuotaCollector.parseCredentialsData(Data(credentials.utf8))

    #expect(token == "token-b")
}

@Test func marksErrorOrEmptySnapshotsAsRefreshFailures() {
    let errorSnapshot = ClaudeQuotaSnapshot(generatedAt: Date(), error: "network failed")
    let emptySnapshot = ClaudeQuotaSnapshot(generatedAt: Date())
    let validSnapshot = ClaudeQuotaSnapshot(
        generatedAt: Date(),
        fiveHour: ClaudeQuotaWindow(remainingPercent: 80),
        weekly: ClaudeQuotaWindow(remainingPercent: 98)
    )
    let partialSnapshot = ClaudeQuotaSnapshot(
        generatedAt: Date(),
        fiveHour: ClaudeQuotaWindow(remainingPercent: 80)
    )

    #expect(errorSnapshot.isRefreshFailure)
    #expect(emptySnapshot.isRefreshFailure)
    #expect(partialSnapshot.isRefreshFailure)
    #expect(!validSnapshot.isRefreshFailure)
}
