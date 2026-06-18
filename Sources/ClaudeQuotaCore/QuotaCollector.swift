import Foundation

public struct ClaudeQuotaCollector: Sendable {
    public init() {}

    public func collect(now: Date = Date()) -> ClaudeQuotaSnapshot {
        do {
            let credentials = try Self.readCredentials()
            let responseBody = try fetchQuota(accessToken: credentials.accessToken)
            var snapshot = try Self.parseResponse(responseBody)
            snapshot.planType = credentials.planType
            snapshot.generatedAt = now
            return snapshot
        } catch {
            return ClaudeQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
        }
    }

    static func readCredentials() throws -> ClaudeOAuthCredentials {
        guard let credentials = try readCredentialsFromKeychain() else {
            throw ClaudeQuotaError.credentialsNotFound
        }
        return credentials
    }

    private static func readCredentialsFromKeychain() throws -> ClaudeOAuthCredentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return try parseCredentialsData(data)
    }

    static func parseCredentialsData(_ data: Data, now: Date = Date()) throws -> ClaudeOAuthCredentials {
        let credentials = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        guard let entry = credentials.claudeAiOauth ?? credentials.claudeDotAiOauth else {
            throw ClaudeQuotaError.invalidCredentials("OAuth entry not found")
        }
        guard let token = entry.accessToken, !token.isEmpty else {
            throw ClaudeQuotaError.invalidCredentials("accessToken is empty or missing")
        }
        if let expiresAt = entry.expiresAt, expiresAt.date < now {
            throw ClaudeQuotaError.invalidCredentials("OAuth token has expired")
        }
        return ClaudeOAuthCredentials(accessToken: token, planType: entry.subscriptionType)
    }

    private func fetchQuota(accessToken: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = [
            "-s", "-S",
            "--max-time", "15",
            "-w", "\n__HTTP_STATUS__:%{http_code}\n",
            "https://api.anthropic.com/api/oauth/usage",
            "-H", "Authorization: Bearer \(accessToken)",
            "-H", "anthropic-beta: oauth-2025-04-20",
            "-H", "Accept: application/json"
        ]
        if let proxy = ClaudeQuotaProxyConfig.proxyURL, !proxy.isEmpty {
            arguments.append(contentsOf: ["--proxy", proxy])
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw ClaudeQuotaError.httpError("curl exited with status \(process.terminationStatus): \(stderr)")
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        if output.isEmpty {
            throw ClaudeQuotaError.httpError("empty response from Claude API")
        }
        return try Self.extractSuccessfulBody(output)
    }

    private static func extractSuccessfulBody(_ output: String) throws -> String {
        guard let markerRange = output.range(of: "\n__HTTP_STATUS__:", options: .backwards) else {
            return output
        }

        let body = String(output[..<markerRange.lowerBound])
        let status = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == "200" else {
            throw ClaudeQuotaError.httpError("API error (HTTP \(status)): \(body)")
        }
        return body
    }

    public static func parseResponse(_ body: String) throws -> ClaudeQuotaSnapshot {
        guard let data = body.data(using: .utf8) else {
            return ClaudeQuotaSnapshot(generatedAt: Date(), error: "invalid response encoding")
        }

        let envelope = try JSONDecoder().decode(ClaudeUsageEnvelope.self, from: data)

        let snapshot = ClaudeQuotaSnapshot(
            generatedAt: Date(),
            fiveHour: envelope.fiveHour?.window,
            weekly: envelope.sevenDay?.window
        )
        guard snapshot.hasCompleteDisplayData else {
            return ClaudeQuotaSnapshot(
                generatedAt: Date(),
                fiveHour: snapshot.fiveHour,
                weekly: snapshot.weekly,
                planType: snapshot.planType,
                error: "quota windows not found"
            )
        }
        return snapshot
    }
}

struct ClaudeOAuthCredentials: Equatable, Sendable {
    var accessToken: String
    var planType: String?
}

private enum ClaudeQuotaError: Error, LocalizedError {
    case credentialsNotFound
    case invalidCredentials(String)
    case httpError(String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude Code OAuth credentials not found"
        case .invalidCredentials(let message):
            return message
        case .httpError(let message):
            return message
        }
    }
}

private struct ClaudeCredentials: Decodable {
    var claudeAiOauth: ClaudeOAuthEntry?
    var claudeDotAiOauth: ClaudeOAuthEntry?

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth
        case claudeDotAiOauth = "claude.ai_oauth"
    }
}

private struct ClaudeOAuthEntry: Decodable {
    var accessToken: String?
    var expiresAt: FlexibleExpiration?
    var subscriptionType: String?
}

struct FlexibleExpiration: Decodable {
    var date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Int64.self) {
            let seconds = milliseconds > 1_000_000_000_000 ? TimeInterval(milliseconds) / 1000.0 : TimeInterval(milliseconds)
            self.date = Date(timeIntervalSince1970: seconds)
            return
        }
        if let string = try? container.decode(String.self) {
            if let date = parseISO8601Date(string) {
                self.date = date
                return
            }
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported expiration format")
    }
}

private struct ClaudeUsageEnvelope: Decodable {
    var fiveHour: ClaudeUsageWindow?
    var sevenDay: ClaudeUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeUsageWindow: Decodable {
    var utilization: Double?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
        if let resetString = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = parseISO8601Date(resetString)
        } else {
            resetsAt = nil
        }
    }

    var window: ClaudeQuotaWindow? {
        guard let utilization else {
            return nil
        }
        let used = max(0, min(100, Int(utilization.rounded())))
        return ClaudeQuotaWindow(
            remainingPercent: max(0, min(100, 100 - used)),
            usedPercent: used,
            resetsAt: resetsAt
        )
    }
}

private func parseISO8601Date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
        return date
    }

    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
}
