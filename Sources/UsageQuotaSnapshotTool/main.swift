import Foundation
import UsageQuotaCore
import WidgetKit

func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let outputIndex = arguments.firstIndex(of: "--output")

let outputURL: URL
if let outputIndex, arguments.indices.contains(outputIndex + 1) {
    outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
} else {
    outputURL = UsageSnapshotStore.defaultURL()
}

let startedAt = Date()
let formatter = ISO8601DateFormatter()
log("Usage refresh started at \(formatter.string(from: startedAt)) output=\(outputURL.path)")

let snapshot = UsageCollector().collect()
let store = UsageSnapshotStore(url: outputURL)

do {
    try store.save(snapshot)
    WidgetCenter.shared.reloadAllTimelines()
    let finishedAt = Date()
    let duration = String(format: "%.1f", finishedAt.timeIntervalSince(startedAt))
    let status = snapshot.sources?.statusLabel ?? "unknown"
    log("Usage refresh finished at \(formatter.string(from: finishedAt)) duration=\(duration)s status=\(status) output=\(outputURL.path)")
} catch {
    fputs("Failed to save usage snapshot: \(error.localizedDescription)\n", stderr)
    exit(1)
}
