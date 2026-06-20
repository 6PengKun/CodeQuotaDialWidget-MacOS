import Foundation
import Testing

@testable import CodexQuotaCore

@Test func parsesFiveHourAndWeeklyLimits() throws {
    let body = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {
          "used_percent": 27,
          "limit_window_seconds": 18000,
          "reset_at": 1760000000
        },
        "secondary_window": {
          "used_percent": 42,
          "limit_window_seconds": 604800,
          "reset_at": 1760400000
        }
      }
    }
    """

    let snapshot = try CodexQuotaCollector.parseUsageResponse(body)

    #expect(snapshot.fiveHour?.remainingPercent == 73)
    #expect(snapshot.fiveHour?.usedPercent == 27)
    #expect(snapshot.fiveHour?.windowDurationMins == 300)
    #expect(snapshot.weekly?.remainingPercent == 58)
    #expect(snapshot.weekly?.usedPercent == 42)
    #expect(snapshot.weekly?.windowDurationMins == 10_080)
    #expect(snapshot.planType == "plus")
}

@Test func clampsRemainingPercent() throws {
    let body = """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": 115,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": -8,
          "limit_window_seconds": 604800
        }
      }
    }
    """

    let snapshot = try CodexQuotaCollector.parseUsageResponse(body)

    #expect(snapshot.fiveHour?.remainingPercent == 0)
    #expect(snapshot.weekly?.remainingPercent == 100)
}

@Test func parsesFreePlanMonthlyWindow() throws {
    let body = """
    {
      "plan_type": "free",
      "rate_limit": {
        "primary_window": {
          "used_percent": 5,
          "limit_window_seconds": 2592000,
          "reset_at": 1784529740
        },
        "secondary_window": null
      }
    }
    """

    let snapshot = try CodexQuotaCollector.parseUsageResponse(body)

    #expect(snapshot.planType == "free")
    #expect(snapshot.isFreePlan)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.weekly == nil)
    #expect(snapshot.monthly?.remainingPercent == 95)
    #expect(snapshot.monthly?.usedPercent == 5)
    #expect(snapshot.monthly?.windowDurationMins == 43_200)
    #expect(snapshot.error == nil)
    #expect(!snapshot.isRefreshFailure)
}

@Test func marksMissingWindowsAsError() throws {
    let snapshot = try CodexQuotaCollector.parseUsageResponse(#"{"plan_type":"pro","credits":{"has_credits":false}}"#)

    #expect(snapshot.error == "quota windows not found")
    #expect(snapshot.planType == "pro")
    #expect(snapshot.isRefreshFailure)
}

@Test func parsesOAuthCredentials() throws {
    let credentials = """
    {
      "auth_mode": "chatgpt",
      "tokens": {
        "access_token": "token-a",
        "account_id": "account-a"
      }
    }
    """

    let parsed = try CodexQuotaCollector.parseCredentialsData(Data(credentials.utf8))

    #expect(parsed.accessToken == "token-a")
    #expect(parsed.accountId == "account-a")
}

@Test func rejectsNonOAuthCredentials() throws {
    let credentials = """
    {
      "auth_mode": "api_key",
      "tokens": {
        "access_token": "token-a"
      }
    }
    """

    #expect(throws: Error.self) {
        try CodexQuotaCollector.parseCredentialsData(Data(credentials.utf8))
    }
}

@Test func marksErrorOrEmptySnapshotsAsRefreshFailures() {
    let errorSnapshot = CodexQuotaSnapshot(generatedAt: Date(), error: "network failed")
    let emptySnapshot = CodexQuotaSnapshot(generatedAt: Date())
    let validSnapshot = CodexQuotaSnapshot(
        generatedAt: Date(),
        fiveHour: CodexQuotaWindow(remainingPercent: 70),
        weekly: CodexQuotaWindow(remainingPercent: 40)
    )
    let partialSnapshot = CodexQuotaSnapshot(
        generatedAt: Date(),
        fiveHour: CodexQuotaWindow(remainingPercent: 70)
    )

    #expect(errorSnapshot.isRefreshFailure)
    #expect(emptySnapshot.isRefreshFailure)
    #expect(partialSnapshot.isRefreshFailure)
    #expect(!validSnapshot.isRefreshFailure)
}
