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
