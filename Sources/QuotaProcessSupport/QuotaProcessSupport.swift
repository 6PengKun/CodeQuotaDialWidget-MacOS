import Foundation

public struct SnapshotStore<Snapshot: Codable & Sendable>: Sendable {
    public typealias DecoderFactory = @Sendable () -> JSONDecoder
    public typealias EncoderFactory = @Sendable () -> JSONEncoder

    public var url: URL

    private let makeDecoder: DecoderFactory
    private let makeEncoder: EncoderFactory

    public init(url: URL) {
        self.init(
            url: url,
            makeDecoder: Self.makeISO8601Decoder,
            makeEncoder: Self.makeISO8601Encoder
        )
    }

    public init(
        url: URL,
        makeDecoder: @escaping DecoderFactory
    ) {
        self.init(
            url: url,
            makeDecoder: makeDecoder,
            makeEncoder: Self.makeISO8601Encoder
        )
    }

    public init(
        url: URL,
        makeDecoder: @escaping DecoderFactory,
        makeEncoder: @escaping EncoderFactory
    ) {
        self.url = url
        self.makeDecoder = makeDecoder
        self.makeEncoder = makeEncoder
    }

    public static func defaultURL(fileName: String, appGroupIdentifier: String) -> URL {
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return appGroupURL.appendingPathComponent(fileName)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func load() throws -> Snapshot {
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(Snapshot.self, from: data)
    }

    public func save(_ snapshot: Snapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try makeEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private static func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public struct QuotaProcessResult: Sendable {
    public var status: Int
    public var stdout: Data
    public var stderr: Data

    public init(status: Int, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}

public enum QuotaProcessSupport {
    /// Environment for child processes: the parent's env with a PATH that
    /// prepends the same node/npm/ccusage dirs the LaunchAgent plist already
    /// sets. GUI hosts (the Xcode app) inherit a minimal system PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits Homebrew and user-local
    /// dirs, so `#!/usr/bin/env node` scripts like npx fail even though npx
    /// itself was located. Prepending the baseline fixes that everywhere we
    /// spawn. Under the LaunchAgent the PATH is already full, so this is
    /// additive (dedup, no behavior change).
    public static func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Keep this list in sync with the PATH in local.*-quota-dial.refresh.plist.
        let baseline = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let inherited = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        let deduped = (baseline + inherited).filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = deduped.joined(separator: ":")
        return env
    }

    public static func run(_ process: Process) throws -> QuotaProcessResult {
        let outputPipe = (process.standardOutput as? Pipe) ?? Pipe()
        let errorPipe = (process.standardError as? Pipe) ?? Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if process.environment == nil {
            process.environment = Self.mergedEnvironment()
        }
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "quota.process.read", attributes: .concurrent)

        try process.run()
        drain(outputPipe, into: outputBox, group: readGroup, queue: readQueue)
        drain(errorPipe, into: errorBox, group: readGroup, queue: readQueue)
        process.waitUntilExit()
        readGroup.wait()

        return QuotaProcessResult(
            status: Int(process.terminationStatus),
            stdout: outputBox.value,
            stderr: errorBox.value
        )
    }

    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) throws -> QuotaProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Self.mergedEnvironment()
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBox = DataBox()
        let errorBox = DataBox()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "quota.process.read", attributes: .concurrent)

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        try process.run()
        drain(outputPipe, into: outputBox, group: readGroup, queue: readQueue)
        drain(errorPipe, into: errorBox, group: readGroup, queue: readQueue)

        if let timeout, semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = readGroup.wait(timeout: .now() + 5)
            throw QuotaProcessError.timedOut(executable)
        }

        if timeout == nil {
            process.waitUntilExit()
        }
        readGroup.wait()

        return QuotaProcessResult(
            status: Int(process.terminationStatus),
            stdout: outputBox.value,
            stderr: errorBox.value
        )
    }

    public static func writeCurlConfig(_ lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codequota-curl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("curl.conf")
        let data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func curlConfigLine(_ name: String, _ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(name) = \"\(escaped)\""
    }

    private static func drain(
        _ pipe: Pipe?,
        into box: DataBox,
        group: DispatchGroup,
        queue: DispatchQueue
    ) {
        guard let handle = pipe?.fileHandleForReading else { return }
        queue.async(group: group) {
            box.value = handle.readDataToEndOfFile()
        }
    }
}

public enum QuotaProcessError: LocalizedError {
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executable):
            return "\(executable) timed out"
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
