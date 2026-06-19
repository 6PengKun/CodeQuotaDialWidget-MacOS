import Foundation

public struct AntigravityQuotaCollector: Sendable {
    private static let maxCandidatePorts = 8

    public init() {}

    public func collect(now: Date = Date()) -> AntigravityQuotaSnapshot {
        do {
            let process = try Self.detectAntigravityProcess()
            let ports = try Self.candidatePorts(for: process)
            let endpoint = try Self.detectConnectEndpoint(ports: ports, csrfToken: process.csrfToken)
            let responseBody = try Self.fetchUserStatus(endpoint: endpoint, csrfToken: process.csrfToken)
            var snapshot = try Self.parseUserStatusResponse(responseBody)
            snapshot.generatedAt = now
            return snapshot
        } catch {
            return AntigravityQuotaSnapshot(generatedAt: now, method: "local", error: error.localizedDescription)
        }
    }

    public static func parseUserStatusResponse(_ body: String, now: Date = Date()) throws -> AntigravityQuotaSnapshot {
        guard let data = body.data(using: .utf8) else {
            return AntigravityQuotaSnapshot(generatedAt: now, method: "local", error: "invalid response encoding")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let envelope = object as? [String: Any] else {
            return AntigravityQuotaSnapshot(generatedAt: now, method: "local", error: "invalid response shape")
        }

        let userStatus = envelope["userStatus"] as? [String: Any] ?? envelope
        let email = userStatus["email"] as? String
        let planType = parsePlanType(from: userStatus)
        let models = parseModels(from: userStatus)

        let snapshot = AntigravityQuotaSnapshot(
            generatedAt: now,
            method: "local",
            email: email,
            planType: planType,
            models: models
        )
        guard snapshot.hasCompleteDisplayData else {
            return AntigravityQuotaSnapshot(
                generatedAt: now,
                method: "local",
                email: email,
                planType: planType,
                models: models,
                error: "target model quotas not found"
            )
        }
        return snapshot
    }

    static func parsePlanType(from userStatus: [String: Any]) -> String? {
        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let currentTier = userStatus["currentTier"] as? [String: Any]
            ?? planStatus?["currentTier"] as? [String: Any]

        return firstString(in: planInfo, keys: ["planType", "planName", "name"])
            ?? firstString(in: currentTier, keys: ["name", "id", "description"])
    }

    private static func firstString(in dictionary: [String: Any]?, keys: [String]) -> String? {
        guard let dictionary else {
            return nil
        }
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func parseModels(from userStatus: [String: Any]) -> [AntigravityModelQuota] {
        guard
            let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any],
            let clientModelConfigs = cascadeData["clientModelConfigs"] as? [[String: Any]]
        else {
            return []
        }

        var bestByFamily: [AntigravityModelFamily: AntigravityModelQuota] = [:]

        for config in clientModelConfigs {
            guard let quota = parseModel(config) else {
                continue
            }
            if let existing = bestByFamily[quota.family] {
                bestByFamily[quota.family] = betterModel(existing, quota)
            } else {
                bestByFamily[quota.family] = quota
            }
        }

        return AntigravityModelFamily.allCases.compactMap { bestByFamily[$0] }
    }

    static func parseModel(_ config: [String: Any]) -> AntigravityModelQuota? {
        let modelOrAlias = config["modelOrAlias"] as? [String: Any]
        let modelId = modelOrAlias?["model"] as? String ?? config["model"] as? String ?? "unknown"
        let label = config["label"] as? String ?? config["displayName"] as? String ?? modelId
        let searchable = "\(modelId) \(label)".lowercased()

        guard !shouldSkipModel(searchable) else {
            return nil
        }
        guard let family = family(for: searchable) else {
            return nil
        }

        let quotaInfo = config["quotaInfo"] as? [String: Any]
        let remainingPercent = percent(fromFraction: quotaInfo?["remainingFraction"])
        let usedPercent = remainingPercent.map { max(0, min(100, 100 - $0)) }
        let resetTime = quotaInfo?["resetTime"] as? String
        let isExhausted = quotaInfo?["isExhausted"] as? Bool ?? (remainingPercent == 0)

        return AntigravityModelQuota(
            family: family,
            label: label,
            modelId: modelId,
            remainingPercent: remainingPercent,
            usedPercent: usedPercent,
            resetsAt: resetTime.flatMap(parseDate),
            isExhausted: isExhausted
        )
    }

    private static func shouldSkipModel(_ searchable: String) -> Bool {
        if searchable.contains("tab_") || searchable.contains("chat_") {
            return true
        }
        if searchable.contains("image") || searchable.contains("lite") || searchable.contains("mquery") {
            return true
        }
        if searchable.contains("autocomplete") || searchable.contains("gemini-2.5") {
            return true
        }
        return false
    }

    private static func family(for searchable: String) -> AntigravityModelFamily? {
        if searchable.contains("opus") {
            return .opus
        }
        if searchable.contains("sonnet") {
            return .sonnet
        }
        if searchable.contains("gemini") && searchable.contains("pro") {
            return .pro
        }
        if searchable.contains("gemini") && searchable.contains("flash") {
            return .flash
        }
        return nil
    }

    private static func betterModel(_ lhs: AntigravityModelQuota, _ rhs: AntigravityModelQuota) -> AntigravityModelQuota {
        switch (lhs.remainingPercent, rhs.remainingPercent) {
        case let (left?, right?):
            return right < left ? rhs : lhs
        case (nil, _?):
            return rhs
        default:
            return lhs
        }
    }

    private static func percent(fromFraction value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }
        return max(0, min(100, Int((number.doubleValue * 100).rounded())))
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension AntigravityQuotaCollector {
    struct ProcessInfo {
        var pid: Int32
        var csrfToken: String?
        var extensionServerPort: Int?
    }

    struct Endpoint {
        var baseURL: String
        var isHTTPS: Bool
    }

    static func detectAntigravityProcess() throws -> ProcessInfo {
        let output = try runProcess(
            executable: "/usr/bin/pgrep",
            arguments: ["-afil", "antigravity"],
            allowNonZeroExit: true
        )
        for line in output.split(separator: "\n") {
            let text = String(line)
            let lower = text.lowercased()
            guard isLikelyAntigravityProcess(lower) else {
                continue
            }
            guard lower.contains("language-server")
                || lower.contains("lsp")
                || lower.contains("--csrf_token")
                || lower.contains("--extension_server_port")
                || lower.contains("exa.language_server_pb")
            else {
                continue
            }

            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else {
                continue
            }
            let commandLine = String(parts[1])
            return ProcessInfo(
                pid: pid,
                csrfToken: extractArgument("--csrf_token", from: commandLine),
                extensionServerPort: extractArgument("--extension_server_port", from: commandLine).flatMap(Int.init)
            )
        }
        throw AntigravityQuotaError.localProcessNotFound
    }

    static func isLikelyAntigravityProcess(_ lowercasedCommandLine: String) -> Bool {
        if lowercasedCommandLine.contains("antigravityquotasnapshottool")
            || lowercasedCommandLine.contains("codequotadialwidget")
            || lowercasedCommandLine.contains("/.codex/")
            || lowercasedCommandLine.contains("codex ") {
            return false
        }
        return lowercasedCommandLine.contains("antigravity.app")
            || lowercasedCommandLine.contains("/antigravity/")
            || lowercasedCommandLine.contains("/antigravity ")
    }

    static func candidatePorts(for process: ProcessInfo) throws -> [Int] {
        var ports: [Int] = []
        if let extensionServerPort = process.extensionServerPort {
            ports.append(extensionServerPort)
            return ports
        }

        let lsof = try? runProcess(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(process.pid)"])
        for line in (lsof ?? "").split(separator: "\n") {
            guard let range = line.range(of: #"(?<=:)\d+(?=\s+\(LISTEN\))"#, options: .regularExpression) else {
                continue
            }
            if let port = Int(line[range]), !ports.contains(port) {
                ports.append(port)
            }
            if ports.count >= maxCandidatePorts {
                break
            }
        }

        guard !ports.isEmpty else {
            throw AntigravityQuotaError.localPortNotFound
        }
        return ports
    }

    static func detectConnectEndpoint(ports: [Int], csrfToken: String?) throws -> Endpoint {
        for port in ports {
            if probe(port: port, isHTTPS: true, csrfToken: csrfToken) {
                return Endpoint(baseURL: "https://127.0.0.1:\(port)", isHTTPS: true)
            }
            if probe(port: port, isHTTPS: false, csrfToken: csrfToken) {
                return Endpoint(baseURL: "http://127.0.0.1:\(port)", isHTTPS: false)
            }
        }
        throw AntigravityQuotaError.connectEndpointNotFound
    }

    static func probe(port: Int, isHTTPS: Bool, csrfToken: String?) -> Bool {
        let body = #"{"wrapper_data":{}}"#
        let result = request(
            endpoint: Endpoint(baseURL: "\(isHTTPS ? "https" : "http")://127.0.0.1:\(port)", isHTTPS: isHTTPS),
            path: "/exa.language_server_pb.LanguageServerService/GetUnleashData",
            body: body,
            csrfToken: csrfToken,
            timeout: 0.25
        )
        switch result {
        case let .success((status, _)):
            return status == 200 || status == 401
        case .failure:
            return false
        }
    }

    static func fetchUserStatus(endpoint: Endpoint, csrfToken: String?) throws -> String {
        let body = #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#
        let result = request(
            endpoint: endpoint,
            path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
            body: body,
            csrfToken: csrfToken,
            timeout: 5
        )
        switch result {
        case let .success((status, response)):
            guard status >= 200 && status < 300 else {
                throw AntigravityQuotaError.localHTTPError("HTTP \(status): \(response)")
            }
            return response
        case let .failure(error):
            throw error
        }
    }

    static func request(
        endpoint: Endpoint,
        path: String,
        body: String,
        csrfToken: String?,
        timeout: TimeInterval
    ) -> Result<(Int, String), Error> {
        var arguments = [
            "-s", "-S",
            "--noproxy", "127.0.0.1,localhost,::1",
            "--connect-timeout", "\(timeout)",
            "--max-time", "\(timeout)",
            "-w", "\n__HTTP_STATUS__:%{http_code}\n",
            "-X", "POST",
            endpoint.baseURL + path,
            "-H", "Accept: application/json",
            "-H", "Content-Type: application/json",
            "-H", "Connect-Protocol-Version: 1",
            "--data", body
        ]
        if endpoint.isHTTPS {
            arguments.insert("-k", at: 0)
        }
        if let csrfToken, !csrfToken.isEmpty {
            arguments.append(contentsOf: ["-H", "X-Codeium-Csrf-Token: \(csrfToken)"])
        }

        do {
            let output = try runProcess(
                executable: "/usr/bin/curl",
                arguments: arguments,
                timeout: timeout + 1,
                allowNonZeroExit: true
            )
            guard let markerRange = output.range(of: "\n__HTTP_STATUS__:", options: .backwards) else {
                return .failure(AntigravityQuotaError.localHTTPError("missing HTTP status"))
            }
            let responseBody = String(output[..<markerRange.lowerBound])
            let statusText = output[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let status = Int(statusText), status > 0 else {
                return .failure(AntigravityQuotaError.localHTTPError("local request failed"))
            }
            return .success((status, responseBody))
        } catch {
            return .failure(error)
        }
    }

    static func extractArgument(_ name: String, from commandLine: String) -> String? {
        let patterns = [
            "\(name)=([^\\s]+)",
            "\(name)\\s+([^\\s]+)"
        ]
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: commandLine, range: NSRange(commandLine.startIndex..., in: commandLine)),
                let range = Range(match.range(at: 1), in: commandLine)
            else {
                continue
            }
            return String(commandLine[range])
        }
        return nil
    }

    static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 3,
        allowNonZeroExit: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        try process.run()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw AntigravityQuotaError.localHTTPError("\(executable) timed out")
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard allowNonZeroExit || process.terminationStatus == 0 else {
            throw AntigravityQuotaError.localHTTPError("\(executable) exited with status \(process.terminationStatus): \(errorOutput)")
        }
        return output + errorOutput
    }
}

private enum AntigravityQuotaError: Error, LocalizedError {
    case localProcessNotFound
    case localPortNotFound
    case connectEndpointNotFound
    case localHTTPError(String)

    var errorDescription: String? {
        switch self {
        case .localProcessNotFound:
            return "Antigravity language server process not found"
        case .localPortNotFound:
            return "Antigravity local server port not found"
        case .connectEndpointNotFound:
            return "Antigravity local Connect endpoint not found"
        case .localHTTPError(let message):
            return message
        }
    }
}
