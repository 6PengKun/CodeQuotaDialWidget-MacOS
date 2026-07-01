import SwiftUI

/// In-app editor for the runtime settings that used to require a reinstall:
/// the network proxy (shared by Codex/Claude/GLM) and the remote SSH hosts for
/// the Usage widget's multi-end aggregation. Saving writes the shared config
/// file; every collector re-reads it on the next refresh.
struct SettingsPanelView: View {
    @State private var proxyURL = ""
    @State private var remoteHostsText = ""
    @State private var zcodeUsageEnabled = true
    @State private var savedConfig = RuntimeConfig.empty
    @State private var statusText: String?
    @State private var isError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                proxyCard
                remoteCard
                zcodeCard

                HStack(spacing: 10) {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                    Button("还原") { load() }
                        .disabled(!isDirty)
                    Spacer(minLength: 0)
                    if let statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(isError ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                FootnoteRow(text: "保存后在对应面板点“刷新”，或等待后台自动刷新即可生效，无需重新安装。")
            }
            .padding(Theme.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("设置")
        .onAppear(perform: load)
    }

    private var proxyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("网络代理", systemImage: "network")
                .font(.callout.weight(.semibold))
            Text("供 Codex / Claude / GLM 拉取额度时使用。留空=自动跟随 macOS 系统代理；填写=覆盖系统代理。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("http://127.0.0.1:7897", text: $proxyURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
        .cardSurface()
    }

    private var remoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("远端 SSH 主机", systemImage: "server.rack")
                .font(.callout.weight(.semibold))
            Text("供“消耗”统计做多端汇总，每行一个 host（需已配置免密登录且远端有 ccusage）。留空=仅本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $remoteHostsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72)
                .padding(4)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
        }
        .cardSurface()
    }

    private var zcodeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $zcodeUsageEnabled) {
                Label("ZCode 用量扩展", systemImage: "bolt.horizontal.circle")
                    .font(.callout.weight(.semibold))
            }
            Text("开启后读取本机 ~/.zcode/cli/db/db.sqlite，并作为 ZCode Agent 合并到“消耗”统计。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardSurface()
    }

    private var editedConfig: RuntimeConfig {
        // glmApiKey is owned by the GLM panel; carry the saved value through
        // untouched so saving proxy/hosts here never wipes it.
        RuntimeConfig(
            proxyURL: proxyURL.trimmingCharacters(in: .whitespaces),
            remoteHosts: parseHosts(remoteHostsText),
            glmApiKey: savedConfig.glmApiKey,
            zcodeUsageEnabled: zcodeUsageEnabled
        )
    }

    private var isDirty: Bool { editedConfig != savedConfig }

    private func load() {
        let config = RuntimeConfigStore.load()
        savedConfig = config
        proxyURL = config.proxyURL
        remoteHostsText = config.remoteHosts.joined(separator: "\n")
        zcodeUsageEnabled = config.zcodeUsageEnabled
        statusText = nil
        isError = false
    }

    private func save() {
        let config = editedConfig
        do {
            try RuntimeConfigStore.save(config)
            savedConfig = config
            // Reflect the normalized values back (trimmed proxy, cleaned hosts).
            proxyURL = config.proxyURL
            remoteHostsText = config.remoteHosts.joined(separator: "\n")
            zcodeUsageEnabled = config.zcodeUsageEnabled
            statusText = "已保存"
            isError = false
        } catch {
            statusText = "保存失败：\(error.localizedDescription)"
            isError = true
        }
    }

    private func parseHosts(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
