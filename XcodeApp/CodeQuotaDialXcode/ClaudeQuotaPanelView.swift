import ClaudeQuotaCore
import SwiftUI
import WidgetKit

struct ClaudeQuotaPanelView: View {
    @State private var snapshot: ClaudeQuotaSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @StateObject private var agent = LaunchAgentController(
        label: LaunchAgentLabels.claude.label,
        plistPath: LaunchAgentLabels.claude.plist
    )

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude 额度")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(snapshot.map { "更新 \(timeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LaunchAgentToggleRow(controller: agent)

            HStack(spacing: Theme.cardSpacing) {
                QuotaStatCard(title: "5h", model: QuotaStatModel(snapshot?.fiveHour))
                QuotaStatCard(title: "本周", model: QuotaStatModel(snapshot?.weekly))
            }

            if let message = errorText ?? agent.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            HStack {
                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("刷新额度")
                    }
                }
                .disabled(isRefreshing)

                Spacer()

                Text("桌面组件每 2 分钟读取快照")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            loadSnapshot()
            agent.refreshStatus()
        }
    }

    private func loadSnapshot() {
        do {
            snapshot = try ClaudeQuotaSnapshotStore().load()
            errorText = snapshot?.error
        } catch {
            errorText = "暂无额度快照，请先刷新。"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            ClaudeQuotaCollector().collect()
        }.value

        do {
            let store = ClaudeQuotaSnapshotStore()

            if newSnapshot.isRefreshFailure, let previous = snapshot ?? (try? store.load()) {
                let reason = newSnapshot.error ?? "未返回额度窗口"
                snapshot = previous
                errorText = "刷新失败，保留 \(timeFormatter.string(from: previous.generatedAt)) 的数据：\(reason)"
                return
            }

            try store.save(newSnapshot)
            WidgetCenter.shared.reloadAllTimelines()
            snapshot = newSnapshot
            errorText = newSnapshot.error
        } catch {
            errorText = "保存额度快照失败：\(error.localizedDescription)"
        }
    }
}

extension QuotaStatModel {
    init(_ window: ClaudeQuotaWindow?) {
        self.init(
            remainingPercent: window?.remainingPercent,
            usedPercent: window?.usedPercent,
            absoluteText: nil,
            resetsAt: window?.resetsAt
        )
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()
