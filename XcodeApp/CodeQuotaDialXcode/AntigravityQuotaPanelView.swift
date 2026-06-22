import AntigravityQuotaCore
import SwiftUI
import WidgetKit

struct AntigravityQuotaPanelView: View {
    @State private var snapshot: AntigravityQuotaSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @StateObject private var agent = LaunchAgentController(
        label: LaunchAgentLabels.antigravity.label,
        plistPath: LaunchAgentLabels.antigravity.plist
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if snapshot?.planType != nil || snapshot?.email != nil {
                    HStack(spacing: 8) {
                        if let planType = snapshot?.planType {
                            TagBadge(text: planType.uppercased(), tint: .purple)
                        }
                        if let email = snapshot?.email {
                            Text(email)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LaunchAgentToggleRow(controller: agent)

                HStack(spacing: Theme.cardSpacing) {
                    ForEach(AntigravityQuotaBucket.allCases, id: \.self) { bucket in
                        QuotaStatCard(
                            title: bucket.displayName,
                            model: QuotaStatModel(snapshot?.model(for: bucket))
                        )
                    }
                }

                if let message = errorText ?? agent.lastError {
                    InlineBanner(text: message)
                }

                FootnoteRow(text: "需要本机 Antigravity 正在运行")
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Antigravity 额度")
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
            snapshot = try AntigravityQuotaSnapshotStore().load()
            errorText = snapshot?.error
        } catch {
            errorText = "暂无额度快照，请先刷新。"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            AntigravityQuotaCollector().collect()
        }.value

        do {
            let store = AntigravityQuotaSnapshotStore()

            if newSnapshot.isRefreshFailure, let previous = snapshot ?? (try? store.load()) {
                let reason = newSnapshot.error ?? "未返回目标模型额度"
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
    init(_ model: AntigravityModelQuota?) {
        guard let model else {
            self.init(remainingPercent: nil, usedPercent: nil, absoluteText: nil, resetsAt: nil)
            return
        }
        self.init(
            remainingPercent: model.remainingPercent,
            usedPercent: model.usedPercent,
            absoluteText: model.label,
            resetsAt: model.resetsAt
        )
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()
