import Combine
import Foundation
import SwiftUI

/// 控制「桌面组件后台刷新」对应的用户级 launchd agent 是否运行。
///
/// 真实 launchd 状态是唯一真相来源（通过 `launchctl print` 判断），
/// 不缓存到 `@AppStorage`，避免与脚本/重启后的实际状态漂移。
/// 所有阻塞型 `Process` 调用都推到主线程之外执行。
@MainActor
final class LaunchAgentController: ObservableObject {
    @Published private(set) var status: AgentStatus = .checking
    @Published private(set) var isRunning = false
    @Published private(set) var isToggling = false
    @Published var lastError: String?

    let label: String
    private let plistPath: String
    private let domain: String  // "gui/<uid>"

    init(label: String, plistPath: String) {
        self.label = label
        self.plistPath = (plistPath as NSString).expandingTildeInPath
        self.domain = "gui/\(getuid())"
    }

    // MARK: - 状态（真实 launchd 状态）

    func refreshStatus() {
        Task {
            await refreshStatusFromLaunchd()
        }
    }

    // MARK: - 开关动作

    func setRunning(_ on: Bool) {
        guard !isToggling else { return }
        isToggling = true
        lastError = nil
        isRunning = on

        let domain = domain
        let label = label
        let plistPath = plistPath

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if on {
                        try Self.enableAgent(domain: domain, label: label, plistPath: plistPath)
                    } else {
                        try Self.disableAgent(domain: domain, label: label)
                    }
                }.value
            } catch {
                lastError = error.localizedDescription
            }
            await refreshStatusFromLaunchd()
            isToggling = false
        }
    }

    private func refreshStatusFromLaunchd() async {
        let domain = domain
        let label = label
        let plistPath = plistPath

        status = .checking
        let resolved = await Task.detached(priority: .userInitiated) { () -> AgentStatus in
            guard FileManager.default.fileExists(atPath: plistPath) else {
                return .notInstalled
            }
            let loaded = Self.run(["print", "\(domain)/\(label)"]).exitCode == 0
            return loaded ? .running : .stopped
        }.value
        status = resolved
        isRunning = resolved == .running
    }
}

// MARK: - launchctl 调用（全部 nonisolated，仅在被 Task.detached 包裹时执行）

private extension LaunchAgentController {
    struct RunResult: Sendable {
        let exitCode: Int
        let combined: String
    }

    nonisolated static func enableAgent(domain: String, label: String, plistPath: String) throws {
        // 幂等：先 bootout 忽略失败，再 bootstrap + kickstart。
        _ = run(["bootout", "\(domain)/\(label)"])

        let bootstrapResult = run(["bootstrap", domain, plistPath])
        // 0 = 成功；133 = 已加载（紧跟 bootout 后通常不会出现，但容错）。
        guard bootstrapResult.exitCode == 0 || bootstrapResult.exitCode == 133 else {
            throw LaunchctlError.bootstrapFailed(bootstrapResult.combined)
        }

        let kickstartResult = run(["kickstart", "-k", "\(domain)/\(label)"])
        guard kickstartResult.exitCode == 0 else {
            throw LaunchctlError.kickstartFailed(kickstartResult.combined)
        }
    }

    nonisolated static func disableAgent(domain: String, label: String) throws {
        let result = run(["bootout", "\(domain)/\(label)"])
        // 「未加载」正是想要的终止状态，容错之。
        if result.exitCode != 0 && !result.combined.lowercased().contains("no such") {
            throw LaunchctlError.bootoutFailed(result.combined)
        }
    }

    nonisolated static func run(_ arguments: [String]) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, combined: error.localizedDescription)
        }
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOut = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(exitCode: Int(process.terminationStatus), combined: output + "\n" + errorOut)
    }
}

// MARK: - 错误与常量

enum LaunchctlError: LocalizedError {
    case bootstrapFailed(String)
    case kickstartFailed(String)
    case bootoutFailed(String)

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let message): return "启动后台刷新失败：\(message)"
        case .kickstartFailed(let message): return "触发后台刷新失败：\(message)"
        case .bootoutFailed(let message):   return "停止后台刷新失败：\(message)"
        }
    }
}

enum LaunchAgentLabels {
    static let codex = (label: "local.codex-quota-dial.refresh",
                        plist: "~/Library/LaunchAgents/local.codex-quota-dial.refresh.plist")
    static let claude = (label: "local.claude-quota-dial.refresh",
                         plist: "~/Library/LaunchAgents/local.claude-quota-dial.refresh.plist")
    static let glm = (label: "local.glm-quota-dial.refresh",
                      plist: "~/Library/LaunchAgents/local.glm-quota-dial.refresh.plist")
    static let antigravity = (label: "local.antigravity-quota-dial.refresh",
                              plist: "~/Library/LaunchAgents/local.antigravity-quota-dial.refresh.plist")
    static let usage = (label: "local.usage-quota-dial.refresh",
                        plist: "~/Library/LaunchAgents/local.usage-quota-dial.refresh.plist")
}
