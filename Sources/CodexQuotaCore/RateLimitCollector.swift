import Foundation
import QuotaProcessSupport

public struct CodexQuotaCollector: Sendable {
    public init() {}

    public func collect(now: Date = Date()) -> CodexQuotaSnapshot {
        do {
            let credentials = try Self.readCredentials()
            let responseBody = try fetchQuota(credentials: credentials)
            var snapshot = try Self.parseUsageResponse(responseBody)
            snapshot.generatedAt = now
            return snapshot
        } catch {
            return CodexQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
        }
    }

    static func readCredentials() throws -> CodexCredentials {
        if let credentials = try readCredentialsFromKeychain() {
            return credentials
        }
        return try readCredentialsFromFile()
    }

    private static func readCredentialsFromKeychain() throws -> CodexCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Codex Auth", "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let result = try QuotaProcessSupport.run(process)

        guard result.status == 0 else {
            return nil
        }

        guard !result.stdout.isEmpty else {
            return nil
        }
        return try parseCredentialsData(result.stdout)
    }

    private static func readCredentialsFromFile() throws -> CodexCredentials {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw CodexQuotaError.credentialsNotFound
        }

        let data = try Data(contentsOf: authURL)
        return try parseCredentialsData(data)
    }

    static func parseCredentialsData(_ data: Data) throws -> CodexCredentials {
        let auth = try JSONDecoder().decode(CodexAuth.self, from: data)
        guard auth.authMode == "chatgpt" else {
            throw CodexQuotaError.invalidCredentials("Codex is not using ChatGPT OAuth mode")
        }
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexQuotaError.invalidCredentials("access_token is empty or missing")
        }
        return CodexCredentials(accessToken: accessToken, accountId: auth.tokens?.accountId)
    }

    private func fetchQuota(credentials: CodexCredentials) throws -> String {
        var configLines = [
            "silent",
            "show-error",
            QuotaProcessSupport.curlConfigLine("max-time", "15"),
            QuotaProcessSupport.curlConfigLine("write-out", "\n__HTTP_STATUS__:%{http_code}\n"),
            QuotaProcessSupport.curlConfigLine("url", "https://chatgpt.com/backend-api/wham/usage"),
            QuotaProcessSupport.curlConfigLine("header", "Authorization: Bearer \(credentials.accessToken)"),
            QuotaProcessSupport.curlConfigLine("header", "User-Agent: codex-cli"),
            QuotaProcessSupport.curlConfigLine("header", "Accept: application/json")
        ]
        if let proxy = QuotaProxyResolver.curlProxy(
            for: "https://chatgpt.com/backend-api/wham/usage",
            manualOverride: CodexQuotaProxyConfig.proxyURL
        ) {
            configLines.append(QuotaProcessSupport.curlConfigLine("proxy", proxy))
        }
        if let accountId = credentials.accountId, !accountId.isEmpty {
            configLines.append(QuotaProcessSupport.curlConfigLine("header", "ChatGPT-Account-Id: \(accountId)"))
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
            throw CodexQuotaError.httpError("curl exited with status \(result.status): \(stderr)")
        }

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        if output.isEmpty {
            throw CodexQuotaError.httpError("empty response from Codex API")
        }
        return try Self.extractSuccessfulBody(output)
    }

    public static func parseUsageResponse(_ body: String) throws -> CodexQuotaSnapshot {
        guard let data = body.data(using: .utf8) else {
            return CodexQuotaSnapshot(generatedAt: Date(), error: "invalid response encoding")
        }

        let envelope = try JSONDecoder().decode(CodexUsageEnvelope.self, from: data)

        var fiveHour: CodexQuotaWindow?
        var weekly: CodexQuotaWindow?
        var monthly: CodexQuotaWindow?

        if envelope.planType?.lowercased() == "free" {
            // 免费版只有一个窗口（主窗口），直接当作 30 天额度，不依赖时长容差。
            monthly = envelope.rateLimit?.primaryWindow?.window
        } else {
            let windows = [
                envelope.rateLimit?.primaryWindow,
                envelope.rateLimit?.secondaryWindow
            ].compactMap { $0?.window }

            for window in windows {
                guard let duration = window.windowDurationMins else { continue }
                if abs(duration - 300) <= 30 {
                    fiveHour = window
                } else if abs(duration - 10_080) <= 120 {
                    weekly = window
                }
            }
        }

        let snapshot = CodexQuotaSnapshot(
            generatedAt: Date(),
            fiveHour: fiveHour,
            weekly: weekly,
            monthly: monthly,
            planType: envelope.planType
        )
        guard snapshot.hasCompleteDisplayData else {
            return CodexQuotaSnapshot(
                generatedAt: Date(),
                fiveHour: fiveHour,
                weekly: weekly,
                monthly: monthly,
                planType: envelope.planType,
                error: "quota windows not found"
            )
        }
        return snapshot
    }

    private static func extractSuccessfulBody(_ output: String) throws -> String {
        guard let markerRange = output.range(of: "\n__HTTP_STATUS__:", options: .backwards) else {
            return output
        }

        let body = String(output[..<markerRange.lowerBound])
        let status = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == "200" else {
            throw CodexQuotaError.httpError("API error (HTTP \(status)): \(body)")
        }
        return body
    }

}

struct CodexCredentials: Equatable, Sendable {
    var accessToken: String
    var accountId: String?
}

private enum CodexQuotaError: Error, LocalizedError {
    case credentialsNotFound
    case invalidCredentials(String)
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Codex OAuth credentials not found"
        case .invalidCredentials(let message):
            return message
        case .httpError(let message):
            return message
        }
    }
}

private struct CodexAuth: Decodable {
    var authMode: String?
    var tokens: CodexTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

private struct CodexTokens: Decodable {
    var accessToken: String?
    var accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountId = "account_id"
    }
}

private struct CodexUsageEnvelope: Decodable {
    var planType: String?
    var rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

private struct CodexRateLimit: Decodable {
    var primaryWindow: CodexRateLimitWindow?
    var secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateLimitWindow: Decodable {
    var usedPercent: Double?
    var limitWindowSeconds: Int?
    var resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    var window: CodexQuotaWindow? {
        guard let usedPercent else {
            return nil
        }
        let used = max(0, min(100, Int(usedPercent.rounded())))
        let windowDurationMins = limitWindowSeconds.map { $0 / 60 }
        return CodexQuotaWindow(
            remainingPercent: max(0, min(100, 100 - used)),
            usedPercent: used,
            resetsAt: resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowDurationMins: windowDurationMins
        )
    }
}
