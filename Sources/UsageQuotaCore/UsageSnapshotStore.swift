import Foundation

public struct UsageSnapshotStore: Sendable {
    public static let fileName = "usage_quota_snapshot.json"
    public static let appGroupIdentifier = UsageQuotaAppGroup.identifier

    public var url: URL

    public init(url: URL = UsageSnapshotStore.defaultURL()) {
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

    public func load() throws -> UsageSnapshot {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(UsageSnapshot.self, from: data)
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try Self.encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
