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

public enum GLMQuotaProxyConfig {
    /// Manual proxy override passed to curl via `--proxy`. `nil`/empty means
    /// the collector falls back to the current macOS system proxy.
    public static var proxyURL: String? {
        guard let value = QuotaRuntimeConfigFile.object()["proxyURL"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}

public enum GLMQuotaApiKeyConfig {
    /// GLM API key, set in the GLM panel and stored in the shared runtime config.
    /// `nil`/empty means not configured here (caller falls back to the legacy file).
    public static var apiKey: String? {
        guard let value = QuotaRuntimeConfigFile.object()["glmApiKey"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
