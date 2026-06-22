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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let plan = snapshot?.planType {
                    TagBadge(text: plan.uppercased(), tint: .orange)
                }

                LaunchAgentToggleRow(controller: agent)

                HStack(spacing: Theme.cardSpacing) {
                    QuotaStatCard(title: "5h", model: QuotaStatModel(snapshot?.fiveHour))
                    QuotaStatCard(title: "本周", model: QuotaStatModel(snapshot?.weekly))
                }

                if let message = errorText ?? agent.lastError {
                    InlineBanner(text: message)
                }

                FootnoteRow(text: "桌面组件每 2 分钟读取快照")
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Claude 额度")
        .navigationSubtitle(snapshot.map { "更新于 \(timeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(isRefreshing: isRefreshing) { await refresh() }
            }
        }
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
