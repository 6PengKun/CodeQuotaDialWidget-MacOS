import Foundation

/// Reads and writes the runtime-editable settings shared with the snapshot
/// tools and the in-process collectors (proxy URL + remote SSH hosts).
///
/// The file lives at a fixed path outside any app-group container because both
/// this (unsandboxed) app and the (unsandboxed) snapshot tools need it, and the
/// tools belong to five different app groups. Editing it here takes effect on
/// the next refresh — the cores re-read the file on every collect — so the proxy
/// and remote hosts no longer require a rebuild/reinstall to change.
struct RuntimeConfig: Equatable {
    var proxyURL: String
    var remoteHosts: [String]
    var glmApiKey: String
    var zcodeUsageEnabled: Bool

    static let empty = RuntimeConfig(proxyURL: "", remoteHosts: [], glmApiKey: "", zcodeUsageEnabled: true)
}

enum RuntimeConfigStore {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodeQuotaDial", isDirectory: true)
        .appendingPathComponent("runtime-config.json")

    static func load() -> RuntimeConfig {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .empty }

        let proxy = (object["proxyURL"] as? String) ?? ""
        let hosts = (object["remoteHosts"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let glmApiKey = ((object["glmApiKey"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let zcodeUsageEnabled = (object["zcodeUsageEnabled"] as? Bool) ?? true
        return RuntimeConfig(
            proxyURL: proxy,
            remoteHosts: hosts,
            glmApiKey: glmApiKey,
            zcodeUsageEnabled: zcodeUsageEnabled
        )
    }

    static func save(_ config: RuntimeConfig) throws {
        let object: [String: Any] = [
            "proxyURL": config.proxyURL.trimmingCharacters(in: .whitespaces),
            "remoteHosts": config.remoteHosts
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            "glmApiKey": config.glmApiKey.trimmingCharacters(in: .whitespaces),
            "zcodeUsageEnabled": config.zcodeUsageEnabled
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
