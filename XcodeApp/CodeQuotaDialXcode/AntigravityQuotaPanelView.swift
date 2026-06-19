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
        VStack(alignment: .leading, spacing: Theme.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Antigravity")
                    .font(.title3.weight(.semibold))
                if let planType = snapshot?.planType {
                    Text(planType.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Capsule())
                }
                if let email = snapshot?.email {
                    Text(email)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(snapshot.map { "更新 \(timeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Text("需要本机 Antigravity 正在运行")
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
