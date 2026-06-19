import Foundation

public struct ClaudeQuotaCollector: Sendable {
    public init() {}

    public func collect(now: Date = Date()) -> ClaudeQuotaSnapshot {
        do {
            return try collectOnce(now: now)
        } catch let error as ClaudeQuotaError where error.isRefreshable {
            // The keychain token is expired or rejected (HTTP 401). Trigger a one-shot
            // `claude -p` so Claude Code refreshes the OAuth token via the long-lived
            // refreshToken and writes it back to the keychain, then retry exactly once.
            // A cooldown prevents respawning `claude` every cycle when refresh is hopeless
            // (e.g. the refreshToken itself was revoked). All steps are logged to stderr,
            // which the LaunchAgent routes to Runtime/claude/logs/refresh.err.log.
            if let last = Self.lastRefreshAttempt() {
                let elapsed = now.timeIntervalSince(last)
                if elapsed < Self.refreshCooldown {
                    let remaining = Int((Self.refreshCooldown - elapsed).rounded())
                    Self.logRefresh("refresh skipped (cooldown, \(remaining)s remaining)")
                    return ClaudeQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
                }
            }

            Self.logRefresh("refresh triggered (reason=\(error.refreshReason))")

            guard Self.refreshCredentialsViaCLI(at: now) else {
                return ClaudeQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
            }

            do {
                let snapshot = try collectOnce(now: now)
                Self.logRefresh("retry after refresh: success")
                return snapshot
            } catch let retryError {
                let label = (retryError as? ClaudeQuotaError)?.shortLabel ?? "error"
                Self.logRefresh("retry after refresh: still failing (\(label))")
                return ClaudeQuotaSnapshot(generatedAt: now, error: retryError.localizedDescription)
            }
        } catch {
            return ClaudeQuotaSnapshot(generatedAt: now, error: error.localizedDescription)
        }
    }

    private func collectOnce(now: Date) throws -> ClaudeQuotaSnapshot {
        let credentials = try Self.readCredentials()
        let responseBody = try fetchQuota(accessToken: credentials.accessToken)
        var snapshot = try Self.parseResponse(responseBody)
        snapshot.planType = credentials.planType
        snapshot.generatedAt = now
        return snapshot
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
            throw ClaudeQuotaError.tokenExpired
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

    static func extractSuccessfulBody(_ output: String) throws -> String {
        guard let markerRange = output.range(of: "\n__HTTP_STATUS__:", options: .backwards) else {
            return output
        }

        let body = String(output[..<markerRange.lowerBound])
        let status = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == "200" else {
            if status == "401" {
                throw ClaudeQuotaError.unauthorized("API error (HTTP 401): \(body)")
            }
            throw ClaudeQuotaError.httpError("API error (HTTP \(status)): \(body)")
        }
        return body
    }

    // MARK: - Credential refresh (via Claude Code CLI)

    /// Cooldown between CLI refresh attempts. Caps wasted `claude` spawns when refresh
    /// can never succeed (e.g. a revoked refreshToken) without delaying normal ~8h expiry.
    private static let refreshCooldown: TimeInterval = 30 * 60

    /// Triggers a one-shot `claude -p` to refresh the keychain OAuth token.
    /// Returns true only if `claude` was found and exited cleanly; the real proof of
    /// success is the caller's retry against the usage endpoint.
    private static func refreshCredentialsViaCLI(at now: Date) -> Bool {
        guard let claudePath = locateClaudeBinary() else {
            logRefresh("claude binary not found (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)")
            return false
        }

        let timeout: TimeInterval = 90
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        // `-p` (non-interactive) refreshes during startup auth and then exits on its own.
        // A bare `claude` would open an interactive TUI and hang here (no TTY in launchd).
        process.arguments = ["-p", "ping"]
        // Detach all streams so a chatty/blocked child can never fill a pipe buffer.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        logRefresh("running: \(claudePath) -p (timeout=\(Int(timeout))s)")
        let start = Date()
        do {
            try process.run()
            recordRefreshAttempt(at: now)
        } catch {
            logRefresh("failed to launch claude: \(error.localizedDescription)")
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(200_000)
        }

        if process.isRunning {
            process.terminate()
            usleep(500_000)
            if process.isRunning {
                process.interrupt()
            }
            logRefresh("claude timed out after \(Int(timeout))s")
            return false
        }

        let elapsed = Date().timeIntervalSince(start)
        let status = process.terminationStatus
        logRefresh(String(format: "claude exited status=%d in %.1fs", status, elapsed))
        return status == 0
    }

    private static func locateClaudeBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Refresh cooldown state

    private static func refreshStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ClaudeQuotaWidget", isDirectory: true)
            .appendingPathComponent("refresh-state.json")
    }

    private static func lastRefreshAttempt() -> Date? {
        guard let data = try? Data(contentsOf: refreshStateURL()),
              let state = try? JSONDecoder().decode([String: Double].self, from: data),
              let ts = state["lastAttemptAt"] else {
            return nil
        }
        return Date(timeIntervalSince1970: ts)
    }

    private static func recordRefreshAttempt(at date: Date) {
        let url = refreshStateURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(["lastAttemptAt": date.timeIntervalSince1970]) {
            try? data.write(to: url)
        }
    }

    // MARK: - Logging

    /// Writes a timestamped line to stderr. The LaunchAgent routes stderr to
    /// Runtime/claude/logs/refresh.err.log for later troubleshooting. Never log tokens.
    private static func logRefresh(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(ts) [claude-refresh] \(message)\n".utf8))
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
    case tokenExpired
    case invalidCredentials(String)
    case unauthorized(String)
    case httpError(String)

    /// Whether a CLI token refresh could plausibly fix this error. Only expiry and
    /// HTTP 401 qualify — `credentialsNotFound` (not logged in) and HTTP 403 (scope)
    /// are never helped by refreshing, so they must not trigger a `claude` spawn.
    var isRefreshable: Bool {
        switch self {
        case .tokenExpired, .unauthorized:
            return true
        default:
            return false
        }
    }

    var refreshReason: String {
        switch self {
        case .tokenExpired: return "token_expired"
        case .unauthorized: return "http_401"
        default: return "unknown"
        }
    }

    var shortLabel: String {
        switch self {
        case .credentialsNotFound: return "credentials_not_found"
        case .tokenExpired: return "token_expired"
        case .invalidCredentials: return "invalid_credentials"
        case .unauthorized: return "http_401"
        case .httpError: return "http_error"
        }
    }

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude Code OAuth credentials not found"
        case .tokenExpired:
            return "OAuth token has expired"
        case .invalidCredentials(let message):
            return message
        case .unauthorized(let message):
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
