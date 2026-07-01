import Foundation

/// Runtime-editable settings shared by the GUI app and the snapshot tools.
///
/// Proxy and remote-host settings used to be baked into a generated source file
/// at install time, so changing them meant a full rebuild + reinstall. They are
/// pure runtime data, so instead they live in a JSON file at a fixed path that
/// both the unsandboxed app and the unsandboxed snapshot tools read on every
/// refresh. Editing it in the app takes effect on the next refresh — no rebuild.
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

public enum ClaudeQuotaProxyConfig {
    /// Manual proxy override passed to curl via `--proxy`. `nil`/empty means
    /// the collector falls back to the current macOS system proxy.
    public static var proxyURL: String? {
        guard let value = QuotaRuntimeConfigFile.object()["proxyURL"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }
}
