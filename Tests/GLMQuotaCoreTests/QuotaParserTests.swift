import Foundation
import Testing

@testable import GLMQuotaCore

@Test func parsesGLMQuotaResponse() throws {
    let json = """
    {"code":200,"msg":"Operation successful","data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":34,"remaining":966,"percentage":3,"nextResetTime":1782871216971},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20,"nextResetTime":1781005073339},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":18,"nextResetTime":1781229616989}],"level":"pro"},"success":true}
    """

    let snapshot = try GLMQuotaCollector.parseResponse(json)

    #expect(snapshot.timeLimit != nil)
    #expect(snapshot.timeLimit?.remainingPercent == 97)
    #expect(snapshot.timeLimit?.usedPercent == 3)
    #expect(snapshot.timeLimit?.usage == 1000)
    #expect(snapshot.timeLimit?.remaining == 966)

    #expect(snapshot.tokensLimit5 != nil)
    #expect(snapshot.tokensLimit5?.remainingPercent == 80)
    #expect(snapshot.tokensLimit5?.usedPercent == 20)

    #expect(snapshot.tokensLimitWeek != nil)
    #expect(snapshot.tokensLimitWeek?.remainingPercent == 82)
    #expect(snapshot.tokensLimitWeek?.usedPercent == 18)

    #expect(snapshot.level == "pro")
    #expect(snapshot.error == nil)
}

@Test func clampsPercentageOutOfBounds() throws {
    let json = """
    {"code":200,"msg":"ok","data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":150,"nextResetTime":1782871216971}],"level":"free"},"success":true}
    """

    let snapshot = try GLMQuotaCollector.parseResponse(json)

    #expect(snapshot.timeLimit?.usedPercent == 100)
    #expect(snapshot.timeLimit?.remainingPercent == 0)
}

@Test func handlesAPIError() throws {
    let json = """
    {"code":401,"msg":"Unauthorized","data":{"limits":[],"level":""},"success":false}
    """

    let snapshot = try GLMQuotaCollector.parseResponse(json)

    #expect(snapshot.error != nil)
    #expect(snapshot.isRefreshFailure)
}

@Test func marksEmptySnapshotsAsRefreshFailures() {
    let errorSnapshot = GLMQuotaSnapshot(generatedAt: Date(), error: "network failed")
    let emptySnapshot = GLMQuotaSnapshot(generatedAt: Date())
    let validSnapshot = GLMQuotaSnapshot(
        generatedAt: Date(),
        timeLimit: GLMQuotaWindow(remainingPercent: 70),
        tokensLimit5: GLMQuotaWindow(remainingPercent: 80),
        tokensLimitWeek: GLMQuotaWindow(remainingPercent: 90)
    )
    let partialSnapshot = GLMQuotaSnapshot(
        generatedAt: Date(),
        timeLimit: GLMQuotaWindow(remainingPercent: 70),
        tokensLimit5: GLMQuotaWindow(remainingPercent: 80)
    )

    #expect(errorSnapshot.isRefreshFailure)
    #expect(emptySnapshot.isRefreshFailure)
    #expect(partialSnapshot.isRefreshFailure)
    #expect(!validSnapshot.isRefreshFailure)
}
