import Foundation

public struct AntigravityQuotaSnapshotStore: Sendable {
    public static let fileName = "antigravity_quota_snapshot.json"
    public static let appGroupIdentifier = AntigravityQuotaAppGroup.identifier

    public var url: URL

    public init(url: URL = AntigravityQuotaSnapshotStore.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL.appendingPathComponent(fileName)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func load() throws -> AntigravityQuotaSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AntigravityQuotaSnapshot.self, from: data)
    }

    public func save(_ snapshot: AntigravityQuotaSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
