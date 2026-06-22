import Foundation
import GLMQuotaCore
import WidgetKit

let arguments = Array(CommandLine.arguments.dropFirst())
let outputIndex = arguments.firstIndex(of: "--output")

let outputURL: URL
if let outputIndex, arguments.indices.contains(outputIndex + 1) {
    outputURL = URL(fileURLWithPath: arguments[outputIndex + 1])
} else {
    outputURL = GLMQuotaSnapshotStore.defaultURL()
}

let snapshot = GLMQuotaCollector().collect()
let store = GLMQuotaSnapshotStore(url: outputURL)

do {
    if snapshot.isRefreshFailure, let previous = try? store.load() {
        let reason = snapshot.error ?? "quota windows not found"
        fputs("Quota refresh failed; keeping previous snapshot from \(previous.generatedAt): \(reason)\n", stderr)
        WidgetCenter.shared.reloadAllTimelines()
        print(outputURL.path)
        exit(0)
    }

    try store.save(snapshot)
    WidgetCenter.shared.reloadAllTimelines()
    print(outputURL.path)
} catch {
    fputs("Failed to save quota snapshot: \(error.localizedDescription)\n", stderr)
    exit(1)
}
