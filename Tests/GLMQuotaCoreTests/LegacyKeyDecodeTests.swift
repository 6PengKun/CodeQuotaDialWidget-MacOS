import Foundation
import Testing
@testable import GLMQuotaCore

@Suite struct LegacyKeyDecodeTests {
    @Test func decodesOldTokensLimitMonthKeyIntoWeek() throws {
        let oldJSON = """
        {"generatedAt":"2026-01-01T00:00:00Z","timeLimit":{"remainingPercent":70,"usedPercent":30},"tokensLimit5":{"remainingPercent":80,"usedPercent":20},"tokensLimitMonth":{"remainingPercent":90,"usedPercent":10},"level":"pro"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(GLMQuotaSnapshot.self, from: oldJSON)
        #expect(snapshot.tokensLimitWeek?.remainingPercent == 90)
    }

    @Test func prefersNewKeyOverLegacyKey() throws {
        let json = """
        {"generatedAt":"2026-01-01T00:00:00Z","tokensLimit5":{"remainingPercent":80,"usedPercent":20},"tokensLimitWeek":{"remainingPercent":50,"usedPercent":50},"tokensLimitMonth":{"remainingPercent":99,"usedPercent":1}}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(GLMQuotaSnapshot.self, from: json)
        #expect(snapshot.tokensLimitWeek?.remainingPercent == 50)
    }

    @Test func reencodeDoesNotEmitLegacyKey() throws {
        let snapshot = GLMQuotaSnapshot(
            generatedAt: Date(),
            tokensLimit5: GLMQuotaWindow(remainingPercent: 80),
            tokensLimitWeek: GLMQuotaWindow(remainingPercent: 90)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let string = String(data: data, encoding: .utf8) ?? ""
        #expect(!string.contains("tokensLimitMonth"))
        #expect(string.contains("tokensLimitWeek"))
    }
}
