import Foundation
import QuotaProcessSupport

public struct GLMQuotaCollector: Sendable {

    public init() {}

    public func collect(now: Date = Date()) -> GLMQuotaSnapshot {
        do {
            let config = try GLMConfig.load()
            let responseBody = try fetchQuota(apiKey: config.apiKey)
            var snapshot = try Self.parseResponse(responseBody)
            snapshot.generatedAt = now
            return snapshot
        } catch {
            return GLMQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
        }
    }

    private func fetchQuota(apiKey: String) throws -> String {
        var configLines = [
            "silent",
            "show-error",
            QuotaProcessSupport.curlConfigLine("max-time", "30"),
            QuotaProcessSupport.curlConfigLine("url", "https://open.bigmodel.cn/api/monitor/usage/quota/limit"),
            QuotaProcessSupport.curlConfigLine("header", "Authorization: \(apiKey)"),
            QuotaProcessSupport.curlConfigLine("header", "Accept-Language: en-US,en"),
            QuotaProcessSupport.curlConfigLine("header", "Content-Type: application/json")
        ]
        if let proxy = GLMQuotaProxyConfig.proxyURL, !proxy.isEmpty {
            configLines.append(QuotaProcessSupport.curlConfigLine("proxy", proxy))
        }

        let configURL = try QuotaProcessSupport.writeCurlConfig(configLines)
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-K", configURL.path]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let result = try QuotaProcessSupport.run(process)

        guard result.status == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? "unknown error"
            throw GLMQuotaError.httpError("curl exited with status \(result.status): \(stderr)")
        }

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        if output.isEmpty {
            throw GLMQuotaError.httpError("empty response from GLM API")
        }
        return output
    }

    public static func parseResponse(_ body: String) throws -> GLMQuotaSnapshot {
        guard let data = body.data(using: .utf8) else {
            return GLMQuotaSnapshot(generatedAt: Date(), error: "invalid response encoding")
        }

        let envelope = try JSONDecoder().decode(GLMEnvelope.self, from: data)

        guard envelope.success, envelope.code == 200 else {
            return GLMQuotaSnapshot(generatedAt: Date(), error: "API error: \(envelope.msg)")
        }

        var timeLimit: GLMQuotaWindow?
        var tokensLimit5: GLMQuotaWindow?
        var tokensLimitWeek: GLMQuotaWindow?

        for item in envelope.data.limits {
            let resetsAt = item.nextResetTime.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            let usedPercent = max(0, min(100, item.percentage))
            let remainingPercent = max(0, min(100, 100 - usedPercent))

            let window = GLMQuotaWindow(
                remainingPercent: remainingPercent,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                usage: item.usage,
                remaining: item.remaining,
                total: item.total
            )

            switch item.type {
            case "TIME_LIMIT":
                timeLimit = window
            case "TOKENS_LIMIT":
                switch item.unit {
                case 3:
                    tokensLimit5 = window
                case 6:
                    tokensLimitWeek = window
                default:
                    break
                }
            default:
                break
            }
        }

        return GLMQuotaSnapshot(
            generatedAt: Date(),
            timeLimit: timeLimit,
            tokensLimit5: tokensLimit5,
            tokensLimitWeek: tokensLimitWeek,
            level: envelope.data.level
        )
    }

}

private enum GLMQuotaError: Error, LocalizedError {
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let message):
            return message
        }
    }
}

private struct GLMEnvelope: Decodable {
    var code: Int
    var msg: String
    var data: GLMData
    var success: Bool
}

private struct GLMData: Decodable {
    var limits: [GLMLimitItem]
    var level: String
}

private struct GLMLimitItem: Decodable {
    var type: String
    var unit: Int?
    var number: Int?
    var usage: Int?
    var currentValue: Int?
    var remaining: Int?
    var percentage: Int
    var nextResetTime: Int64?
    var total: Int?
    var usageDetails: [GLMUsageDetail]?

    enum CodingKeys: String, CodingKey {
        case type, unit, number, usage
        case currentValue, remaining, percentage
        case nextResetTime, total, usageDetails
    }
}

private struct GLMUsageDetail: Decodable {
    var modelCode: String
    var usage: Int
}
