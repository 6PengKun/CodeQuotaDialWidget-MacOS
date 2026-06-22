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

public enum CodexQuotaProxyConfig {
    /// Proxy URL passed to curl via `--proxy`. `nil`/empty means a direct call.
    public static var proxyURL: String? {
        guard let value = QuotaRuntimeConfigFile.object()["proxyURL"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
