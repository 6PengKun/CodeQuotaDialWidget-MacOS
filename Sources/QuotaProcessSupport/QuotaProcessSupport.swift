import Foundation

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
    public static func run(_ process: Process) throws -> QuotaProcessResult {
        let outputPipe = (process.standardOutput as? Pipe) ?? Pipe()
        let errorPipe = (process.standardError as? Pipe) ?? Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
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
