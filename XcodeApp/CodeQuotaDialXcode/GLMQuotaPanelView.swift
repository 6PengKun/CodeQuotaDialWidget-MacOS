import GLMQuotaCore
import SwiftUI
import WidgetKit

struct GLMQuotaPanelView: View {
    @State private var snapshot: GLMQuotaSnapshot?
    @State private var errorText: String?
    @State private var isRefreshing = false
    @State private var keyIsSet = false
    @State private var isEditingKey = false
    @State private var apiKeyInput = ""
    @State private var keyStatus: String?
    @StateObject private var agent = LaunchAgentController(
        label: LaunchAgentLabels.glm.label,
        plistPath: LaunchAgentLabels.glm.plist
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let level = snapshot?.level {
                    TagBadge(text: level.uppercased(), tint: .blue)
                }

                LaunchAgentToggleRow(controller: agent)

                apiKeyCard

                HStack(spacing: Theme.cardSpacing) {
                    QuotaStatCard(title: "工具类额度", model: QuotaStatModel(snapshot?.timeLimit))
                    QuotaStatCard(title: "5h", model: QuotaStatModel(snapshot?.tokensLimit5))
                    QuotaStatCard(title: "本周", model: QuotaStatModel(snapshot?.tokensLimitMonth))
                }

                if let message = errorText ?? agent.lastError {
                    InlineBanner(text: message)
                }

                FootnoteRow(text: "桌面组件每 2 分钟读取快照")
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("GLM 额度")
        .navigationSubtitle(snapshot.map { "更新于 \(timeFormatter.string(from: $0.generatedAt))" } ?? "未刷新")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton(isRefreshing: isRefreshing) { await refresh() }
            }
        }
        .onAppear {
            loadSnapshot()
            agent.refreshStatus()
            keyIsSet = GLMConfig.resolvedApiKey() != nil
        }
    }

    // MARK: - API Key

    @ViewBuilder private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if keyIsSet && !isEditingKey {
                    Text("已设置")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }

            if keyIsSet && !isEditingKey {
                // Set state: never re-display the stored key; only offer to change it.
                HStack {
                    Text("已保存并隐藏")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("修改") {
                        apiKeyInput = ""
                        isEditingKey = true
                        keyStatus = nil
                    }
                    .controlSize(.small)
                }
            } else {
                // Editing / unset state: visible while typing so it can be verified.
                TextField("粘贴 GLM API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                HStack(spacing: 8) {
                    Button("保存") { saveApiKey() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keyIsSet {
                        Button("取消") {
                            apiKeyInput = ""
                            isEditingKey = false
                            keyStatus = nil
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    if let keyStatus {
                        Text(keyStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardSurface()
    }

    private func saveApiKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        var config = RuntimeConfigStore.load()   // preserve proxy / remote hosts
        config.glmApiKey = key
        do {
            try RuntimeConfigStore.save(config)
            apiKeyInput = ""        // drop the plaintext from memory / view
            keyIsSet = true
            isEditingKey = false
            keyStatus = "已保存"
            Task { await refresh() }
        } catch {
            keyStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func loadSnapshot() {
        do {
            snapshot = try GLMQuotaSnapshotStore().load()
            errorText = snapshot?.error
        } catch {
            errorText = "暂无额度快照，请先刷新。"
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let newSnapshot = await Task.detached {
            GLMQuotaCollector().collect()
        }.value

        do {
            let store = GLMQuotaSnapshotStore()

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
    init(_ window: GLMQuotaWindow?) {
        guard let window else {
            self.init(remainingPercent: nil, usedPercent: nil, absoluteText: nil, resetsAt: nil)
            return
        }
        let absolute: String? = {
            if let remaining = window.remaining, let total = window.total {
                return "\(remaining)/\(total)"
            }
            if let remaining = window.remaining, let usage = window.usage {
                return "\(remaining)/\(usage)"
            }
            return nil
        }()
        self.init(
            remainingPercent: window.remainingPercent,
            usedPercent: window.usedPercent,
            absoluteText: absolute,
            resetsAt: window.resetsAt
        )
    }
}

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()
