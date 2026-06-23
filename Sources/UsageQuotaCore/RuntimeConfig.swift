import Foundation

/// Runtime-editable settings shared by the GUI app and the snapshot tools.
/// See ClaudeQuotaCore/RuntimeConfig.swift for the rationale; the file is the
/// same one across every widget so a single in-app edit covers them all.
enum QuotaRuntimeConfigFile {
    /// `~/Library/Application Support/CodeQuotaDial/runtime-config.json`.
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodeQuotaDial", isDirectory: true)
        .appendingPathComponent("runtime-config.json")

    static func object() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}

public enum UsageRemoteConfig {
    /// SSH hosts for joint multi-end statistics. Empty = local only. Hosts still
    /// need passwordless SSH set up on this machine; this list only chooses which.
    public static var remoteHosts: [String] {
        guard let raw = QuotaRuntimeConfigFile.object()["remoteHosts"] as? [String] else { return [] }
        return raw
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum UsageZCodeConfig {
    /// Local-only extension for ZCode usage. Missing config defaults to enabled
    /// so an existing local ZCode install appears automatically.
    public static var enabled: Bool {
        guard let value = QuotaRuntimeConfigFile.object()["zcodeUsageEnabled"] else { return true }
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "enabled": return true
            case "0", "false", "no", "disabled": return false
            default: return true
            }
        }
        return true
    }
}

public enum UsageProxyConfig {
    /// Proxy URL passed to curl for optional online model pricing refresh.
    public static var proxyURL: String? {
        guard let value = QuotaRuntimeConfigFile.object()["proxyURL"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
